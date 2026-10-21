import Foundation
import Testing
@testable import Core

/// A canned OpenRouter response whose message content is `content`.
private func response(_ content: String, cost: Double = 0.0002) -> Data {
    let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]],
                                 "usage": ["cost": cost]]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func answer(_ corrected: String, _ alternatives: [String], reason: String = "Question form") -> String {
    let object: [String: Any] = ["corrected": corrected, "alternatives": alternatives, "reason": reason]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Suite struct ManualCheckParseTests {
    @Test func correctedAndAlternatives() throws {
        let parsed = try ManualCheck.parse(response(answer("Does it work?", ["Is it working?", "Does this work?"]), cost: 0.25),
                                           text: "Is it work?")
        #expect(parsed.result.corrected == "Does it work?")
        #expect(parsed.result.alternatives == ["Is it working?", "Does this work?"])
        #expect(parsed.result.reason == "Question form")
        #expect(!parsed.result.looksGood)
        #expect(parsed.cost == 0.25)
    }

    @Test func emptyDuplicateAndSameAsCorrectedAreDropped() throws {
        let parsed = try ManualCheck.parse(response(answer("Does it work?", ["", "Does it work?", "Is it working?", " Is it working? "])),
                                           text: "Is it work?")
        #expect(parsed.result.alternatives == ["Is it working?"])
    }

    @Test func atMostThreeAlternatives() throws {
        let parsed = try ManualCheck.parse(response(answer("Does it work?", ["a", "b", "c", "d", "e"])), text: "Is it work?")
        #expect(parsed.result.alternatives == ["a", "b", "c"])
    }

    @Test func correctedEqualToTextLooksGood() throws {
        let parsed = try ManualCheck.parse(response(answer("It works. ", ["It's working."])), text: "  It works.")
        #expect(parsed.result.looksGood)
        #expect(parsed.result.alternatives == ["It's working."])
    }

    @Test func emptyCorrectedMeansUnchanged() throws {
        let parsed = try ManualCheck.parse(response(answer("", [])), text: "It works.")
        #expect(parsed.result.corrected == "It works.")
        #expect(parsed.result.looksGood)
    }

    @Test func codeFencedJSONIsRead() throws {
        let parsed = try ManualCheck.parse(response("```json\n\(answer("Does it work?", []))\n```"), text: "Is it work?")
        #expect(parsed.result.corrected == "Does it work?")
    }

    @Test func unreadableThrows() {
        #expect(throws: TierTwoError.malformed) { try ManualCheck.parse(response("not json"), text: "x") }
        #expect(throws: TierTwoError.malformed) { try ManualCheck.parse(response(#"{"alternatives": []}"#), text: "x") }
        #expect(throws: TierTwoError.malformed) { try ManualCheck.parse(Data("{}".utf8), text: "x") }
    }

    @Test func bodyHasItsOwnPromptSchemaContextAndModels() throws {
        let body = ManualCheck.body(text: "Is it work?", before: "Hi.", after: "Thanks.", models: ["a", "b"])
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["models"] as? [String] == ["a", "b"])
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages[0]["content"] == ManualCheck.systemPrompt)
        #expect(messages[0]["content"] != TierTwoRequest.systemPrompt)
        #expect(messages[1]["content"] == "BEFORE: Hi.\nTEXT: Is it work?\nAFTER: Thanks.")
        let format = try #require(object["response_format"] as? [String: Any])
        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        #expect(Set(schema["required"] as? [String] ?? []) == ["corrected", "alternatives", "reason"])
    }
}

@MainActor
@Suite struct ManualCheckSchedulerTests {
    @Test func sentEvenAtTheCapAndCounted() async throws {
        let sent = Counter()
        let scheduler = TierTwoScheduler(models: ["m"], cap: 1, ledger: UsageLedger(day: UsageLedger.dayKey(Date()), requests: 1),
                                         send: { _ in sent.add(); return response(answer("Does it work?", ["Is it working?"]), cost: 0.0005) },
                                         log: { _ in })
        #expect(scheduler.capReached)
        let result = try await scheduler.checkNow("Is it work?", before: nil, after: nil)
        #expect(result.result.corrected == "Does it work?")
        #expect(sent.value == 1)
        #expect(scheduler.ledger.requests == 2)
        #expect(scheduler.ledger.cost == 0.0005)
        #expect(scheduler.counters.manual == 1)

        // The automatic checks still obey the cap.
        var document = DocumentState()
        _ = document.update(text: "She dont know.")
        scheduler.update(sentences: document.sentences, caret: nil) { _ in false }
        try await Task.sleep(for: .milliseconds(20))
        #expect(sent.value == 1)
    }

    @Test func failureIsCountedAndThrown() async {
        let scheduler = TierTwoScheduler(models: ["m"], cap: 10, send: { _ in throw TierTwoError.http(500) }, log: { _ in })
        await #expect(throws: TierTwoError.http(500)) { try await scheduler.checkNow("x", before: nil, after: nil) }
        #expect(scheduler.counters.failures == 1)
        #expect(scheduler.counters.lastError == "HTTP 500")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
