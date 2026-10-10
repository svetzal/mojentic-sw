import Foundation
@testable import Mojentic
import Testing

@Suite("Recovery refusal safety")
struct RecoveryAdmissionSafetyTests {
    @Test(
        arguments: RecoveryBoundary.all,
        ["exhausted", "ineligible", "admissionRequired", "limit", "capture", "jitter"],
    )
    func cancellationWinsOverRefusal(_ boundary: RecoveryBoundary, _ phase: String) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: phase == "ineligible" ? 400 : 503, body: "busy"), boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        let handle = RecoveryLocked<Task<LLMGatewayResponse, any Error>?>(nil)
        let launch = AsyncStream<Void>.makeStream()
        var policy = recoveryPolicy(recorder, attempts: phase == "exhausted" ? 1 : 2)
        if phase == "admissionRequired" {
            policy.admission = nil
        }
        if phase == "limit" {
            policy.budget = 0
        }
        let observe = policy.observer
        policy.observer = { event in
            observe?(event)
            if event.transition == .attemptFailed, phase != "capture", phase != "jitter" {
                handle.withLock { $0?.cancel() }
            }
        }
        if phase == "jitter" {
            policy.timing.jitter = { _ in
                handle.withLock { $0?.cancel() }
                return 100
            }
            policy.delayCeiling = 0
        }
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if phase == "capture", case .request(let identity, _, _, _) = event, identity.wireNumber == 2 {
                handle.withLock { $0?.cancel() }
            }
        }
        let gateway = boundary.gateway(server, policy: policy)
        let task = Task {
            var iterator = launch.stream.makeAsyncIterator()
            _ = await iterator.next()
            return try await boundary.complete(gateway)
        }
        handle.withLock { $0 = task }
        launch.continuation.yield(())
        launch.continuation.finish()
        let failure = try await recoveryFailure { _ = try await task.value }
        let first = try #require(recorder.requests.withLock { $0.first })
        #expect(failure.outcome == .cancelled)
        #expect(failure.failure.category == .cancellation)
        #expect(failure.failure.inspectEvidence().cause is CancellationError)
        #expect(failure.failure.identity == first.0)
        #expect(failure.logicalID == first.0.logicalID)
        #expect(failure.history.count == 1)
        #expect(failure.history.first?.identity == first.0)
        #expect(failure.history.first?.category == .http)
        #expect(failure.history.first?.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        #expect(failure.failure.inspectEvidence().body == Data("busy".utf8))
        #expect(failure.failure.progress.rawBytes == 4)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(server.requests.withLock { $0 } == [first.1])
        let prefix: [RecoveryTransition] =
            if phase == "capture" {
                [.attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled]
            } else {
                if phase == "jitter" {
                    [.attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed]
                } else {
                    [.attemptStarted, .attemptFailed]
                }
            }
        #expect(recorder.events.withLock { $0.map(\.transition) } == prefix + [.cancelled])
        #expect(recorder.events.withLock { $0.allSatisfy { $0.identity == first.0 } })
    }

    @Test(arguments: RecoveryBoundary.all, ["content", "reasoning", "tool"])
    func observedSemanticEvidenceRefusesReplay(
        _ boundary: RecoveryBoundary, _ evidence: String,
    ) async throws {
        let content = evidence == "content" ? "observed" : ""
        var message: [String: JSONValue] = ["content": .string(content), "role": "assistant"]
        message[boundary.omlx ? "reasoning_content" : "thinking"] = evidence == "reasoning" ? "thought" : ""
        if evidence == "tool" {
            let arguments: JSONValue = boundary.omlx ? .string("{}") : .object([:])
            message["tool_calls"] = .array([
                [
                    "id": "observed-tool", "type": "function",
                    "function": ["name": "resolve_date", "arguments": arguments],
                ]
            ])
        }
        let envelope: JSONValue =
            if boundary.omlx {
                ["choices": .array([["message": .object(message), "finish_reason": "stop"]])]
            } else {
                ["message": .object(message), "done": true]
            }
        let bytes = try JSONEncoder().encode(envelope)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: #require(String(data: bytes, encoding: .utf8)), truncated: true),
            boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.admission = { _, _ in
            Issue.record("Observed semantic output must never reach caller admission")
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        let first = try #require(recorder.requests.withLock { $0.first })
        #expect(failure.outcome == .ineligible)
        #expect(failure.failure.category == .transport)
        #expect(!failure.failure.eligible)
        #expect(failure.failure.reason == "observedSemanticOutput")
        #expect(failure.failure.inspectEvidence().cause is URLError)
        #expect(failure.failure.inspectEvidence().body == bytes)
        #expect(failure.failure.progress.rawBytes == bytes.count)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(failure.failure.progress.observed.contentBytes == (evidence == "content" ? 8 : 0))
        #expect(failure.failure.progress.observed.reasoningBytes == (evidence == "reasoning" ? 7 : 0))
        #expect(failure.failure.progress.observed.toolFragments == (evidence == "tool" ? 1 : 0))
        #expect(failure.failure.progress.observed.completedToolCalls == (evidence == "tool" ? 1 : 0))
        #expect(failure.failure.identity == first.0)
        #expect(failure.history.count == 1)
        #expect(failure.history.first?.progress == failure.failure.progress)
        #expect(server.requests.withLock { $0 } == [first.1])
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .ineligible,
            ]
        )
    }
}
