import Foundation

/// A suggestion placed in the full text.
public struct PlacedSuggestion: Equatable, Sendable {
    public let suggestion: Suggestion
    /// UTF-16 range in the full text.
    public let range: NSRange
}

/// The suggestions for one text field. Results are stored per sentence hash, so a sentence that
/// didn't change keeps its suggestions (and their ids) wherever it moves.
public struct DocumentState: Sendable {
    public private(set) var sentences: [Sentence] = []
    private var results: [String: [Suggestion]] = [:]

    public init() {}

    /// Re-splits `text`. Returns the sentences that still need checking, one per distinct text.
    /// Results for sentences that are gone are dropped.
    public mutating func update(text: String) -> [Sentence] {
        sentences = segment(text)
        let present = Set(sentences.map(\.hash))
        results = results.filter { present.contains($0.key) }
        var queued = Set<String>()
        return sentences.filter { results[$0.hash] == nil && queued.insert($0.hash).inserted }
    }

    /// Stores check results. Ignored if that sentence is no longer in the text.
    public mutating func store(_ suggestions: [Suggestion], for sentenceHash: String) {
        guard sentences.contains(where: { $0.hash == sentenceHash }) else { return }
        results[sentenceHash] = suggestions
    }

    public func hasResults(for sentenceHash: String) -> Bool {
        results[sentenceHash] != nil
    }

    /// Every stored suggestion at its current place in the text, in text order.
    public var placed: [PlacedSuggestion] { placed(ignoring: IgnoreList()) }

    /// Like `placed`, without what the user dismissed, ignored or added to the dictionary.
    public func placed(ignoring ignore: IgnoreList) -> [PlacedSuggestion] {
        sentences.flatMap { sentence in
            merge(local: results[sentence.hash] ?? [], llm: [], ignore: ignore).map {
                PlacedSuggestion(suggestion: $0, range: NSRange(
                    location: sentence.range.location + $0.range.location, length: $0.range.length))
            }
        }
    }
}
