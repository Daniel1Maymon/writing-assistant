import AppKit

/// Re-runs the tier-1 probe from DESIGN.md → Open decision inside the real app.
/// Uses fixed test strings only, so the report contains no user text.
enum SpellProbe {
    static let samples = [
        "recieve",
        "definately",
        "teh",
        "hav",
        "I has a apple.",
        "She dont know where teh car are.",
    ]

    struct Sample: Codable {
        let text: String
        /// Words flagged by the combined spelling + grammar check (`check(_:range:types:...)`).
        let spelling: [String]
        /// Spans flagged as grammar by the combined check.
        let grammar: [String]
        /// Grammar details from `checkGrammar(of:...)` with the language forced to English.
        let grammarForcedEnglish: Int
    }

    struct Report: Codable {
        let date: Date
        let osVersion: String
        let checkerLanguage: String
        let automaticallyIdentifiesLanguages: Bool
        let samples: [Sample]

        var summary: String {
            let spelling = samples.reduce(0) { $0 + $1.spelling.count }
            let grammar = samples.reduce(0) { $0 + $1.grammar.count + $1.grammarForcedEnglish }
            return "\(spelling) spelling, \(grammar) grammar flags"
        }
    }

    @MainActor
    static func run() -> Report {
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }

        let types = NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.grammar.rawValue

        let results = samples.map { text -> Sample in
            let ns = text as NSString
            let found = checker.check(
                text, range: NSRange(location: 0, length: ns.length), types: types,
                options: nil, inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil)

            let spelling = found.filter { $0.resultType == .spelling }.map { ns.substring(with: $0.range) }
            let grammar = found.filter { $0.resultType == .grammar }.map { ns.substring(with: $0.range) }

            var details: NSArray?
            _ = checker.checkGrammar(
                of: text, startingAt: 0, language: "en", wrap: false,
                inSpellDocumentWithTag: tag, details: &details)

            return Sample(text: text, spelling: spelling, grammar: grammar,
                          grammarForcedEnglish: details?.count ?? 0)
        }

        return Report(
            date: Date(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            checkerLanguage: checker.language(),
            automaticallyIdentifiesLanguages: checker.automaticallyIdentifiesLanguages,
            samples: results)
    }

    static func write(_ report: Report) throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WritingAssistant", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("probe.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }
}
