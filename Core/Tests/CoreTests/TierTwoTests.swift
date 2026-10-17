import Foundation
import Testing
@testable import Core

/// A canned OpenRouter response whose message content is `content`.
private func response(_ content: String, cost: Double = 0.0001) -> Data {
    let object: [String: Any] = ["model": "deepseek/deepseek-v4-flash",
                                 "choices": [["message": ["role": "assistant", "content": content]]],
                                 "usage": ["prompt_tokens": 300, "completion_tokens": 20, "cost": cost]]
    return try! JSONSerialization.data(withJSONObject: object)
}

private let doesnt = #"{"edits": [{"original": "dont", "replacement": "doesn't", "category": "grammar", "reason": "Agreement"}], "rewrite": null}"#

/// Records every request body; answers with `reply`, after `delay`.
private actor Stub {
    var bodies: [Data] = []
    let reply: @Sendable (Int) throws -> Data
    let delay: Duration

    init(delay: Duration = .zero, reply: @escaping @Sendable (Int) throws -> Data) {
        self.delay = delay
        self.reply = reply
    }

    func send(_ body: Data) async throws -> Data {
        bodies.append(body)
        let n = bodies.count
        if delay > .zero { try await Task.sleep(for: delay) }
        return try reply(n)
    }

    var count: Int { bodies.count }
}

/// Collects the log lines and the delivered results.
@MainActor
private final class Harness {
    let stub: Stub
    let scheduler: TierTwoScheduler
    var document = DocumentState()
    var delivered: [(Sentence, [Suggestion])] = []
    let lines = LogLines()

    init(stub: Stub, cap: Int = 100, models: [String] = ["main/model", "fallback/model"],
         now: @escaping () -> Date = Date.init) {
        self.stub = stub
        let lines = self.lines
        scheduler = TierTwoScheduler(models: models, cap: cap, send: { try await stub.send($0) },
                                     log: { lines.append($0) }, now: now)
        scheduler.onResult = { [unowned self] sentence, found in
            delivered.append((sentence, found))
            document.storeLLM(found, for: sentence.hash)
        }
    }

    func type(_ text: String, caret: Int?) {
        _ = document.update(text: text)
        scheduler.update(sentences: document.sentences, caret: caret) { [document] in document.hasLLMResults(for: $0) }
    }

    /// Waits until the scheduler has nothing in flight.
    func settle() async {
        for _ in 0..<200 where scheduler.inFlightCount > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ line: String) { lock.withLock { items.append(line) } }
    var all: [String] { lock.withLock { items } }
}

@Suite struct ParseTests {
    @Test func validAnswerGivesEditsAndCost() throws {
        let parsed = try TierTwoRequest.parse(response(doesnt, cost: 0.00012))
        #expect(parsed.result.edits == [LLMEdit(original: "dont", replacement: "doesn't", category: .grammar, reason: "Agreement")])
        #expect(parsed.result.rewrite == nil)
        #expect(parsed.cost == 0.00012)
    }

    @Test func malformedContentThrows() {
        #expect(throws: TierTwoError.malformed) { try TierTwoRequest.parse(response("not json")) }
        #expect(throws: TierTwoError.malformed) { try TierTwoRequest.parse(Data("{\"error\": {\"code\": 500}}".utf8)) }
    }

    @Test func codeFencedJSONIsRead() throws {
        let parsed = try TierTwoRequest.parse(response("```json\n\(doesnt)\n```"))
        #expect(parsed.result.edits.count == 1)
    }

    @Test func malformedRewriteKeepsEdits() throws {
        let content = #"{"edits": [{"original": "dont", "replacement": "doesn't", "category": "grammar", "reason": "x"}], "rewrite": {"kind": "sideways"}}"#
        let parsed = try TierTwoRequest.parse(response(content))
        #expect(parsed.result.edits.count == 1)
        #expect(parsed.result.rewrite == nil)
    }

    @Test func bodyHasModelsSchemaAndLimits() throws {
        let body = TierTwoRequest.body(sentence: "Is it work?", before: nil, after: "Yes.", models: ["a", "b"])
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["models"] as? [String] == ["a", "b"])
        #expect((object["provider"] as? [String: Any])?["sort"] as? String == "latency")
        #expect(object["max_tokens"] as? Int == 300)
        #expect(object["temperature"] as? Int == 0)
        #expect((object["reasoning"] as? [String: Any])?["enabled"] as? Bool == false)
        let format = try #require(object["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect((messages[1]["content"] as? String)?.contains("SENTENCE: Is it work?") == true)
    }
}

