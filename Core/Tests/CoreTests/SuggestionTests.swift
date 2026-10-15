import Foundation
import Testing
@testable import Core

private func suggestion(_ sentence: Sentence, _ range: NSRange, _ replacement: String,
                        category: SuggestionCategory = .grammar, source: SuggestionSource = .local,
                        ruleId: String? = nil) -> Suggestion {
    Suggestion(sentenceHash: sentence.hash, range: range, original: (sentence.text as NSString).substring(with: range),
               category: category, message: "msg", replacements: [replacement], source: source, ruleId: ruleId)
}

@Suite struct RelocateTests {
    @Test func missingOrEmptySubstringIsNil() {
        #expect(relocate("absent", in: "The cat sat.") == nil)
        #expect(relocate("", in: "The cat sat.") == nil)
    }

    @Test func repeatedSubstringPicksNearestToHint() {
        let sentence = "the cat and the dog and the bird"
        #expect(relocate("the", in: sentence) == NSRange(location: 0, length: 3))
        #expect(relocate("the", in: sentence, hint: 14) == NSRange(location: 12, length: 3))
        #expect(relocate("the", in: sentence, hint: 30) == NSRange(location: 24, length: 3))
    }

    @Test func offsetsAreUTF16AfterEmojiAndHebrew() {
        let sentence = "😀 שלום teh end"
        let range = relocate("teh", in: sentence)
        #expect(range == (sentence as NSString).range(of: "teh"))
        #expect(range?.location == 8)  // emoji = 2 units, space, 4 Hebrew letters, space
    }
}

@Suite struct LLMEditTests {
    @Test func editNotInSentenceIsDropped() {
        let sentence = Sentence(range: NSRange(location: 0, length: 0), text: "I has a apple.")
        let edits = [
            LLMEdit(original: "has", replacement: "have", category: .grammar, reason: "Agreement"),
            LLMEdit(original: "banana", replacement: "pear", category: .grammar, reason: "Invented"),
        ]
        let result = suggestions(from: edits, in: sentence)
        #expect(result.count == 1)
        #expect(result[0].range == NSRange(location: 2, length: 3))
        #expect(result[0].replacements == ["have"])
        #expect(result[0].source == .llm)
        #expect(result[0].message == "Agreement")
    }

    @Test func twoEditsOfARepeatedWordGetDifferentOccurrences() {
        let sentence = Sentence(range: NSRange(location: 0, length: 0), text: "teh cat and teh dog")
        let edit = LLMEdit(original: "teh", replacement: "the", category: .spelling, reason: "Typo")
        let result = suggestions(from: [edit, edit], in: sentence)
        #expect(result.map(\.range.location) == [0, 12])
    }

    @Test func decodesTheDesignContract() throws {
        let json = #"{"original": "in order to", "replacement": "to", "category": "concise", "reason": "Shorter"}"#
        let edit = try JSONDecoder().decode(LLMEdit.self, from: Data(json.utf8))
        #expect(edit == LLMEdit(original: "in order to", replacement: "to", category: .concise, reason: "Shorter"))
    }
}

@Suite struct MergeTests {
    let sentence = Sentence(range: NSRange(location: 0, length: 0), text: "Teh cat recieve the mail in order to read.")

    @Test func overlappingLLMSuggestionDroppedOthersKeptAndSorted() {
        let local = suggestion(sentence, NSRange(location: 8, length: 7), "receive", category: .spelling)
        let overlapping = suggestion(sentence, NSRange(location: 4, length: 11), "cat receives", source: .llm)
        let separate = suggestion(sentence, NSRange(location: 25, length: 11), "to", category: .concise, source: .llm)
        let first = suggestion(sentence, NSRange(location: 0, length: 3), "The", category: .spelling)

        let result = merge(local: [local, first], llm: [separate, overlapping])
        #expect(result.map(\.replacements[0]) == ["The", "receive", "to"])
    }

    @Test func ignoreListRemovesRulesDismissedAndDictionaryWords() {
        let teh = suggestion(sentence, NSRange(location: 0, length: 3), "The", category: .spelling)
        let recieve = suggestion(sentence, NSRange(location: 8, length: 7), "receive", category: .spelling)
        let ruled = suggestion(sentence, NSRange(location: 16, length: 3), "a", ruleId: "article")
        let concise = suggestion(sentence, NSRange(location: 25, length: 11), "to", category: .concise, source: .llm)

        let ignore = IgnoreList(rules: ["article"], dismissed: [concise.id], dictionary: ["TEH"])
        #expect(merge(local: [teh, recieve, ruled], llm: [concise], ignore: ignore) == [recieve])
    }

    @Test func dictionaryOnlyHidesSpelling() {
        let grammar = suggestion(sentence, NSRange(location: 0, length: 3), "The", category: .grammar)
        #expect(merge(local: [grammar], llm: [], ignore: IgnoreList(dictionary: ["teh"])) == [grammar])
    }

