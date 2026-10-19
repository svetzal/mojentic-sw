import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryLifecycleFailureTests {
    @Test(arguments: TypedRecoveryBoundary.all)
    func malformedAtEveryPublicPath(_ boundary: TypedRecoveryBoundary) async throws {
        let body =
            boundary.path.streaming
            ? (boundary.provider.omlx ? "data: {bad}\n\n" : "{bad}\n") : "{bad}"
        let reply = RecoveryReply(body: body)
        let server = try InProcessHTTPFixture(replies: [reply])
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        let gateway = boundary.provider.gateway(server, policy: recoveryPolicy(recorder))
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(broker: broker, model: "fixture", systemPrompt: "seed")
        let delivered = RecoveryLocked<Int>(0)
        let failure = try #require(
            await withRecoveryStreamCancellation {
                try await boundary.failure(
                    gateway: gateway,
                    session: session,
                    broker: broker,
                    tool: RecoveryCountingTool(calls: counter),
                    delivered: delivered
                )
            } as? RecoveryError
        )
        let identities = try assertStatusWires(recorder, server: server, replies: [reply])
        #expect(failure.failure.identity == identities[0])
        #expect(failure.history.map(\.identity) == [identities[0]])
        #expect(failure.failure.inspectEvidence().body == Data(body.utf8))
        #expect(delivered.withLock { $0 } == 0)
        #expect(counter.value.withLock { $0 } == 0)
        #expect(await session.messages() == [.system("seed")])
        #expect(
            recorder.events.withLock { $0 }
                == RecoveryLifecycleEvidence(boundary).terminal(
                    identity: identities[0],
                    progress: lifecycleProgress(reply),
                    category: .protocolFailure,
                    outcome: boundary.path.streaming ? .malformedResponse : .ineligible,
                    reason: "malformedResponse",
                    phase: boundary.path.streaming ? .streaming : .decoding
                )
        )
    }

    @Test(arguments: TypedRecoveryBoundary.all)
    func cancellationAtRequestCapturePreventsDispatch(_ boundary: TypedRecoveryBoundary) async throws {
        let server = try InProcessHTTPFixture(replies: [boundary.reply(length: false)])
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        var policy = recoveryPolicy(recorder)
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if case .request = event { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let gateway = boundary.provider.gateway(server, policy: policy)
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(broker: broker, model: "fixture", systemPrompt: "seed")
        let delivered = RecoveryLocked<Int>(0)
        let task = Task {
            try await withRecoveryStreamCancellation {
                try await boundary.failure(
                    gateway: gateway,
                    session: session,
                    broker: broker,
                    tool: RecoveryCountingTool(calls: counter),
                    delivered: delivered
                )
            }
        }
        let failure = try #require(await task.value as? RecoveryError)
        let candidate = try #require(recorder.requests.withLock { $0.first?.0 })
        #expect(recorder.requests.withLock { $0.count } == 1)
        #expect(server.requests.withLock { $0.isEmpty })
        #expect(recorder.wires.withLock { $0.count } == 1)
        #expect(failure.history.isEmpty)
        #expect(failure.failure.identity == nil)
        #expect(failure.failure.inspectEvidence().cause is CancellationError)
        #expect(delivered.withLock { $0 } == 0)
        #expect(counter.value.withLock { $0 } == 0)
        #expect(await session.messages() == [.system("seed")])
        #expect(
            recorder.events.withLock { $0 }
                == RecoveryLifecycleEvidence(boundary).undispatched(
                    logicalID: candidate.logicalID,
                    outcome: .cancelled,
                    category: .cancellation,
                    reason: "callerCancelled"
                )
        )
    }
}
