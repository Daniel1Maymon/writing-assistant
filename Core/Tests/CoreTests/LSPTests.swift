import Foundation
import Testing
@testable import Core

private func pos(_ line: Int, _ character: Int) -> LSPPosition { LSPPosition(line: line, character: character) }

private func diagnostic(_ start: Int, _ end: Int, code: String? = "AnA", line: Int = 0) -> LSPDiagnostic {
    LSPDiagnostic(range: LSPRange(start: pos(line, start), end: pos(line, end)), message: "msg", code: code)
}

@Suite struct LSPFramingTests {
    @Test func encodeCountsBytesNotCharacters() {
        let body = Data(#"{"t":"שלום 😀"}"#.utf8)
        let framed = String(decoding: LSPFrame.encode(body), as: UTF8.self)
        #expect(framed.hasPrefix("Content-Length: \(body.count)\r\n\r\n"))
        #expect(body.count > #"{"t":"שלום 😀"}"#.count)
    }

    @Test func decoderHandlesSplitReads() {
        let framed = LSPFrame.encode(Data(#"{"id":1,"x":"😀"}"#.utf8))
        var decoder = LSPFrameDecoder()
        #expect(decoder.append(framed.prefix(10)).isEmpty)
        #expect(decoder.append(framed.dropFirst(10).prefix(25)).isEmpty)
        #expect(decoder.append(framed.dropFirst(35)) == [Data(#"{"id":1,"x":"😀"}"#.utf8)])
    }

    @Test func decoderHandlesTwoMessagesInOneRead() {
        var decoder = LSPFrameDecoder()
        let both = LSPFrame.encode(Data("{\"a\":1}".utf8)) + LSPFrame.encode(Data("{\"b\":2}".utf8))
        #expect(decoder.append(both) == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
    }

    @Test func decoderWaitsForBodyAndSkipsBadHeaders() {
        var decoder = LSPFrameDecoder()
        #expect(decoder.append(Data("Content-Type: x\r\n\r\ncontent-length: 2\r\n\r\n".utf8)).isEmpty)
        #expect(decoder.append(Data("{}".utf8)) == [Data("{}".utf8)])
    }
}

@Suite struct HarperMappingTests {
    @Test func singleLineOffsetIsTheCharacter() {
        #expect(utf16Offset(of: pos(0, 4), in: "Is itt work?") == 4)
        #expect(utf16Offset(of: pos(0, 12), in: "Is itt work?") == 12)
        #expect(utf16Offset(of: pos(0, 13), in: "Is itt work?") == nil)
    }

    @Test func multiLineOffsetsHandleLFAndCRLFAndCR() {
        #expect(utf16Offset(of: pos(1, 2), in: "ab\ncd") == 5)
        #expect(utf16Offset(of: pos(1, 2), in: "ab\r\ncd") == 6)
        #expect(utf16Offset(of: pos(2, 0), in: "a\rb\nc") == 4)
        #expect(utf16Offset(of: pos(0, 3), in: "ab\r\ncd") == nil)
        #expect(utf16Offset(of: pos(3, 0), in: "a\nb") == nil)
    }

    @Test func offsetAfterEmojiAndHebrewIsUTF16() {
        let text = "😀 שלום teh car."
        let start = utf16Offset(of: pos(0, 8), in: text)!
        #expect((text as NSString).substring(with: NSRange(location: start, length: 3)) == "teh")
    }

    @Test func diagnosticBecomesSuggestion() throws {
        let sentence = Sentence(range: NSRange(location: 40, length: 14), text: "I has a apple.")
        let s = try #require(suggestion(from: diagnostic(6, 7), replacements: ["an"], in: sentence))
        #expect(s.range == NSRange(location: 6, length: 1))
        #expect(s.original == "a")
        #expect(s.category == .grammar)
        #expect(s.replacements == ["an"])
        #expect(s.ruleId == "harper.AnA")
        #expect(s.source == .local)
        #expect(s.sentenceHash == sentence.hash)
    }

    @Test func spellCheckIsSpellingAndReplacementsAreDedupedAndCapped() throws {
        let sentence = Sentence(range: NSRange(location: 0, length: 12), text: "She teh car.")
        let s = try #require(suggestion(from: diagnostic(4, 7, code: "SpellCheck"),
                                        replacements: ["the", "the", "teh", "tea", "tech", "ten"], in: sentence))
        #expect(s.category == .spelling)
        #expect(s.replacements == ["the", "tea", "tech"])
    }

    @Test func outOfRangeOrEmptyDiagnosticIsDropped() {
        let sentence = Sentence(range: NSRange(location: 0, length: 5), text: "Hello")
        #expect(suggestion(from: diagnostic(3, 9), replacements: [], in: sentence) == nil)
        #expect(suggestion(from: diagnostic(2, 2), replacements: [], in: sentence) == nil)
        #expect(suggestion(from: diagnostic(0, 1, line: 1), replacements: [], in: sentence) == nil)
    }

    @Test func diagnosticCodeMayBeANumberOrMissing() throws {
        let json = #"[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"m","code":7},"#
            + #"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"m"}]"#
        let decoded = try JSONDecoder().decode([LSPDiagnostic].self, from: Data(json.utf8))
        #expect(decoded.map(\.code) == ["7", nil])
    }

    @Test func quickfixReplacementsIgnoreOtherActions() throws {
        let json = """
            [{"title":"Replace with “an”","kind":"quickfix","edit":{"changes":{"file:///a":[
               {"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":7}},"newText":"an"}]}}},
             {"title":"Ignore Harper error.","command":{"title":"x","command":"HarperIgnoreLint"}}]
            """
        let actions = try JSONDecoder().decode([LSPCodeAction].self, from: Data(json.utf8))
        #expect(quickfixReplacements(actions) == ["an"])
    }
}

@Suite struct DocumentStateTests {
    private func result(for sentence: Sentence, word: String) -> [Suggestion] {
        let range = (sentence.text as NSString).range(of: word)
        guard range.location != NSNotFound else { return [] }
        return [Suggestion(sentenceHash: sentence.hash, range: range, original: word, category: .spelling,
                           message: "m", replacements: ["x"], source: .local)]
    }