@Suite struct RewriteTests {
    let sentence = Sentence(range: NSRange(location: 0, length: 11), text: "Is it work?")

    private func result(_ rewrite: LLMRewrite?) -> [Suggestion] {
        suggestions(from: LLMResult(edits: [], rewrite: rewrite), in: sentence)
    }

    @Test func fixIsOneSentenceWideGrammarSuggestion() {
        let found = result(LLMRewrite(text: "Does it work?", kind: .fix, reason: "Question form"))
        #expect(found.count == 1)
        #expect(found[0].rewrite == .fix)
        #expect(found[0].category == .grammar)
        #expect(found[0].range == NSRange(location: 0, length: 11))
        #expect(found[0].replacements == ["Does it work?"])
        #expect(found[0].ruleId == "llm.rewrite.fix")
    }

    @Test func naturalIsClarity() {
        let found = result(LLMRewrite(text: "Does it work?", kind: .natural, reason: "More natural"))
        #expect(found.map(\.rewrite) == [.natural])
        #expect(found[0].category == .clarity)
    }

    @Test func nullOrSameSentenceGivesNothing() {
        #expect(result(nil).isEmpty)
        #expect(result(LLMRewrite(text: "Is it work? ", kind: .natural, reason: "")).isEmpty)
    }

    @Test func editNotInSentenceIsDropped() {
        let found = suggestions(from: LLMResult(edits: [LLMEdit(original: "banana", replacement: "x", category: .grammar, reason: "")],
                                                rewrite: nil), in: sentence)
        #expect(found.isEmpty)
    }
}

@Suite struct ReadyRuleTests {
    let sentence = Sentence(range: NSRange(location: 10, length: 14), text: "She dont know.")
    let open = Sentence(range: NSRange(location: 10, length: 13), text: "She dont know")

    @Test func finishedSentence() {
        #expect(isReadyForTierTwo(sentence, caret: 24))   // right after the "."
        #expect(isReadyForTierTwo(sentence, caret: 10))   // at its start
        #expect(isReadyForTierTwo(sentence, caret: 40))
        #expect(isReadyForTierTwo(sentence, caret: nil))
        #expect(!isReadyForTierTwo(sentence, caret: 15))  // inside
    }

    @Test func unfinishedSentenceOnlyWhenCaretIsAway() {
        #expect(!isReadyForTierTwo(open, caret: 23))
        #expect(!isReadyForTierTwo(open, caret: 10))
        #expect(!isReadyForTierTwo(open, caret: 15))
        #expect(isReadyForTierTwo(open, caret: 30))
        #expect(isReadyForTierTwo(open, caret: 2))
    }

    @Test func closingQuoteAfterThePeriodCounts() {
        let quoted = Sentence(range: NSRange(location: 0, length: 9), text: "He said.”")
        #expect(isReadyForTierTwo(quoted, caret: 9))
    }
}

@Suite(.serialized) @MainActor struct SchedulerTests {
    @Test func validAnswerDeliversMergedEdits() async {
        let h = Harness(stub: Stub { _ in response(doesnt) })
        h.type("She dont know.", caret: 14)
        await h.settle()
        #expect(await h.stub.count == 1)
        #expect(h.document.placed.map(\.suggestion.replacements) == [["doesn't"]])
        #expect(h.scheduler.ledger.requests == 1)
        #expect(h.scheduler.ledger.cost == 0.0001)
    }

