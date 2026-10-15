import Core
import Foundation
import OSLog

private let log = Logger(subsystem: "com.danielmaymon.WritingAssistant", category: "harper")

struct HarperError: Error, CustomStringConvertible {
    let description: String
}

/// Tier 1: talks to a `harper-ls --stdio` helper over LSP (decision 0005). Each sentence is opened as its
/// own short-lived document, so results can't mix. The helper is restarted on the next check if it dies.
actor HarperClient {
    private var process: Process?
    private var input: FileHandle?
    private var nextId = 1
    private var nextDocument = 1
    private var responses: [Int: CheckedContinuation<Data, Error>] = [:]
    private var diagnostics: [String: CheckedContinuation<[LSPDiagnostic], Error>] = [:]
    private(set) var starts = 0

    static var executableURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/harper-ls")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        #if DEBUG
        // Plain Xcode builds don't run scripts/install.sh, which copies the helper in.
        for path in ["/opt/homebrew/bin/harper-ls", "/usr/local/bin/harper-ls"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        #endif
        return nil
    }

    var pid: Int32? { process?.processIdentifier }

    func check(_ sentence: Sentence) async throws -> [Suggestion] {
        try await startIfNeeded()
        let uri = "file:///writing-assistant/\(nextDocument).txt"
        nextDocument += 1

        let found = try await awaitDiagnostics(for: uri) {
            try self.notify("textDocument/didOpen", [
                "textDocument": ["uri": uri, "languageId": "plaintext", "version": 1, "text": sentence.text],
            ])
        }
        var result: [Suggestion] = []
        for diagnostic in found {
            let body = try await request("textDocument/codeAction", [
                "textDocument": ["uri": uri],
                "range": try jsonObject(diagnostic.range),
                "context": ["diagnostics": [try jsonObject(diagnostic)]],
            ])
            let actions = (try? JSONDecoder().decode(Response<[LSPCodeAction]>.self, from: body).result) ?? nil
            if let made = suggestion(from: diagnostic, replacements: quickfixReplacements(actions ?? []), in: sentence) {
                result.append(made)
            }
        }
        try? notify("textDocument/didClose", ["textDocument": ["uri": uri]])
        return result
    }

    // MARK: Process

    private func startIfNeeded() async throws {
        if process?.isRunning == true { return }
        guard let url = Self.executableURL else { throw HarperError(description: "harper-ls not found") }

        let process = Process()
        process.executableURL = url
        process.arguments = ["--stdio"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Harper's own logs may quote the text being checked; drop them (CLAUDE.md: no user text in logs).
        process.standardError = FileHandle.nullDevice

        let reader = FrameReader { [weak self] body in
            Task { await self?.receive(body) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.feed(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.died() }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        starts += 1
        log.info("harper-ls started (start #\(self.starts, privacy: .public))")

        _ = try await request("initialize", ["processId": Int(getpid()), "rootUri": NSNull(), "capabilities": [:]])
        try notify("initialized", [:])
    }

    private func died() {
        log.error("harper-ls exited")
        process = nil
        input = nil
        failAll(HarperError(description: "harper-ls exited"))
    }

    private func failAll(_ error: Error) {
        let pendingResponses = responses.values, pendingDiagnostics = diagnostics.values
        responses = [:]
        diagnostics = [:]
        pendingResponses.forEach { $0.resume(throwing: error) }
        pendingDiagnostics.forEach { $0.resume(throwing: error) }
    }

    // MARK: Messages

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw HarperError(description: "harper-ls not running") }
        let body = try JSONSerialization.data(withJSONObject: message)
        try input.write(contentsOf: LSPFrame.encode(body))
    }

    private func notify(_ method: String, _ params: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> Data {
        let id = nextId
        nextId += 1
        return try await withTimeout(id: id) {
            try await withCheckedThrowingContinuation { continuation in
                self.responses[id] = continuation
                do {
                    try self.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                } catch {
                    self.responses[id] = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func awaitDiagnostics(for uri: String, after send: @escaping () throws -> Void) async throws -> [LSPDiagnostic] {
        try await withCheckedThrowingContinuation { continuation in
            self.diagnostics[uri] = continuation
            do {
                try send()
            } catch {
                self.diagnostics[uri] = nil
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.timeOutDiagnostics(uri)
            }
        }
    }

    private func withTimeout(id: Int, _ body: () async throws -> Data) async throws -> Data {
        let timer = Task {
            try? await Task.sleep(for: .seconds(3))
            self.timeOutResponse(id)
        }
        defer { timer.cancel() }
        return try await body()
    }

    private func timeOutResponse(_ id: Int) {
        responses.removeValue(forKey: id)?.resume(throwing: HarperError(description: "harper-ls timed out"))
    }

    private func timeOutDiagnostics(_ uri: String) {
        diagnostics.removeValue(forKey: uri)?.resume(throwing: HarperError(description: "harper-ls timed out"))
    }

    private func receive(_ body: Data) {
        guard let header = try? JSONDecoder().decode(Header.self, from: body) else { return }
        switch (header.id, header.method) {
        case (let id?, nil):
            // A response to one of our requests.
            if case .int(let number) = id { responses.removeValue(forKey: number)?.resume(returning: body) }
        case (let id?, _?):
            // A request from the server (configuration, capability registration): answer with null.
            try? send(["jsonrpc": "2.0", "id": id.json, "result": NSNull()])
        case (nil, "textDocument/publishDiagnostics"):
            guard let params = try? JSONDecoder().decode(Notification<DiagnosticParams>.self, from: body).params,
                  let continuation = diagnostics.removeValue(forKey: params.uri) else { return }
            continuation.resume(returning: params.diagnostics)
        default:
            break
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

// MARK: Wire types

private enum MessageId: Decodable {
    case int(Int), string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) { self = .int(number) } else { self = .string(try container.decode(String.self)) }
    }

    var json: Any {
        switch self {
        case .int(let number): number
        case .string(let text): text
        }
    }
}

private struct Header: Decodable {
    let id: MessageId?
    let method: String?
}

private struct Response<T: Decodable>: Decodable {
    let result: T?
}

private struct Notification<T: Decodable>: Decodable {
    let params: T
}

private struct DiagnosticParams: Decodable {
    let uri: String
    let diagnostics: [LSPDiagnostic]
}

/// Splits stdout into messages. The pipe's handler calls `feed` from one queue at a time, in order;
/// the lock only guards against a late call during shutdown.
private final class FrameReader: @unchecked Sendable {
    private var decoder = LSPFrameDecoder()
    private let lock = NSLock()
    private let deliver: @Sendable (Data) -> Void

    init(deliver: @escaping @Sendable (Data) -> Void) {
        self.deliver = deliver
    }

    func feed(_ data: Data) {
        let bodies = lock.withLock { decoder.append(data) }
        bodies.forEach(deliver)
    }
}
