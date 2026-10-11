import Foundation
@testable import Mojentic
import Testing

struct StreamingRecoveryTimingTests {
    @Test(arguments: StreamingBoundary.withAnthropic, ["2", "Thu, 01 Jan 1970 00:00:03 GMT", "invalid"])
    func retryAfterPreservesPolicy(_ boundary: StreamingBoundary, _ header: String) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 429, headers: ["Retry-After": header], body: "busy"),
            RecoveryReply(body: boundary.frame(content: "ok", done: true)),
        ])
        let recorder = RecoveryRecorder()
        let sleeps = RecoveryLocked<[TimeInterval]>([])
        var policy = recoveryPolicy(recorder)
        policy.baseDelay = 1
        policy.timing.jitter = { $0 }
        policy.timing.wall = { Date(timeIntervalSince1970: 0) }
        policy.timing.sleep = { delay in sleeps.withLock { $0.append(delay) } }
        try await boundary.consume(boundary.gateway(server, policy))
        #expect(sleeps.withLock { $0 } == [header == "2" ? 2 : header == "invalid" ? 1 : 3])
        #expect(server.requests.withLock { $0.count } == 2)
        assertRecoveryRequests(recorder, server)
    }

    @Test(arguments: StreamingBoundary.withAnthropic, [false, true])
    func retryAfterRefusal(
        _ boundary: StreamingBoundary,
        _ budget: Bool,
    ) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 429, headers: ["Retry-After": "31"], body: "busy")
        ])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.timing.monotonic = { 0 }
        if budget {
            policy.delayCeiling = 40
            policy.budget = 10
        }
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, policy))
        }
        #expect(failure.outcome == .limitRefused)
        #expect(failure.failure.retryAfter == .seconds(31))
        #expect(server.requests.withLock { $0.count } == 1)
        assertRecoveryRequests(recorder, server)
        #expect(!recorder.events.withLock { $0.map(\.transition) }.contains(.delayScheduled))
    }

    @Test(arguments: StreamingBoundary.withAnthropic, [false, true])
    func keepaliveAdmissionRemainsPending(
        _ boundary: StreamingBoundary,
        _ allow: Bool,
    ) async throws {
        let keepalive = boundary.omlx ? ": still alive\n\n" : "\n"
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: keepalive, truncated: true),
            RecoveryReply(body: boundary.frame(content: "ok", done: true)),
        ])
        let recorder = RecoveryRecorder()
        let pending = AsyncStream<Void>.makeStream()
        let decision = AsyncStream<RecoveryAdmission>.makeStream()
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, number in
            #expect(failure.acceptance == .unknown)
            #expect(failure.progress.rawBytes == keepalive.utf8.count)
            #expect(failure.progress.observed == RecoverySemanticProgress())
            #expect(failure.progress.delivered == RecoverySemanticProgress())
            #expect(failure.inspectEvidence().cause is URLError)
            #expect(number == 2)
            pending.continuation.yield(())
            return decision.stream
        }
        let gateway = boundary.gateway(server, policy)
        let task = Task { try await boundary.consume(gateway) }
        var iterator = pending.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(server.requests.withLock { $0.count } == 1)
        assertRecoveryRequests(recorder, server)
        #expect(recorder.events.withLock { $0.last?.transition } == .admissionPending)
        decision.continuation.yield(allow ? .allow : .reject)
        decision.continuation.finish()
        if allow {
            try await task.value
            #expect(server.requests.withLock { $0.count } == 2)
            assertRecoveryRequests(recorder, server)
        } else {
            let failure = try await recoveryFailure { try await task.value }
            #expect(failure.outcome == .admissionRejected)
            #expect(failure.history.count == 1)
        }
    }
}
