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
/// Listener ownership and reply state are synchronized with the server thread.
final class RecoveryLoopback: @unchecked Sendable {
    let url: URL
    let requests = RecoveryLocked<[Data]>([])
    let requestHeaders = RecoveryLocked<[String]>([])
    private let activeClient = RecoveryLocked<Int32?>(nil)
    let arrivals: AsyncStream<Int>
    private let arrival: AsyncStream<Int>.Continuation
    private let listener = RecoveryLocked<Int32?>(nil)
    private let replies: [RecoveryReply]
    private let condition = NSCondition()
    private let requestCondition = NSCondition()
    private var released = false
    // Guarded by deliveryCondition. `nil` until a recovery client reports deliveries.
    private let deliveryCondition = NSCondition()
    private var deliveredBytes: Int?

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
            let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        try #require(descriptor >= 0, "socket failed with errno \(errno)")
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bindResult == 0, "bind failed with errno \(errno)")
        try #require(listen(descriptor, 8) == 0, "listen failed with errno \(errno)")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        try #require(nameResult == 0, "getsockname failed with errno \(errno)")
        url = try #require(URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"))
        // The accept thread owns the listener until shutdown unblocks it. Keeping
        // it open until accept returns prevents descriptor reuse during teardown;
        // a second descriptor for the same socket is unnecessary.
        // Closure and shutdown share ownership state, so an accept error cannot
        // leave teardown addressing a descriptor that another socket has reused.
        // A weak owner prevents the blocking accept loop from retaining the fixture.
        listener.withLock { $0 = descriptor }
        transferred = true
        Thread.detachNewThread { [weak self, listener] in
            defer {
                listener.withLock { current in
                    if let current { close(current) }
                    current = nil
                }
            }
            while true {
                let client = accept(descriptor, nil, nil)
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
        listener.withLock { current in
            if let current { shutdown(current, Int32(SHUT_RDWR)) }
        }
        arrival.finish()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    /// Enables delivery reports, so a truncated reply closes only after the client received its bytes.
    ///
    /// Apple URLSession can discard body bytes that it has read but not yet passed to
    /// its delegate when the end of stream arrives in the same read. A real server
    /// that drops a connection mid-body does so after the client saw the partial
    /// body; this handshake keeps that ordering under parallel test load.
    func expectDeliveryReports() {
        deliveryCondition.lock()
        deliveredBytes = deliveredBytes ?? 0
        deliveryCondition.unlock()
    }

    /// Records body bytes that the client's wire observer received.
    func reportDelivery(_ count: Int) {
        deliveryCondition.lock()
        deliveredBytes = (deliveredBytes ?? 0) + count
        deliveryCondition.broadcast()
        deliveryCondition.unlock()
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
        // The client finishes each attempt before it sends the next request.
        deliveryCondition.lock()
        if deliveredBytes != nil {
            deliveredBytes = 0
        }
        deliveryCondition.unlock()
        let receivedHeaders = String(bytes: request[..<boundary.lowerBound], encoding: .utf8) ?? ""
        requestHeaders.withLock { $0.append(receivedHeaders) }
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
        if reply.truncated {
            waitForDelivery(of: data.count, from: client)
        }
    }

    /// Holds the close until the client reports `count` body bytes, gives up, or times out.
    private func waitForDelivery(of count: Int, from client: Int32) {
        let deadline = Date().addingTimeInterval(5)
        deliveryCondition.lock()
        defer { deliveryCondition.unlock() }
        while let delivered = deliveredBytes, delivered < count, Date() < deadline {
            if peerClosed(client) {
                return
            }
            _ = deliveryCondition.wait(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    private func peerClosed(_ client: Int32) -> Bool {
        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        var byte: UInt8 = 0
        return recv(client, &byte, 1, Int32(MSG_PEEK)) <= 0
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
