import Foundation
@testable import Mojentic
import Testing

/// Unlike AsyncStream.next(), this pause does not resume when its task is cancelled.
final class RecoveryConsumerPause: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if resume {
                continuation.resume()
            }
        }
    }

    func resume() {
        let saved = lock.withLock {
            released = true
            let saved = continuation
            continuation = nil
            return saved
        }
        saved?.resume()
    }
}

struct PausedRecoveryOwnershipTests {
    @Test(
        arguments: StreamingBoundary.all,
        [
            ("gateway", "keepalive"), ("gateway", "terminal"), ("broker", "keepalive"),
            ("broker", "terminal"), ("session", "keepalive"), ("session", "terminal"),
        ],
    )
    func pausedConsumerClosesActiveHTTPBeforeResuming(
        _ boundary: StreamingBoundary,
        _ scenario: (String, String),
    ) async throws {
        let (path, phase) = scenario
        if boundary.single, path == "session" {
            return
        }
        let body = try replyBody(boundary: boundary, phase: phase)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(
                headers: ["X-Request-ID": "original-header"],
                body: body,
                truncated: phase == "keepalive",
                hold: phase == "keepalive",
            )
        ])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let report = RecoveryLocked<CompletionRecoveryReport?>(nil)
        let wireReady = AsyncStream<Void>.makeStream()
        var policy = recoveryPolicy(recorder)
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if case .body = event {
                wireReady.continuation.yield(())
            }
        }
        policy.reportObserver = { value in report.withLock { $0 = value } }
        let ready = AsyncStream<Void>.makeStream()
        let pause = RecoveryConsumerPause()
        let gateway = boundary.gateway(server, policy)
        let broker = LLMBroker(gateway: gateway)
        let chat = ChatSession(broker: broker, model: "fixture")
        let task = Task {
            try await withRecoveryStreamCancellation {
                if boundary.single {
                    let stream: AsyncStream<RecoveryCompletionStreamEvent> =
                        if path == "gateway" {
                            try gateway.completeStreamEventsRecovering(
                                model: "fixture", messages: [], config: .init(),
                            )
                        } else {
                            broker.generateRecoveryStreamEvents(model: "fixture", messages: [])
                        }
                    var wire = wireReady.stream.makeAsyncIterator()
                    _ = await wire.next()
                    ready.continuation.yield(())
                    await pause.wait()
                    withExtendedLifetime(stream) {}
                } else if path == "gateway" {
                    let stream = gateway.streamRecovering(
                        model: "fixture", messages: [], tools: nil, config: .init(),
                    )
                    var wire = wireReady.stream.makeAsyncIterator()
                    _ = await wire.next()
                    ready.continuation.yield(())
                    await pause.wait()
                    withExtendedLifetime(stream) {}
                } else {
                    let stream =
                        if path == "session" {
                            chat.stream("fixture")
                        } else {
                            broker.stream(model: "fixture", messages: [])
                        }
                    var wire = wireReady.stream.makeAsyncIterator()
                    _ = await wire.next()
                    ready.continuation.yield(())
                    await pause.wait()
                    withExtendedLifetime(stream) {}
                }
            }
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        task.cancel()
        // Cleanup and FIN must occur with the public stream and consumer still held.
        let cleaned = try await awaitCleanup(report)
        #expect(cleaned != nil)
        if phase == "keepalive" {
            #expect(server.waitForPeerClose())
        }
        let transitions = recorder.events.withLock { $0.map(\.transition) }
        #expect(transitions == [.attemptStarted, .attemptFailed, .cancelled])
        assertCapturedAttempt(
            recorder: recorder,
            server: server,
            cleaned: cleaned,
            body: body,
            phase: phase,
            single: boundary.single,
        )
        pause.resume()
        try await task.value
        if path == "session" {
            #expect(await chat.messages().isEmpty)
        }
    }

    private func assertCapturedAttempt(
        recorder: RecoveryRecorder,
        server: RecoveryLoopback,
        cleaned: CompletionRecoveryReport?,
        body: String,
        phase: String,
        single: Bool,
    ) {
        #expect(cleaned?.history.count == 1)
        #expect(cleaned?.progress.headersReceived == true)
        #expect(cleaned?.progress.rawBytes == body.utf8.count)
        #expect(cleaned?.progress.delivered.completedToolCalls == 0)
        #expect(cleaned?.progress.observed.contentBytes == (phase == "keepalive" ? 0 : 2))
        #expect(cleaned?.progress.observed.reasoningBytes == (phase == "keepalive" ? 0 : 3))
        #expect(cleaned?.progress.observed.toolFragments == (phase == "keepalive" || single ? 0 : 1))
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        #expect(cleaned?.identity == requests.first?.0)
        #expect(cleaned?.logicalID == requests.first?.0.logicalID)
        #expect(cleaned?.identity?.wireNumber == 1)
        #expect(cleaned?.history.first?.identity == requests.first?.0)
        #expect(cleaned?.history.first?.status == 200)
        #expect(cleaned?.history.first?.category == .cancellation)
        #expect(cleaned?.history.first?.inspectEvidence().cause != nil)
        let fields = requests.first.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.1) }
        #expect(fields?.objectValue?["model"] == "fixture")
        #expect(fields?.objectValue?["stream"] == true)
        #expect(recorder.events.withLock { $0.allSatisfy { $0.identity == cleaned?.identity } })
        #expect(cleaned?.history.first?.inspectEvidence().body == Data(body.utf8))
        #expect(
            cleaned?.history.first?.inspectEvidence().headers.contains {
                $0.key.lowercased() == "x-request-id" && $0.value == "original-header"
            } == true
        )
    }

    private func awaitCleanup(
        _ report: RecoveryLocked<CompletionRecoveryReport?>
    ) async throws -> CompletionRecoveryReport? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while report.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return report.withLock { $0 }
    }

    private func replyBody(boundary: StreamingBoundary, phase: String) throws -> String {
        if phase == "keepalive" {
            boundary.omlx ? ": keepalive\n\n" : "\n"
        } else {
            try boundary.frame(
                content: "é",
                reasoning: "ré",
                tool: !boundary.single,
                done: true,
                metrics: true,
            )
        }
    }
}
