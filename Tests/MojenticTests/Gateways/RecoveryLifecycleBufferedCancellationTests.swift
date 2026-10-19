import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryLifecycleBufferedCancellationTests {
    @Test(
        arguments: TypedRecoveryBoundary.all.filter { !$0.path.streaming },
        ["active", "admission", "backoff"]
    )
    func cancellationThroughCaller(_ boundary: TypedRecoveryBoundary, _ phase: String) async throws {
        let reply =
            phase == "active"
            ? RecoveryReply(body: "\n", truncated: true, hold: true)
            : RecoveryReply(status: 503, body: "busy")
        let server = try InProcessHTTPFixture(replies: [reply])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        let delivered = RecoveryLocked<Int>(0)
        let ready = AsyncStream<Void>.makeStream()
        let decisions = AsyncStream<RecoveryAdmission>.makeStream()
        let blocked = AsyncStream<Void>.makeStream()
        var policy = recoveryPolicy(recorder)
        let capture = policy.wireObserver
        if phase == "active" {
            policy.wireObserver = { event in
                try capture?(event)
                if case .body = event { ready.continuation.yield(()) }
            }
        } else if phase == "admission" {
            policy.admission = { _, _ in
                ready.continuation.yield(())
                return decisions.stream
            }
        } else {
            policy.timing.sleep = { _ in
                ready.continuation.yield(())
                var iterator = blocked.stream.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
        }
        let gateway = boundary.provider.gateway(server, policy: policy)
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(broker: broker, model: "fixture", systemPrompt: "seed")
        let task = Task {
            try await boundary.failure(
                gateway: gateway,
                session: session,
                broker: broker,
                tool: RecoveryCountingTool(calls: counter),
                delivered: delivered
            )
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        task.cancel()
        let failure = try #require(await task.value as? RecoveryError)
        #expect(failure.outcome == .cancelled)
        #expect(failure.failure.inspectEvidence().cause is CancellationError)
        #expect(failure.history.count == 1)
        #expect(failure.failure.progress == lifecycleProgress(reply))
        #expect(failure.failure.inspectEvidence().body == Data(reply.body.utf8))
        #expect(delivered.withLock { $0 } == 0)
        #expect(counter.value.withLock { $0 } == 0)
        #expect(await session.messages() == [.system("seed")])
        if phase == "active" { #expect(server.waitForPeerClose()) }
        let request = try #require(recorder.requests.withLock { $0.first })
        #expect(server.requests.withLock { $0 } == [request.1])
        #expect(failure.failure.identity == request.0)
        #expect(failure.history.first?.identity == request.0)
        #expect(request.0.wireNumber == 1)
        if boundary.path == .sessionImages {
            try assertTypedImageRequest(request.1, provider: boundary.provider)
        }
        try assertCancellationLifecycle(
            recorder,
            lifecycle: RecoveryLifecycleEvidence(boundary),
            reply: reply,
            phase: phase
        )
    }
}
