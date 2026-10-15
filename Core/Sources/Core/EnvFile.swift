import Foundation

/// Minimal `.env` reader for debug builds. Release builds read secrets from Keychain instead.
public enum EnvFile {
    /// Reads `url`. A missing file is not an error: it yields an empty dictionary.
    public static func load(from url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// `KEY=value` per line. Supports `#` comments, an optional `export ` prefix,
    /// single or double quotes, and ` #` trailing comments on unquoted values.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value(String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func value(_ raw: String) -> String {
        for quote in ["\"", "'"] where raw.count >= 2 && raw.hasPrefix(quote) && raw.hasSuffix(quote) {
            return String(raw.dropFirst().dropLast())
        }
        if let comment = raw.range(of: " #") {
            return raw[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return raw
    }
}
