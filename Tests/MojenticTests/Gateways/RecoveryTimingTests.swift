import Foundation
import Testing

@testable import Mojentic

@Suite("Recovery admission and timing")
struct RecoveryTimingTests {
    @Test(arguments: RecoveryBoundary.all, ["2", "Thu, 01 Jan 1970 00:00:03 GMT", "invalid", "-2"])
    func retryAfterUsesInjectedTiming(_ boundary: RecoveryBoundary, _ header: String) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 429, headers: ["Retry-After": header], body: "busy"),
            try boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        let delays = RecoveryLocked<[TimeInterval]>([])
        var policy = recoveryPolicy(recorder)
        policy.baseDelay = 1
        policy.timing.wall = { Date(timeIntervalSince1970: 1) }
        policy.timing.monotonic = { 0 }
        policy.timing.jitter = { $0 / 2 }
        policy.timing.sleep = { value in delays.withLock { $0.append(value) } }
        let observed = RecoveryLocked<RecoveryRetryAfter?>(nil)
        policy.admission = { failure, next in
            observed.withLock { $0 = failure.retryAfter }
            #expect(next == 2)
            #expect(failure.status == 429)
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        let delay: TimeInterval = header == "2" || header.hasPrefix("Thu") ? 2 : 0.5
        #expect(delays.withLock { $0 } == [delay])
        switch header {
        case "2": #expect(observed.withLock { $0 } == .seconds(2))
        case "invalid", "-2": #expect(observed.withLock { $0 } == .invalid)
        default: #expect(observed.withLock { $0 } == .date(Date(timeIntervalSince1970: 3)))
        }
        #expect(server.requests.withLock { $0.count } == 2)
    }

    @Test(arguments: RecoveryBoundary.all, [false, true])
    func retryAfterLimitRefusesResend(_ boundary: RecoveryBoundary, _ budget: Bool) async throws {
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
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.outcome == .limitRefused)
        #expect(failure.failure.retryAfter == .seconds(31))
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(!recorder.events.withLock { $0.map(\.transition.rawValue) }.contains("delayScheduled"))
    }

    @Test(arguments: RecoveryBoundary.all, [false, true])
    func pendingAdmissionRequiresExplicitDecision(_ boundary: RecoveryBoundary, _ allow: Bool) async throws {
        // Truncated successful response is ambiguous transport failure, not termination proof.
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: " ", truncated: true), try boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        let pending = AsyncStream<Void>.makeStream()
        let decision = AsyncStream<RecoveryAdmission>.makeStream()
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, next in
            #expect(failure.acceptance == .unknown)
            #expect(failure.progress.rawBytes == 1)
            #expect(failure.progress.observed == RecoverySemanticProgress())
            #expect(failure.eligible)
            #expect(next == 2)
            #expect(failure.inspectEvidence().cause is URLError)
            pending.continuation.yield(())
            return decision.stream
        }
        let gateway = boundary.gateway(server, policy: policy)
        let task = Task { try await boundary.complete(gateway) }
        var iterator = pending.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(recorder.events.withLock { $0.last?.transition } == .admissionPending)
        decision.continuation.yield(allow ? .allow : .reject)
        decision.continuation.finish()
        if allow {
            #expect(try await task.value.thinking == "reasoning")
            #expect(server.requests.withLock { $0.count } == 2)
        } else {
            let failure = try await recoveryFailure { _ = try await task.value }
            #expect(failure.outcome == .admissionRejected)
            #expect(failure.failure.inspectEvidence().cause is URLError)
            #expect(server.requests.withLock { $0.count } == 1)
        }
    }

    @Test(arguments: RecoveryBoundary.all)
    func ambiguousFailureWithoutHookRequiresAdmission(_ boundary: RecoveryBoundary) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 504, body: "busy")])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.admission = nil
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.outcome == .admissionRequired)
        #expect(failure.failure.eligible)
        #expect(failure.failure.acceptance == .unknown)
        #expect(server.requests.withLock { $0.count } == 1)
    }
}

@Suite("Recovery admission limits")
struct RecoveryAdmissionLimitTests {
    @Test(arguments: RecoveryBoundary.all)
    func expiresWhileAdmissionIsPending(_ boundary: RecoveryBoundary) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 503, body: "busy")])
        let recorder = RecoveryRecorder()
        let sleeping = AsyncStream<Void>.makeStream()
        let elapsed = AsyncStream<Void>.makeStream()
        let pending = AsyncStream<RecoveryAdmission>.makeStream()
        let now = RecoveryLocked<TimeInterval>(0)
        var policy = recoveryPolicy(recorder)
        policy.budget = 5
        policy.timing.monotonic = { now.withLock { $0 } }
        policy.admission = { _, _ in pending.stream }
        policy.timing.sleep = { delay in
            #expect(delay == 5)
            sleeping.continuation.yield(())
            var iterator = elapsed.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let gateway = boundary.gateway(server, policy: policy)
        let task = Task { try await boundary.complete(gateway) }
        var iterator = sleeping.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(server.requests.withLock { $0.count } == 1)
        now.withLock { $0 = 5 }
        elapsed.continuation.yield(())
        elapsed.continuation.finish()
        let failure = try await recoveryFailure { _ = try await task.value }
        #expect(failure.outcome == .limitRefused)
        #expect(failure.history.count == 1)
        #expect(server.requests.withLock { $0.count } == 1)
    }
}

