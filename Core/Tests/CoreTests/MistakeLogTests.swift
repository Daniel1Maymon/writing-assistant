import Foundation
import Testing
@testable import Core

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("MistakeLogTests-\(UUID().uuidString)/nested/mistakes.sqlite")
}

private func entry(_ original: String, _ replacement: String, category: SuggestionCategory = .spelling,
                   sentence: String = "Teh cat.", at seconds: TimeInterval = 0) -> MistakeEntry {
    MistakeEntry(createdAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds), appBundleId: "com.apple.TextEdit",
                 appName: "TextEdit", sentence: sentence, original: original, replacement: replacement,
                 category: category, message: "Spelling", source: .local)
}

@Suite struct MistakeLogTests {
    @Test func recordAndReadBackIdenticalFieldsIncludingHebrewAndEmoji() throws {
        let log = try MistakeLog(url: tempURL())
        var written = MistakeEntry(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.5), appBundleId: "com.apple.mail", appName: "Mail",
            sentence: "שלום 😀, \"quoted\" teh end.", original: "teh", replacement: "the", category: .spelling,
            message: "Possible typo", ruleId: "spell.teh", source: .llm)
        written.id = try log.record(written)

        let read = try log.recent()
        #expect(read == [written])
    }

    @Test func recentIsNewestFirstAndFiltersByCategory() throws {
        let log = try MistakeLog(url: tempURL())
        try log.record(entry("a", "b", at: 1))
        try log.record(entry("has", "have", category: .grammar, at: 2))
        try log.record(entry("c", "d", at: 3))

        #expect(try log.recent().map(\.original) == ["c", "has", "a"])
        #expect(try log.recent(limit: 1).map(\.original) == ["c"])
        #expect(try log.recent(category: .grammar).map(\.original) == ["has"])
    }

    @Test func mostRepeatedGroupsCaseInsensitively() throws {
        let log = try MistakeLog(url: tempURL())
        try log.record(entry("Teh", "The"))
        try log.record(entry("teh", "the"))
        try log.record(entry("recieve", "receive"))

        let top = try log.mostRepeated()
        #expect(top.first == RepeatedMistake(original: "teh", replacement: "the", count: 2))
        #expect(top.count == 2)
    }

    @Test func csvEscapesCommasQuotesAndNewlines() throws {
        let log = try MistakeLog(url: tempURL())
        try log.record(entry("teh", "the", sentence: "Well, he said \"teh\"\nthen left."))

        let csv = try log.exportCSV()
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "createdAt,appBundleId,appName,sentence,original,replacement,category,message,ruleId,source")
        #expect(csv.contains(#","Well, he said ""teh""\#nthen left.",teh,the,spelling,Spelling,,local"#))
        #expect(csv.hasSuffix("\r\n"))
    }

    @Test func deleteAllEmptiesTheLog() throws {
        let log = try MistakeLog(url: tempURL())
        try log.record(entry("a", "b"))
        try log.deleteAll()
        #expect(try log.recent().isEmpty)
    }

    @Test func missingFolderIsCreated() throws {
        let url = tempURL()
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        _ = try MistakeLog(url: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unwritablePathThrowsWithoutCrashing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MistakeLogRO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        #expect(throws: MistakeLogError.self) { try MistakeLog(url: dir.appendingPathComponent("mistakes.sqlite")) }
        #expect(throws: MistakeLogError.self) {
            try MistakeLog(url: dir.appendingPathComponent("sub/mistakes.sqlite"))
        }
    }
}
