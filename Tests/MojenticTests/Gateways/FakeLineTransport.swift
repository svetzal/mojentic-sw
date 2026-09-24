import Foundation

@testable import Mojentic

/// Records what a ``FakeLineTransport`` was asked to send and whether its
/// stream was terminated.
actor TransportRecorder {
    private(set) var bodies: [JSONValue] = []
    private(set) var terminations = 0
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    func record(body: JSONValue) {
        bodies.append(body)
    }

    func recordTermination() {
        terminations += 1
        let waiters = terminationWaiters
        terminationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Suspend until the transport stream has been terminated at least once.
    func waitForTermination() async {
        if terminations > 0 { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }
}

/// Scripted stand-in for the HTTP line-streaming boundary.
///
/// Yields `lines` in order. When `holdOpen` is true the stream never
/// finishes on its own, so only consumer cancellation can end it.
struct FakeLineTransport: LineStreamingTransport {
    let lines: [String]
    var holdOpen = false
    var failure: MojenticError?
    let recorder = TransportRecorder()

    init(lines: [String] = [], holdOpen: Bool = false, failure: MojenticError? = nil) {
        self.lines = lines
        self.holdOpen = holdOpen
        self.failure = failure
    }

    func streamLines(
        url _: URL,
        body: some Encodable,
        headers _: [String: String]
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let data = try JSONEncoder().encode(body)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        await recorder.record(body: value)
        if let failure {
            throw failure
        }
        let lines = self.lines
        let holdOpen = self.holdOpen
        let recorder = self.recorder
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in
                Task { await recorder.recordTermination() }
            }
            for line in lines {
                continuation.yield(line)
            }
            if !holdOpen {
                continuation.finish()
            }
        }
    }
}

/// Drain a gateway stream, ignoring its events.
func drain(_ stream: AsyncThrowingStream<GatewayStreamEvent, any Error>) async throws {
    for try await _ in stream {}
}