@Suite("Ambiguous local timeout")
struct RecoveryTimeoutTests {
    @Test(arguments: RecoveryBoundary.all, [false, true])
    func timeoutRemainsPendingUntilExplicitAllowOrReject(
        _ boundary: RecoveryBoundary,
        _ allow: Bool
    ) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: "", truncated: true, hold: true), try boundary.success(),
        ])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let pending = AsyncStream<Void>.makeStream()
        let decisions = AsyncStream<RecoveryAdmission>.makeStream()
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, next in
            #expect(failure.category == .clientTimeout)
            #expect((failure.inspectEvidence().cause as? URLError)?.code == .timedOut)
            #expect(failure.acceptance == .unknown)
            #expect(failure.progress.delivered == RecoverySemanticProgress())
            #expect(failure.progress.rawBytes == 0)
            #expect(next == 2)
            pending.continuation.yield(())
            return decisions.stream
        }
        let gateway = boundary.gateway(server, policy: policy, idleTimeout: 2)
        let task = Task { try await boundary.complete(gateway) }
        var iterator = pending.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(recorder.events.withLock { $0.last?.transition } == .admissionPending)
        server.release()
        decisions.continuation.yield(allow ? .allow : .reject)
        decisions.continuation.finish()
        if allow {
            #expect(try await task.value.thinking == "reasoning")
            let bodies = server.requests.withLock { $0 }
            #expect(bodies.count == 2)
            #expect(bodies.first == bodies.last)
        } else {
            let failure = try await recoveryFailure { _ = try await task.value }
            #expect(failure.outcome == .admissionRejected)
            #expect((failure.failure.inspectEvidence().cause as? URLError)?.code == .timedOut)
            #expect(server.requests.withLock { $0.count } == 1)
        }
    }
}

@Suite("Recovery bounded backoff")
struct RecoveryBackoffTests {
    @Test(arguments: RecoveryBoundary.all)
    func exponentialCeilingsAndBoundedHistory(_ boundary: RecoveryBoundary) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 504, body: "busy")])
        let recorder = RecoveryRecorder()
        let delays = RecoveryLocked<[TimeInterval]>([])
        var policy = recoveryPolicy(recorder, attempts: 4)
        policy.baseDelay = 1
        policy.delayCeiling = 3
        policy.timing.monotonic = { 0 }
        policy.timing.jitter = { $0 }
        policy.timing.sleep = { delay in delays.withLock { $0.append(delay) } }
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(delays.withLock { $0 } == [1, 2, 3])
        #expect(failure.outcome == .exhausted)
        #expect(failure.history.map { $0.identity?.wireNumber } == [1, 2, 3, 4])
        #expect(failure.history.allSatisfy { $0.retryAfter == .absent })
        #expect(server.requests.withLock { $0.count } == 4)
    }

    @Test(arguments: RecoveryBoundary.all)
    func pastDateDoesNotReplaceJitterDelay(_ boundary: RecoveryBoundary) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(
                status: 429,
                headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:00 GMT"],
                body: "busy"
            ),
            try boundary.success(),
        ])
        let delays = RecoveryLocked<[TimeInterval]>([])
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.baseDelay = 1
        policy.timing.wall = { Date(timeIntervalSince1970: 10) }
        policy.timing.jitter = { $0 / 2 }
        policy.timing.sleep = { delay in delays.withLock { $0.append(delay) } }
        _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        #expect(delays.withLock { $0 } == [0.5])
        #expect(server.requests.withLock { $0.count } == 2)
    }

    @Test(arguments: RecoveryBoundary.all)
    func expiredAbsoluteDeadlinePreventsAdmission(_ boundary: RecoveryBoundary) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 503, body: "busy")])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.deadline = 1
        policy.timing.monotonic = { 1 }
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.outcome == .limitRefused)
        #expect(failure.history.count == 1)
        #expect(!recorder.events.withLock { $0.map(\.transition.rawValue) }.contains("admissionPending"))
        #expect(server.requests.withLock { $0.count } == 1)
    }
}
