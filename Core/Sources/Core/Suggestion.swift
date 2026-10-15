import CryptoKit
import Foundation

public enum SuggestionCategory: String, Codable, CaseIterable, Sendable {
    case spelling, grammar, punctuation, clarity, concise
}

public enum SuggestionSource: String, Codable, Sendable {
    case local, llm
}

/// One fix for one span of a sentence. Schema: DESIGN.md → Suggestion record.
public struct Suggestion: Equatable, Sendable {
    public let id: String
    public let sentenceHash: String
    /// UTF-16 range within the sentence.
    public let range: NSRange
    public let original: String
    public let category: SuggestionCategory
    public let message: String
    public let replacements: [String]
    public let source: SuggestionSource
    public let ruleId: String?

    public init(sentenceHash: String, range: NSRange, original: String, category: SuggestionCategory,
                message: String, replacements: [String], source: SuggestionSource, ruleId: String? = nil) {
        self.id = Suggestion.makeId(sentenceHash: sentenceHash, range: range, replacement: replacements.first ?? "")
        self.sentenceHash = sentenceHash
        self.range = range
        self.original = original
        self.category = category
        self.message = message
        self.replacements = replacements
        self.source = source
        self.ruleId = ruleId
    }

    static func makeId(sentenceHash: String, range: NSRange, replacement: String) -> String {
        let key = "\(sentenceHash)|\(range.location)|\(range.length)|\(replacement)"
        return SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// An edit as the model returns it (DESIGN.md → LLM output contract): quoted text, never offsets.
public struct LLMEdit: Codable, Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let category: SuggestionCategory
    public let reason: String

    public init(original: String, replacement: String, category: SuggestionCategory, reason: String) {
        self.original = original
        self.replacement = replacement
        self.category = category
        self.reason = reason
    }
}

/// Finds `substring` in `sentence`. With several matches, picks the one starting nearest to `hint` (UTF-16 offset).
public func relocate(_ substring: String, in sentence: String, hint: Int? = nil) -> NSRange? {
    nearest(occurrences(of: substring, in: sentence), to: hint)
}

func occurrences(of substring: String, in sentence: String) -> [NSRange] {
    guard !substring.isEmpty else { return [] }
    let ns = sentence as NSString
    var matches: [NSRange] = []
    var searchFrom = 0
    while searchFrom < ns.length {
        let found = ns.range(of: substring, options: .literal,
                             range: NSRange(location: searchFrom, length: ns.length - searchFrom))
        guard found.location != NSNotFound else { break }
        matches.append(found)
        searchFrom = found.location + 1
    }
    return matches
}

private func nearest(_ ranges: [NSRange], to hint: Int?) -> NSRange? {
    guard let hint else { return ranges.first }
    return ranges.min { abs($0.location - hint) < abs($1.location - hint) }
}

/// Turns model edits into suggestions. Edits whose text can't be found are dropped.
/// Edits are matched in order, so two edits of a repeated word land on two different occurrences.
public func suggestions(from edits: [LLMEdit], in sentence: Sentence) -> [Suggestion] {
    var claimed: [NSRange] = []
    var hint = 0
    var result: [Suggestion] = []
    for edit in edits {
        let free = occurrences(of: edit.original, in: sentence.text).filter { !claimed.contains($0) }
        guard let range = nearest(free, to: hint) else { continue }
        claimed.append(range)
        hint = NSMaxRange(range)
        result.append(Suggestion(
            sentenceHash: sentence.hash, range: range, original: edit.original, category: edit.category,
            message: edit.reason, replacements: [edit.replacement], source: .llm))
    }
    return result
}

/// What the user has told the app to stop showing.
public struct IgnoreList: Codable, Equatable, Sendable {
    public var rules: Set<String>
    public var dismissed: Set<String>
    /// Stored lower-cased.
    public var dictionary: Set<String>

    public init(rules: Set<String> = [], dismissed: Set<String> = [], dictionary: Set<String> = []) {
        self.rules = rules
        self.dismissed = dismissed
        self.dictionary = Set(dictionary.map { $0.lowercased() })
    }

    public func hides(_ suggestion: Suggestion) -> Bool {
        if dismissed.contains(suggestion.id) { return true }
        if let rule = suggestion.ruleId, rules.contains(rule) { return true }
        return suggestion.category == .spelling && dictionary.contains(suggestion.original.lowercased())
    }
}

/// Local results win: an LLM suggestion that overlaps a local one is dropped. Result is sorted by position.
public func merge(local: [Suggestion], llm: [Suggestion], ignore: IgnoreList = IgnoreList()) -> [Suggestion] {
    let llmKept = llm.filter { candidate in
        !local.contains { NSIntersectionRange($0.range, candidate.range).length > 0 }
    }
    var seen = Set<String>()
    return (local + llmKept)
        .filter { !ignore.hides($0) && seen.insert($0.id).inserted }
        .sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
}

extension IgnoreList {
    /// Reads the list saved by `save(to:)`. A missing or unreadable file gives an empty list.
    public static func load(from url: URL) -> IgnoreList {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(IgnoreList.self, from: data) else { return IgnoreList() }
        return IgnoreList(rules: list.rules, dismissed: list.dismissed, dictionary: list.dictionary)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The result of replacing one span of a field's text.
public struct AppliedEdit: Equatable, Sendable {
    public let text: String
    /// UTF-16 caret position after the edit: the end of the replacement.
    public let caret: Int
}

/// Replaces `range` of `text` with `replacement`, but only if the span still reads `original`
/// (the text may have changed since the suggestion was made). Nil when it doesn't.
public func applyEdit(to text: String, range: NSRange, original: String, replacement: String) -> AppliedEdit? {
    let ns = text as NSString
    guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == original else { return nil }
    return AppliedEdit(text: ns.replacingCharacters(in: range, with: replacement),
                       caret: range.location + (replacement as NSString).length)
}