    @Test func duplicateIdsAppearOnce() {
        let a = suggestion(sentence, NSRange(location: 0, length: 3), "The", category: .spelling)
        #expect(merge(local: [a, a], llm: []).count == 1)
    }
}

@Suite struct SuggestionIdTests {
    @Test func idDependsOnHashRangeAndReplacement() {
        let sentence = Sentence(range: NSRange(location: 0, length: 0), text: "Teh cat.")
        let a = suggestion(sentence, NSRange(location: 0, length: 3), "The")
        let b = suggestion(sentence, NSRange(location: 0, length: 3), "The")
        let c = suggestion(sentence, NSRange(location: 0, length: 3), "Tea")
        let d = suggestion(sentence, NSRange(location: 4, length: 3), "The")
        #expect(a.id == b.id)
        #expect(a.id != c.id)
        #expect(a.id != d.id)
    }
}

@Suite struct CacheTests {
    @Test func sameSentenceTextIsAHit() {
        var cache = LRUCache<CacheKey, [Suggestion]>(capacity: 10)
        let first = segment("Is itt work? Hello.")[0]
        cache.set(CacheKey(sentenceHash: first.hash, ignoreVersion: 0), [])
        let again = segment("Other text. Is itt work?")[1]
        #expect(cache.get(CacheKey(sentenceHash: again.hash, ignoreVersion: 0)) != nil)
        #expect(cache.get(CacheKey(sentenceHash: again.hash, ignoreVersion: 1)) == nil)
    }

    @Test func evictsLeastRecentlyUsed() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.set("a", 1)
        cache.set("b", 2)
        _ = cache.get("a")  // "b" is now the oldest
        cache.set("c", 3)
        #expect(cache.count == 2)
        #expect(cache.get("b") == nil)
        #expect(cache.get("a") == 1)
        #expect(cache.get("c") == 3)
    }

    @Test func settingAnExistingKeyReplacesIt() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.set("a", 1)
        cache.set("a", 2)
        #expect(cache.count == 1)
        #expect(cache.get("a") == 2)
    }
}

@Suite struct M3CoreTests {
    private func suggestion(_ sentence: Sentence, _ word: String, _ category: SuggestionCategory, rule: String) -> Suggestion {
        Suggestion(sentenceHash: sentence.hash, range: (sentence.text as NSString).range(of: word), original: word,
                   category: category, message: "m", replacements: ["x"], source: .local, ruleId: rule)
    }

    @Test func placedIgnoringHidesDismissedRulesAndDictionaryWords() {
        var state = DocumentState()
        let sentence = state.update(text: "Teh Zorbo has a apple.")[0]
        let teh = suggestion(sentence, "Teh", .spelling, rule: "harper.SpellCheck")
        let zorbo = suggestion(sentence, "Zorbo", .spelling, rule: "harper.SpellCheck2")
        let has = suggestion(sentence, "has", .grammar, rule: "harper.Agreement")
        let a = suggestion(sentence, "a", .grammar, rule: "harper.AnA")
        state.store([teh, zorbo, has, a], for: sentence.hash)

        let ignore = IgnoreList(rules: ["harper.AnA"], dismissed: [has.id], dictionary: ["zorbo", "teh-not"])
        #expect(state.placed(ignoring: ignore).map(\.suggestion.original) == ["Teh"])
        #expect(state.placed.count == 4)
    }

    @Test func ignoreListRoundTripsAndBadFilesGiveEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IgnoreList-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("sub/ignore.json")
        let list = IgnoreList(rules: ["r"], dismissed: ["d"], dictionary: ["Zorbo"])
        try list.save(to: url)
        #expect(IgnoreList.load(from: url) == list)
        #expect(IgnoreList.load(from: dir.appendingPathComponent("missing.json")) == IgnoreList())
        try Data("not json".utf8).write(to: url)
        #expect(IgnoreList.load(from: url) == IgnoreList())
    }

    @Test func applyEditReplacesSpanAndPutsCaretAfterIt() {
        let text = "😀 שלום I recieve mail."
        let range = (text as NSString).range(of: "recieve")
        let edit = applyEdit(to: text, range: range, original: "recieve", replacement: "receive")
        #expect(edit == AppliedEdit(text: "😀 שלום I receive mail.", caret: NSMaxRange(range)))
        let sentence = applyEdit(to: "Is it work? Yes.", range: NSRange(location: 0, length: 11),
                                 original: "Is it work?", replacement: "Does it work?")
        #expect(sentence == AppliedEdit(text: "Does it work? Yes.", caret: 13))
    }

    @Test func applyEditRefusesWhenTextChanged() {
        #expect(applyEdit(to: "I receive mail.", range: NSRange(location: 2, length: 7), original: "recieve", replacement: "receive") == nil)
        #expect(applyEdit(to: "Hi", range: NSRange(location: 1, length: 5), original: "i", replacement: "o") == nil)
    }
}
