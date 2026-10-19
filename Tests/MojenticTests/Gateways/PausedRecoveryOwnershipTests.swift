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

@Suite(.serialized)
struct PausedRecoveryOwnershipTests {
    private enum RetainedStream: Sendable {
        case gateway(AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error>)
        case relay(AsyncThrowingStream<StreamEvent, any Error>)
        case completion(AsyncStream<RecoveryCompletionStreamEvent>)
    }

    struct Scenario: Sendable {
        let path: String
        let phase: String
        let delayIteration: Bool

        init(_ path: String, _ phase: String, delayIteration: Bool = false) {
            self.path = path
            self.phase = phase
            self.delayIteration = delayIteration
        }
    }

    @Test(
        arguments: StreamingBoundary.withAnthropic,
        [
            Scenario("gateway", "keepalive"), Scenario("gateway", "terminal"),
            Scenario("broker", "keepalive"), Scenario("broker", "terminal"),
            Scenario("session", "keepalive"), Scenario("session", "terminal"),
            Scenario("session", "keepalive", delayIteration: true),
            Scenario("session", "terminal", delayIteration: true),
        ],
    )
    func pausedConsumerClosesActiveHTTPBeforeResuming(
        _ boundary: StreamingBoundary,
        _ scenario: Scenario,
    ) async throws {
        let path = scenario.path
        let phase = scenario.phase
        if boundary.single, path == "session" {
            return
        }
        let body = try replyBody(boundary: boundary, phase: phase)
        let server = try InProcessHTTPFixture(replies: [
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
        let cleanup = AsyncStream<Void>.makeStream()
        policy.reportObserver = { value in
            report.withLock { $0 = value }
            cleanup.continuation.yield(())
        }
        let ready = AsyncStream<Void>.makeStream()
        let pause = RecoveryConsumerPause()
        let producerPause = RecoveryConsumerPause()
        let producerFinished = AsyncStream<Void>.makeStream()
        let beforeIteration: @Sendable () async -> Void = {
            if scenario.delayIteration {
                await producerPause.wait()
            }
        }
        let retained = RecoveryLocked<RetainedStream?>(nil)
        let finished: @Sendable (String) -> Void = { type in
            if type == "Mojentic.StreamEvent" {
                producerFinished.continuation.yield(())
            }
        }
        let calls = RecoveryToolCounter()
        let tools: [any LLMTool] = [RecoveryCountingTool(calls: calls)]
        let gateway = boundary.gateway(server, policy)
        let broker = LLMBroker(gateway: gateway)
        let chat = ChatSession(broker: broker, model: "fixture", tools: tools)
        let task = Task {
            try await RecoveryDeliveryScheduling.$beforeSessionIteration.withValue(beforeIteration) {
                try await RecoveryDeliveryScheduling.$finished.withValue(finished) {
                    try await withRecoveryStreamCancellation {
                        let stream = try publicStream(
                            boundary, path: path, gateway: gateway, broker: broker, chat: chat, tools: tools,
                        )
                        retained.withLock { $0 = stream }
                        var wire = wireReady.stream.makeAsyncIterator()
                        _ = await wire.next()
                        ready.continuation.yield(())
                        await pause.wait()
                        withExtendedLifetime(stream) {}
                    }
                }
            }
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        task.cancel()
        // Cleanup and FIN must occur with the public stream and consumer still held.
        var cleanupSignal = cleanup.stream.makeAsyncIterator()
        _ = await cleanupSignal.next()
        let cleaned = try #require(report.withLock { $0 })
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
        producerPause.resume()
        if path == "session" {
            // Both broker and session relays finish before history is inspected.
            // The public stream and its consumer remain held throughout rollback.
            var completion = producerFinished.stream.makeAsyncIterator()
            _ = await completion.next()
            _ = await completion.next()
            #expect(await chat.messages() == [])
        }
        #expect(calls.value.withLock { $0 } == 0)
        try await assertCancellation(try #require(retained.withLock { $0 }), path: path)
        #expect(calls.value.withLock { $0 } == 0)
        pause.resume()
        try await task.value
    }

    private func publicStream(
        _ boundary: StreamingBoundary,
        path: String,
        gateway: any LLMGateway,
        broker: LLMBroker,
        chat: ChatSession,
        tools: [any LLMTool],
    ) throws -> RetainedStream {
        if boundary.single {
            let stream =
                if path == "gateway" {
                    try gateway.completeStreamEventsRecovering(
                        model: "fixture", messages: [], config: .init())
                } else {
                    broker.generateRecoveryStreamEvents(model: "fixture", messages: [])
                }
            return .completion(stream)
        }
        if path == "gateway" {
            return .gateway(
                gateway.streamRecovering(model: "fixture", messages: [], tools: nil, config: .init()))
        }
        return .relay(
            path == "session"
                ? chat.stream("fixture")
                : broker.stream(model: "fixture", messages: [], tools: tools)
        )
    }

    private func assertCancellation(_ stream: RetainedStream, path: String) async throws {
        switch stream {
        case .completion(let stream):
            var iterator = stream.makeAsyncIterator()
            let event = try #require(await iterator.next())
            if case .recoveryFailure(let failure) = event {
                #expect(failure.outcome == .cancelled)
            } else if case .error(.cancelled) = event, path == "broker" {
                // The existing broker relay can expose MojenticError on cancellation.
            } else {
                Issue.record("Expected a recovery cancellation, got \(event)")
            }
            #expect(await iterator.next() == nil)
        case .gateway(let stream):
            do {
                for try await _ in stream {
                    Issue.record("Gateway delivery after cancellation")
                }
                Issue.record("Cancelled gateway completed successfully")
            } catch let failure as RecoveryError {
                #expect(failure.outcome == .cancelled)
            }
        case .relay(let stream):
            do {
                for try await _ in stream {
                    Issue.record("Relay delivery after cancellation")
                }
                Issue.record("Cancelled relay completed successfully")
            } catch let failure as RecoveryError {
                #expect(failure.outcome == .cancelled)
            } catch MojenticError.cancelled {}
        }
    }

    private func assertCapturedAttempt(
        recorder: RecoveryRecorder,
        server: InProcessHTTPFixture,
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
