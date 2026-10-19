import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryLifecycleLimitTests {
    @Test(arguments: TypedRecoveryBoundary.all, ["budget", "deadline", "backoff-budget", "backoff-deadline"])
    func refusalRetainsAttempt(_ boundary: TypedRecoveryBoundary, _ limit: String) async throws {
        let reply = RecoveryReply(status: 503, headers: ["Retry-After": "31"], body: "busy")
        let server = try InProcessHTTPFixture(replies: [reply])
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        let delivered = RecoveryLocked<Int>(0)
        var policy = recoveryPolicy(recorder)
        policy.delayCeiling = 40
        policy.timing.monotonic = { 0 }
        let duringBackoff = limit.hasPrefix("backoff")
        if limit.hasSuffix("budget") { policy.budget = duringBackoff ? 10 : 0 }
        if limit.hasSuffix("deadline") { policy.deadline = duringBackoff ? 10 : 0 }
        let gateway = boundary.provider.gateway(server, policy: policy)
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(broker: broker, model: "fixture", systemPrompt: "seed")
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
        #expect(failure.outcome == .limitRefused)
        let identities = try assertStatusWires(recorder, server: server, replies: [reply])
        #expect(failure.failure.identity == identities[0])
        #expect(failure.history.map(\.identity) == [identities[0]])
        #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        #expect(failure.failure.inspectEvidence().body == Data("busy".utf8))
        #expect(failure.failure.retryAfter == .seconds(31))
        #expect(counter.value.withLock { $0 } == 0)
        #expect(delivered.withLock { $0 } == 0)
        #expect(await session.messages() == [.system("seed")])
        let steps: [RecoveryTransition] =
            duringBackoff
            ? [.attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .limitRefused]
            : [.attemptStarted, .attemptFailed, .limitRefused]
        #expect(
            recorder.events.withLock { $0 }
                == RecoveryLifecycleEvidence(boundary).http(
                    steps,
                    identity: identities[0],
                    reply: reply
                )
        )
    }
}
