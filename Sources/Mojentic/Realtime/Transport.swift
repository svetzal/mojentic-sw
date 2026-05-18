import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One frame of duplex transport traffic.
public enum TransportFrame: Sendable, Hashable {
    /// Text payload (typically JSON event).
    case text(String)
    /// Binary payload (typically base64-encoded audio is sent as text, but
    /// some providers binary-frame the audio directly).
    case data(Data)
}

/// Duplex transport contract used by realtime sessions.
///
/// Implementations own the underlying socket / pipe and serialise reads
/// and writes correctly. The default ``URLSessionWebSocketTransport``
/// wraps `URLSessionWebSocketTask`.
public protocol RealtimeTransport: Sendable {
    /// Send a text frame.
    func send(text: String) async throws

    /// Send a binary frame.
    func send(data: Data) async throws

    /// Yield server-pushed frames in arrival order.
    ///
    /// The stream terminates when the transport closes.
    func receive() -> AsyncThrowingStream<TransportFrame, any Error>

    /// Close the transport idempotently.
    func close() async
}

/// `URLSessionWebSocketTask`-backed transport.
///
/// Read/write coordination is funnelled through this actor so reads and
/// writes against the same task can't race. Cancellation flows from the
/// outer `Task` into the underlying task via `receive()`'s onTermination.
public actor URLSessionWebSocketTransport: RealtimeTransport {
    private let task: URLSessionWebSocketTask
    private var closed = false

    /// Wrap an already-resumed websocket task.
    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    /// Convenience initialiser that opens a websocket against `url` with
    /// the supplied request headers.
    public init(url: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        self.task = session.webSocketTask(with: request)
        self.task.resume()
    }

    /// Send a text frame.
    public func send(text: String) async throws {
        try await sendOrThrow(.string(text))
    }

    /// Send a binary frame.
    public func send(data: Data) async throws {
        try await sendOrThrow(.data(data))
    }

    /// Stream inbound frames.
    public nonisolated func receive() -> AsyncThrowingStream<TransportFrame, any Error> {
        let task = self.task
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            continuation.yield(.text(text))
                        case .data(let data):
                            continuation.yield(.data(data))
                        @unknown default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MojenticError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// Close the websocket.
    public func close() async {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
    }

    private func sendOrThrow(_ message: URLSessionWebSocketTask.Message) async throws {
        if closed {
            throw MojenticError.transport(message: "transport already closed")
        }
        do {
            try await task.send(message)
        } catch is CancellationError {
            throw MojenticError.cancelled
        } catch {
            throw MojenticError.transport(message: error.localizedDescription)
        }
    }
}
