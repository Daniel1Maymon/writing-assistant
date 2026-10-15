import CryptoKit
import Foundation
import NaturalLanguage

public struct Sentence: Equatable, Sendable {
    /// UTF-16 range in the full text, without surrounding whitespace.
    public let range: NSRange
    public let text: String
    /// Depends only on the text, so a sentence keeps its hash when it moves.
    public let hash: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
        self.hash = Sentence.hash(text)
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Splits text into sentences with `NLTokenizer`, which already handles "Dr.", "e.g." and "p.m.".
public func segment(_ text: String) -> [Sentence] {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    let ns = text as NSString

    return tokenizer.tokens(for: text.startIndex..<text.endIndex).compactMap { tokenRange in
        let raw = NSRange(tokenRange, in: text)
        let trimmed = trimWhitespace(raw, in: ns)
        guard trimmed.length > 0 else { return nil }
        return Sentence(range: trimmed, text: ns.substring(with: trimmed))
    }
}

private func trimWhitespace(_ range: NSRange, in ns: NSString) -> NSRange {
    let whitespace = CharacterSet.whitespacesAndNewlines
    var start = range.location
    var end = NSMaxRange(range)
    while start < end, let scalar = Unicode.Scalar(ns.character(at: start)), whitespace.contains(scalar) {
        start += 1
    }
    while end > start, let scalar = Unicode.Scalar(ns.character(at: end - 1)), whitespace.contains(scalar) {
        end -= 1
    }
    return NSRange(location: start, length: end - start)
}

/// Sentences in `next` whose hash wasn't in `previous` are dirty and need checking; the rest keep their suggestions.
public func diff(previous: [Sentence], next: [Sentence]) -> (dirty: [Sentence], kept: [Sentence]) {
    let known = Set(previous.map(\.hash))
    var dirty: [Sentence] = []
    var kept: [Sentence] = []
    for sentence in next {
        if known.contains(sentence.hash) {
            kept.append(sentence)
        } else {
            dirty.append(sentence)
        }
    }
    return (dirty, kept)
}
