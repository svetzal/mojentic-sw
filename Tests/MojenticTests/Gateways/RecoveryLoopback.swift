import Foundation
import Testing

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// One deliberately scripted HTTP response, including partial-body evidence.
struct RecoveryReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body: String
    var truncated = false
    var hold = false
    var splitAt: Int?
}

/// A real loopback HTTP server with deterministic request/active-send signals.
///
/// Only the condition protecting held replies is shared with the server thread.
final class RecoveryLoopback: @unchecked Sendable {
    let url: URL
    let requests = RecoveryLocked<[Data]>([])
    private let activeClient = RecoveryLocked<Int32?>(nil)
    let arrivals: AsyncStream<Int>
    private let arrival: AsyncStream<Int>.Continuation
    private let socketFD: Int32
    private let replies: [RecoveryReply]
    private let condition = NSCondition()
    private let requestCondition = NSCondition()
    private var released = false

    init(
        replies: [RecoveryReply] = [
            RecoveryReply(status: 503, body: "credential-and-payload-sentinel"),
            RecoveryReply(
                body: #"""
                    {"message":{"content":"recovered","thinking":"reasoning"},"done":true}
                    """#
            ),
        ]
    ) throws {
        self.replies = replies
        let stream = AsyncStream<Int>.makeStream()
        arrivals = stream.stream
        arrival = stream.continuation
        #if os(Linux)
            socketFD = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            socketFD = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        let descriptor = socketFD
        #expect(descriptor >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)
        #expect(listen(descriptor, 8) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        #expect(nameResult == 0)
        url = try #require(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"))
        // A weak owner prevents the blocking accept loop from retaining the fixture.
        let threadDescriptor = dup(descriptor)
        Thread.detachNewThread { [weak self] in
            defer { close(threadDescriptor) }
            while true {
                let client = accept(threadDescriptor, nil, nil)
                if client < 0 {
                    break
                }
                self?.serve(client)
                close(client)
            }
        }
    }

    deinit {
        release()
        shutdown(socketFD, Int32(SHUT_RDWR))
        close(socketFD)
        arrival.finish()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForRequest(_ number: Int) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        requestCondition.lock()
        defer { requestCondition.unlock() }
        while requests.withLock({ $0.count }) < number {
            if !requestCondition.wait(until: deadline) {
                return false
            }
        }
        return true
    }

    /// Observes the client's FIN without releasing a held reply or consuming data.
    func waitForPeerClose() -> Bool {
        guard let client = activeClient.withLock({ $0 }) else { return false }
        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 2000) > 0 else { return false }
        var byte: UInt8 = 0
        return recv(client, &byte, 1, Int32(MSG_PEEK)) == 0
    }

    private func serve(_ client: Int32) {
        activeClient.withLock { $0 = client }
        defer { activeClient.withLock { $0 = nil } }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var boundary: Range<Data.Index>?
        var bodyLength = 0
        while true {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 {
                return
            }
            request.append(contentsOf: buffer.prefix(count))
            if boundary == nil, let found = request.range(of: Data("\r\n\r\n".utf8)) {
                boundary = found
                let headers = String(bytes: request[..<found.lowerBound], encoding: .utf8) ?? ""
                let field = headers.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }
                bodyLength = field.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            }
            if let boundary, request.count >= boundary.upperBound + bodyLength {
                break
            }
        }
        guard let boundary else { return }
        let body = Data(request[boundary.upperBound...])
        let index = requests.withLock { requests in
            requests.append(body)
            return requests.count - 1
        }
        requestCondition.lock()
        requestCondition.broadcast()
        requestCondition.unlock()
        let reply = replies[min(index, replies.count - 1)]
        let data = Data(reply.body.utf8)
        var header =
            "HTTP/1.1 \(reply.status) Fixture\r\nContent-Length: \(data.count + (reply.truncated ? 20 : 0))"
        header += "\r\nConnection: close\r\nContent-Type: application/json\r\n"
        for (name, value) in reply.headers {
            header += "\(name): \(value)\r\n"
        }
        write(Data((header + "\r\n").utf8), to: client)
        let split = reply.splitAt ?? (reply.hold && !reply.truncated ? data.count / 2 : data.count)
        write(Data(data.prefix(split)), to: client)
        arrival.yield(index + 1)
        if reply.hold {
            condition.lock()
            while !released {
                condition.wait()
            }
            condition.unlock()
            if split < data.count {
                write(Data(data.dropFirst(split)), to: client)
            }
        }
    }

    private func write(_ data: Data, to client: Int32) {
        #if !os(Linux)
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                    let count = send(
                        client,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset,
                        Int32(MSG_NOSIGNAL),
                    )
                #else
                    let count = send(client, bytes.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
                #endif
                if count <= 0 {
                    break
                }
                offset += count
            }
        }
    }
}
