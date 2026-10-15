import Foundation

// The small part of the Language Server Protocol needed to talk to `harper-ls` (decision 0005).

/// Base-protocol framing: a `Content-Length` header (in bytes), a blank line, then the JSON body.
public enum LSPFrame {
    public static func encode(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}

/// Collects bytes from the server's stdout and hands back whole message bodies.
public struct LSPFrameDecoder: Sendable {
    private var buffer = Data()
    private static let separator = Data("\r\n\r\n".utf8)

    public init() {}

    /// Appends `data` and returns every message body that is now complete, in order.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var bodies: [Data] = []
        while let headerEnd = buffer.range(of: Self.separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(header) else {
                // Not a header we understand: skip it rather than stall forever.
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            guard buffer.endIndex - headerEnd.upperBound >= length else { break }
            let bodyEnd = headerEnd.upperBound + length
            bodies.append(Data(buffer[headerEnd.upperBound..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return bodies
    }

    private static func contentLength(_ header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

public struct LSPPosition: Codable, Equatable, Sendable {
    public let line: Int
    /// UTF-16 code units, the LSP default.
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LSPRange: Codable, Equatable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

public struct LSPDiagnostic: Codable, Equatable, Sendable {
    public let range: LSPRange
    public let message: String
    /// The rule name, e.g. "SpellCheck". LSP allows a number here too.
    public let code: String?

    public init(range: LSPRange, message: String, code: String?) {
        self.range = range
        self.message = message
        self.code = code
    }

    enum CodingKeys: String, CodingKey { case range, message, code }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        range = try container.decode(LSPRange.self, forKey: .range)
        message = try container.decode(String.self, forKey: .message)
        if let text = try? container.decodeIfPresent(String.self, forKey: .code) {
            code = text
        } else {
            code = (try? container.decodeIfPresent(Int.self, forKey: .code)).flatMap { $0.map(String.init) }
        }
    }
}

public struct LSPCodeAction: Decodable, Equatable, Sendable {
    public struct TextEdit: Decodable, Equatable, Sendable {
        public let range: LSPRange
        public let newText: String
    }

    public struct WorkspaceEdit: Decodable, Equatable, Sendable {
        public let changes: [String: [TextEdit]]?
    }

    public let title: String
    public let kind: String?
    public let edit: WorkspaceEdit?
}

/// The replacement texts offered by quickfix actions, in the server's order. Other actions are ignored.
public func quickfixReplacements(_ actions: [LSPCodeAction]) -> [String] {
    actions.filter { $0.kind == "quickfix" }
        .flatMap { action in (action.edit?.changes ?? [:]).values.flatMap { $0.map(\.newText) } }
}

/// Converts an LSP position to a UTF-16 offset. Lines end at "\n", "\r\n" or "\r". Nil if past the end.
public func utf16Offset(of position: LSPPosition, in text: String) -> Int? {
    let ns = text as NSString
    var lineStart = 0
    var line = 0
    while line < position.line {
        guard let next = nextLineStart(after: lineStart, in: ns) else { return nil }
        lineStart = next
        line += 1
    }
    let lineEnd = nextLineStart(after: lineStart, in: ns).map { lineBreakStart(before: $0, in: ns) } ?? ns.length
    let offset = lineStart + position.character
    return offset <= lineEnd ? offset : nil
}

private func nextLineStart(after start: Int, in ns: NSString) -> Int? {
    var i = start
    while i < ns.length {
        let c = ns.character(at: i)
        if c == 0x0A { return i + 1 }
        if c == 0x0D { return i + 1 < ns.length && ns.character(at: i + 1) == 0x0A ? i + 2 : i + 1 }
        i += 1
    }
    return nil
}

private func lineBreakStart(before nextStart: Int, in ns: NSString) -> Int {
    if nextStart >= 2, ns.character(at: nextStart - 2) == 0x0D, ns.character(at: nextStart - 1) == 0x0A {
        return nextStart - 2
    }
    return nextStart - 1
}

/// Turns one Harper diagnostic plus its quickfix texts into a suggestion for `sentence`.
/// Nil when the range doesn't fit the sentence or is empty.
public func suggestion(from diagnostic: LSPDiagnostic, replacements: [String], in sentence: Sentence) -> Suggestion? {
    guard let start = utf16Offset(of: diagnostic.range.start, in: sentence.text),
          let end = utf16Offset(of: diagnostic.range.end, in: sentence.text),
          end > start else { return nil }
    let range = NSRange(location: start, length: end - start)
    let original = (sentence.text as NSString).substring(with: range)
    var seen = Set<String>()
    let options = replacements.filter { $0 != original && seen.insert($0).inserted }.prefix(3)
    return Suggestion(
        sentenceHash: sentence.hash, range: range, original: original,
        category: diagnostic.code == "SpellCheck" ? .spelling : .grammar,
        message: diagnostic.message, replacements: Array(options), source: .local,
        ruleId: diagnostic.code.map { "harper.\($0)" })
}
