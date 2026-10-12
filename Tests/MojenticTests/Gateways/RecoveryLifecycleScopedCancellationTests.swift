import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryLifecycleScopedCancellationTests {
    @Test(arguments: RecoveryLifecycleStreamCase.all, ["active", "admission", "backoff"])
    func retainedPublicConsumer(_ scenario: RecoveryLifecycleStreamCase, _ phase: String) async throws {
        let boundary = scenario.boundary
        let reply =
            phase == "active"
            ? RecoveryReply(body: "\n", truncated: true, hold: true)
            : RecoveryReply(status: 503, body: "busy")
        let server = try RecoveryLoopback(replies: [reply])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let ready = AsyncStream<Void>.makeStream()
        let created = AsyncStream<Void>.makeStream()
        let cleanup = AsyncStream<CompletionRecoveryReport>.makeStream()
        let decisions = AsyncStream<RecoveryAdmission>.makeStream()
        let blocked = AsyncStream<Void>.makeStream()
        let pause = RecoveryConsumerPause()
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { cleanup.continuation.yield($0) }
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
        let gateway = boundary.gateway(server, policy)
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(broker: broker, model: "fixture", systemPrompt: "seed")
        let task = Task {
            try await withRecoveryStreamCancellation {
                let consumer = try scenario.consumer(gateway, broker: broker, session: session)
                created.continuation.yield(())
                await pause.wait()
                return consumer
            }
        }
        var initialized = created.stream.makeAsyncIterator()
        _ = await initialized.next()
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        task.cancel()
        var reports = cleanup.stream.makeAsyncIterator()
        let report = try #require(await reports.next())
        #expect(report.history.count == 1)
        #expect(report.progress == lifecycleProgress(reply))
        if phase == "active" { #expect(server.waitForPeerClose()) }
        pause.resume()
        let consumer = try await task.value
        var caught: (any Error)?
        do {
            while let value = try await consumer.next() { Issue.record("Unexpected delivery: \(value)") }
        } catch { caught = error }
        let error = try #require(caught)
        if let failure = error as? RecoveryError {
            #expect(failure.outcome == .cancelled)
            #expect(failure.failure.inspectEvidence().cause is CancellationError)
            #expect(failure.history.count == 1)
            #expect(failure.failure.progress == lifecycleProgress(reply))
            #expect(failure.failure.identity == recorder.requests.withLock { $0.first?.0 })
        } else {
            // A cancelled broker single-turn relay preserves its existing public cancellation case.
            #expect(boundary.single && scenario.path == "broker")
            guard case MojenticError.cancelled = error else {
                Issue.record("Unexpected cancellation cause: \(error)")
                return
            }
        }
        #expect(await session.messages() == [.system("seed")])
        let request = try #require(recorder.requests.withLock { $0.first })
        #expect(server.requests.withLock { $0 } == [request.1])
        #expect(request.0.wireNumber == 1)
        try assertCancellationLifecycle(
            recorder,
            lifecycle: RecoveryLifecycleEvidence(boundary),
            reply: reply,
            phase: phase
        )
    }
}