    @Test func firstTextIsAllDirtyAndEditingSentenceTwoKeepsSentenceOneIds() {
        var state = DocumentState()
        let dirty = state.update(text: "I recieve mail. I has a apple.")
        #expect(dirty.map(\.text) == ["I recieve mail.", "I has a apple."])
        for sentence in dirty { state.store(result(for: sentence, word: sentence.text.contains("recieve") ? "recieve" : "has"), for: sentence.hash) }
        let before = state.placed.first!.suggestion.id

        let dirtyAfterEdit = state.update(text: "I recieve mail. I have a apple.")
        #expect(dirtyAfterEdit.map(\.text) == ["I have a apple."])
        #expect(state.placed.map(\.suggestion.id) == [before])
    }

    @Test func rangesBecomeAbsoluteAndFollowInsertedText() {
        var state = DocumentState()
        for sentence in state.update(text: "Hi. I recieve mail.") {
            state.store(result(for: sentence, word: "recieve"), for: sentence.hash)
        }
        #expect(state.placed.map(\.range) == [NSRange(location: 6, length: 7)])

        let dirty = state.update(text: "Hello there. Hi. I recieve mail.")
        #expect(dirty.map(\.text) == ["Hello there."])
        #expect(state.placed.map(\.range) == [NSRange(location: 19, length: 7)])
    }

    @Test func deletedSentenceLosesItsSuggestionsAndLateResultsAreIgnored() {
        var state = DocumentState()
        let dirty = state.update(text: "I recieve mail. Fine.")
        let first = dirty[0]
        state.store(result(for: first, word: "recieve"), for: first.hash)
        _ = state.update(text: "Fine.")
        #expect(state.placed.isEmpty)
        state.store(result(for: first, word: "recieve"), for: first.hash)
        #expect(state.placed.isEmpty)
        #expect(!state.hasResults(for: first.hash))
    }

    @Test func repeatedSentenceIsQueuedOnceAndPlacedTwice() {
        var state = DocumentState()
        let dirty = state.update(text: "Teh end. Teh end.")
        #expect(dirty.count == 1)
        state.store(result(for: dirty[0], word: "Teh"), for: dirty[0].hash)
        #expect(state.placed.map(\.range) == [NSRange(location: 0, length: 3), NSRange(location: 9, length: 3)])
    }
}
