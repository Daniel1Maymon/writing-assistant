import Foundation
import Testing
@testable import Core

@Suite struct EnvFileTests {
    @Test func parsesPlainPairs() {
        let env = EnvFile.parse("A=1\nB=two")
        #expect(env == ["A": "1", "B": "two"])
    }

    @Test func skipsBlankLinesAndComments() {
        let env = EnvFile.parse("\n# comment\n   # indented comment\nA=1\n\n")
        #expect(env == ["A": "1"])
    }

    @Test func stripsMatchingQuotes() {
        let env = EnvFile.parse("A=\"hello world\"\nB='single'\nC=\"unbalanced")
        #expect(env["A"] == "hello world")
        #expect(env["B"] == "single")
        #expect(env["C"] == "\"unbalanced")
    }

    @Test func keepsHashInsideQuotesButStripsInlineComment() {
        let env = EnvFile.parse("A=\"a # b\"\nB=value # trailing\nC=abc#def")
        #expect(env["A"] == "a # b")
        #expect(env["B"] == "value")
        #expect(env["C"] == "abc#def")
    }

    @Test func emptyValuesAreEmptyStrings() {
        let env = EnvFile.parse("A=\nB=\"\"")
        #expect(env["A"] == "")
        #expect(env["B"] == "")
    }

    @Test func trimsWhitespaceAndExportPrefix() {
        let env = EnvFile.parse("  export A = 1  \nB= x ")
        #expect(env["A"] == "1")
        #expect(env["B"] == "x")
    }

    @Test func valueMayContainEquals() {
        let env = EnvFile.parse("URL=https://x.test/?a=b")
        #expect(env["URL"] == "https://x.test/?a=b")
    }

    @Test func ignoresLinesWithoutKey() {
        let env = EnvFile.parse("no equals here\n=nokey\nA=1")
        #expect(env == ["A": "1"])
    }

    @Test func laterDuplicateWins() {
        #expect(EnvFile.parse("A=1\nA=2")["A"] == "2")
    }

    @Test func handlesWindowsLineEndings() {
        #expect(EnvFile.parse("A=1\r\nB=2\r\n") == ["A": "1", "B": "2"])
    }

    @Test func missingFileGivesEmptyDictionary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID()).env")
        #expect(try EnvFile.load(from: url) == [:])
    }

    @Test func loadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).env")
        try "OPENROUTER_MODEL=anthropic/claude-haiku-5.5\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try EnvFile.load(from: url)["OPENROUTER_MODEL"] == "anthropic/claude-haiku-5.5")
    }

    /// The project's real example file must parse into the keys the app expects.
    @Test func projectEnvExampleHasExpectedKeys() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".env.example")
        let env = try EnvFile.load(from: example)
        for key in ["OPENROUTER_API_KEY", "OPENROUTER_MODEL", "OPENROUTER_FALLBACK_MODEL",
                    "OPENROUTER_BASE_URL", "DAILY_REQUEST_CAP"] {
            #expect(env[key]?.isEmpty == false, "missing \(key)")
        }
    }
}
