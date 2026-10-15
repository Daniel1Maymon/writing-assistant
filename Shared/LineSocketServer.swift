import Foundation

/// A tiny local Unix-socket server for test harnesses (decision 0006): each connection sends one line,
/// gets one line back, and is closed. Used by the debug app and by FixtureApp.
final class LineSocketServer: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (String) async -> String
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "LineSocketServer")

    init(path: String, handler: @escaping @Sendable (String) async -> String) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source
    }

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        let handler = handler
        Thread.detachNewThread {
            var line = Data()
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {
                line.append(byte)
            }
            let request = String(decoding: line, as: UTF8.self)
            let done = DispatchSemaphore(value: 0)
            let reply = Box()
            Task {
                reply.value = await handler(request)
                done.signal()
            }
            done.wait()
            let data = Data((reply.value + "\n").utf8)
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(client)
        }
    }

    private final class Box: @unchecked Sendable {
        var value = ""
    }
}
