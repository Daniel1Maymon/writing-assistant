import Foundation
import SQLite3

/// One accepted fix. Schema: DESIGN.md → Mistake log; decision 0002.
public struct MistakeEntry: Equatable, Sendable {
    public var id: Int64?
    public var createdAt: Date
    public var appBundleId: String
    public var appName: String
    public var sentence: String
    public var original: String
    public var replacement: String
    public var category: SuggestionCategory
    public var message: String
    public var ruleId: String?
    public var source: SuggestionSource

    public init(id: Int64? = nil, createdAt: Date, appBundleId: String, appName: String, sentence: String,
                original: String, replacement: String, category: SuggestionCategory, message: String,
                ruleId: String? = nil, source: SuggestionSource) {
        self.id = id
        self.createdAt = createdAt
        self.appBundleId = appBundleId
        self.appName = appName
        self.sentence = sentence
        self.original = original
        self.replacement = replacement
        self.category = category
        self.message = message
        self.ruleId = ruleId
        self.source = source
    }
}

public struct RepeatedMistake: Equatable, Sendable {
    /// Lower-cased.
    public let original: String
    /// Lower-cased.
    public let replacement: String
    public let count: Int
}

public struct MistakeLogError: Error, CustomStringConvertible {
    public let description: String
}

/// The local SQLite file of accepted fixes. Not thread-safe; use it from one place.
public final class MistakeLog {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WritingAssistant/mistakes.sqlite")
    }

    private var db: OpaquePointer?

    /// Creates the folder and the table if needed. Throws if the file can't be opened or written.
    public init(url: URL = MistakeLog.defaultURL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw MistakeLogError(description: "can't create folder: \(error.localizedDescription)")
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            db = nil
            throw MistakeLogError(description: message)
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS mistakes (
              id INTEGER PRIMARY KEY,
              createdAt TEXT NOT NULL,
              appBundleId TEXT NOT NULL,
              appName TEXT NOT NULL,
              sentence TEXT NOT NULL,
              original TEXT NOT NULL,
              replacement TEXT NOT NULL,
              category TEXT NOT NULL,
              message TEXT NOT NULL,
              ruleId TEXT,
              source TEXT NOT NULL
            )
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    public func record(_ entry: MistakeEntry) throws -> Int64 {
        let statement = try prepare("""
            INSERT INTO mistakes (createdAt, appBundleId, appName, sentence, original, replacement,
                                  category, message, ruleId, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        let values: [String?] = [
            dateFormatter.string(from: entry.createdAt), entry.appBundleId, entry.appName, entry.sentence,
            entry.original, entry.replacement, entry.category.rawValue, entry.message, entry.ruleId,
            entry.source.rawValue,
        ]
        for (index, value) in values.enumerated() {
            bind(value, to: statement, at: Int32(index + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        return sqlite3_last_insert_rowid(db)
    }

    /// Newest first. `search` matches the sentence, the original or the replacement, ignoring case (decision 0015).
    public func recent(limit: Int = 100, category: SuggestionCategory? = nil, search: String = "") throws -> [MistakeEntry] {
        var conditions: [String] = []
        var values: [String] = []
        if let category {
            conditions.append("category = ?")
            values.append(category.rawValue)
        }
        let search = search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            conditions.append("(sentence LIKE ? ESCAPE '\\' OR original LIKE ? ESCAPE '\\' OR replacement LIKE ? ESCAPE '\\')")
            let pattern = "%" + search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            values += [pattern, pattern, pattern]
        }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let statement = try prepare("SELECT * FROM mistakes \(filter) ORDER BY createdAt DESC, id DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            bind(value, to: statement, at: Int32(index + 1))
        }
        sqlite3_bind_int64(statement, Int32(values.count + 1), Int64(limit))
        return try rows(statement, map: entry(from:))
    }

    public func count() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM mistakes")
        defer { sqlite3_finalize(statement) }
        return try rows(statement) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    public func delete(id: Int64) throws {
        let statement = try prepare("DELETE FROM mistakes WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    /// Grouped by lower-cased `original → replacement`, most frequent first.
    public func mostRepeated(limit: Int = 20) throws -> [RepeatedMistake] {
        let statement = try prepare("""
            SELECT lower(original) AS o, lower(replacement) AS r, COUNT(*) AS n
            FROM mistakes GROUP BY o, r ORDER BY n DESC, o ASC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        return try rows(statement) {
            RepeatedMistake(original: Self.text($0, 0) ?? "", replacement: Self.text($0, 1) ?? "",
                            count: Int(sqlite3_column_int64($0, 2)))
        }
    }

    /// All rows, oldest first, as RFC 4180 CSV.
    public func exportCSV() throws -> String {
        let all = try recent(limit: Int.max).reversed()
        let header = "createdAt,appBundleId,appName,sentence,original,replacement,category,message,ruleId,source"
        let lines = all.map { entry in
            [dateFormatter.string(from: entry.createdAt), entry.appBundleId, entry.appName, entry.sentence,
             entry.original, entry.replacement, entry.category.rawValue, entry.message, entry.ruleId ?? "",
             entry.source.rawValue].map(Self.csvField).joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\r\n") + "\r\n"
    }

    public func deleteAll() throws {
        try exec("DELETE FROM mistakes")
    }

    // MARK: SQLite helpers

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // SQLITE_TRANSIENT: SQLite copies the string before the Swift buffer goes away.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func entry(from statement: OpaquePointer?) throws -> MistakeEntry {
        let t = { (column: Int32) in Self.text(statement, column) ?? "" }
        guard let date = dateFormatter.date(from: t(1)),
              let category = SuggestionCategory(rawValue: t(7)),
              let source = SuggestionSource(rawValue: t(10)) else {
            throw MistakeLogError(description: "malformed row \(sqlite3_column_int64(statement, 0))")
        }
        return MistakeEntry(
            id: sqlite3_column_int64(statement, 0), createdAt: date, appBundleId: t(2), appName: t(3),
            sentence: t(4), original: t(5), replacement: t(6), category: category, message: t(8),
            ruleId: Self.text(statement, 9), source: source)
    }

    private func rows<T>(_ statement: OpaquePointer?, map: (OpaquePointer?) throws -> T) throws -> [T] {
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(try map(statement))
            case SQLITE_DONE: return result
            default: throw lastError()
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        return statement
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> MistakeLogError {
        MistakeLogError(description: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }
}