    @Test func onlySentencesNearTheCaretAreSent() async {
        let h = Harness(stub: Stub { _ in response(#"{"edits": [], "rewrite": null}"#) })
        let text = (1...20).map { "Line number \($0) is here." }.joined(separator: " ")
        h.type(text, caret: (text as NSString).length)
        await h.settle()
        #expect(await h.stub.count == 3)
        h.type(text, caret: 0)
        await h.settle()
        #expect(await h.stub.count == 6)
    }

    @Test func noCaretSendsNothing() async {
        let h = Harness(stub: Stub { _ in response(#"{"edits": [], "rewrite": null}"#) })
        h.type((1...8).map { "Line number \($0) is here." }.joined(separator: " "), caret: nil)
        await h.settle()
        #expect(await h.stub.count == 0)
    }

    @Test func noRequestWhileTypingThenExactlyOneAfterThePeriod() async {
        let h = Harness(stub: Stub { _ in response(doesnt) })
        h.type("She dont kn", caret: 11)
        h.type("She dont know", caret: 13)
        await h.settle()
        #expect(await h.stub.count == 0)
        h.type("She dont know.", caret: 14)
        await h.settle()
        h.type("She dont know. ", caret: 15)
        h.type("She dont know. Ok", caret: 17)
        await h.settle()
        #expect(await h.stub.count == 1)
    }

    @Test func failuresGiveNoEditsAndTheNextRequestUsesTheFallbackFirst() async throws {
        let h = Harness(stub: Stub { n in
            if n == 1 { throw TierTwoError.http(503) }
            if n == 2 { return response("nonsense") }
            return response(doesnt)
        })
        h.type("She dont know.", caret: 14)
        await h.settle()
        #expect(h.document.placed.isEmpty)
        #expect(h.scheduler.counters.lastError == "HTTP 503")
        h.type("She dont know.", caret: 14)
        await h.settle()
        #expect(h.document.placed.isEmpty)
        h.type("She dont know.", caret: 14)
        await h.settle()
        #expect(h.document.placed.count == 1)
        let bodies = await h.stub.bodies
        let models = try bodies.map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any])["models"] as? [String] }
        #expect(models == [["main/model", "fallback/model"], ["fallback/model", "main/model"], ["fallback/model", "main/model"]])
    }

    @Test func atMostThreeAttemptsPerSentence() async {
        let h = Harness(stub: Stub { _ in throw TierTwoError.http(500) })
        for _ in 0..<6 {
            h.type("She dont know.", caret: 14)
            await h.settle()
        }
        #expect(await h.stub.count == 3)
    }

    @Test func changingTheSentenceMidRequestCancelsIt() async {
        let h = Harness(stub: Stub(delay: .milliseconds(150)) { _ in response(doesnt) })
        h.type("She dont know.", caret: 0)
        #expect(h.scheduler.inFlightCount == 1)
        h.type("He dont know.", caret: 5)  // caret inside the new sentence: no new request
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.scheduler.counters.cancelled == 1)
        #expect(h.delivered.isEmpty)
        #expect(h.document.placed.isEmpty)
    }

    @Test func lateAnswerForARemovedSentenceIsNeverShown() async {
        // Even if a result arrives, DocumentState drops it when the sentence is gone.
        var document = DocumentState()
        let old = document.update(text: "She dont know.")[0]
        _ = document.update(text: "Something else.")
        document.storeLLM([Suggestion(sentenceHash: old.hash, range: NSRange(location: 4, length: 4), original: "dont",
                                      category: .grammar, message: "", replacements: ["doesn't"], source: .llm)], for: old.hash)
        #expect(document.placed.isEmpty)
    }

    @Test func sameSentenceAgainUsesTheCache() async {
        let h = Harness(stub: Stub { _ in response(doesnt) })
        h.type("She dont know.", caret: 14)
        await h.settle()
        h.type("", caret: 0)
        h.type("She dont know.", caret: 14)
        await h.settle()
        #expect(await h.stub.count == 1)
        #expect(h.scheduler.counters.cacheHits == 1)
        #expect(h.document.placed.count == 1)
    }

    @Test func capStopsRequestsUntilTheNextDay() async {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let h = Harness(stub: Stub { _ in response(doesnt) }, cap: 2, now: { clock.date })
        h.type("One dont. Two dont. Three dont.", caret: 31)
        await h.settle()
        #expect(await h.stub.count == 2)
        #expect(h.scheduler.capReached)
        clock.date += 86_400
        #expect(!h.scheduler.capReached)
        h.type("One dont. Two dont. Three dont.", caret: 31)
        await h.settle()
        #expect(await h.stub.count == 3)
        #expect(h.scheduler.ledger.requests == 1)
        #expect(h.scheduler.ledger.cost == 0.0001)
    }

    @Test func logsNeverContainTheText() async {
        let h = Harness(stub: Stub { n in n == 1 ? try { throw TierTwoError.malformed }() : response(doesnt) })
        h.type("Secretword dont know.", caret: 21)
        await h.settle()
        h.type("Secretword dont know.", caret: 21)
        await h.settle()
        h.type("Other secretword.", caret: 0)
        await h.settle()
        let lines = h.lines.all
        #expect(lines.count >= 4)
        #expect(!lines.contains { $0.localizedCaseInsensitiveContains("secretword") || $0.contains("dont") })
    }
}

private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}
