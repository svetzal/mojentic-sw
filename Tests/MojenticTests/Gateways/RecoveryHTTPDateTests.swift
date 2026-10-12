import Foundation
@testable import Mojentic
import Testing

struct RecoveryHTTPDateTests {
    enum Form: CaseIterable, Sendable {
        case imf, rfc850, asctime

        func header(seconds: Int) -> String {
            let time = seconds == 3 ? "00:00:03" : "00:00:31"
            switch self {
            case .imf: return "Thu, 01 Jan 1970 \(time) GMT"
            case .rfc850: return "Thursday, 01-Jan-70 \(time) GMT"
            case .asctime: return "Thu Jan  1 \(time) 1970"
            }
        }
    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func obsoleteDateRefusesShortenedMinimum(_ boundary: RecoveryStatusBoundary) async throws {
        try await assertRefusal(boundary, form: .rfc850, budget: false)
    }

    @Test(arguments: RecoveryStatusBoundary.all, Form.allCases)
    func dateMinimumPreservesTimingAndWire(_ boundary: RecoveryStatusBoundary, _ form: Form) async throws {
        for wall: TimeInterval in [1, 10] {
            let rejected = RecoveryReply(
                status: 429, headers: ["Retry-After": form.header(seconds: 3)], body: "busy",
            )
            let replies = [rejected, try success(boundary)]
            let server = try RecoveryLoopback(replies: replies)
            let recorder = RecoveryRecorder()
            let sleeps = RecoveryLocked<[TimeInterval]>([])
            let failures = RecoveryLocked<[RecoveryFailure]>([])
            var policy = timedPolicy(recorder, wall: wall, sleeps: sleeps)
            policy.admission = { failure, next in
                failures.withLock { $0.append(failure) }
                #expect(next == 2)
                return AsyncStream {
                    $0.yield(.allow)
                    $0.finish()
                }
            }
            try await boundary.invoke(
                boundary.provider.gateway(server, policy: policy), delivered: RecoveryLocked([]),
            )
            #expect(sleeps.withLock { $0 } == [wall == 1 ? 2 : 0.5])
            let identities = try assertStatusWires(recorder, server: server, replies: replies)
            let failure = try #require(failures.withLock { $0.first })
            #expect(failures.withLock { $0.count } == 1)
            assertDateFailure(failure, identity: identities[0], seconds: 3)
            let events = recorder.events.withLock { $0 }
            #expect(
                events.map(\.transition) == [
                    .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled,
                    .retryStarted, .attemptStarted, .attemptSucceeded,
                ])
            #expect(
                events.map(\.identity) == Array(repeating: identities[0], count: 5)
                    + Array(repeating: identities[1], count: 3))
            #expect(events.first { $0.transition == .delayScheduled }?.delay == (wall == 1 ? 2 : 0.5))
        }
    }

    @Test(arguments: RecoveryStatusBoundary.all, Form.allCases)
    func dateLimitsRetainFailureAndHistory(_ boundary: RecoveryStatusBoundary, _ form: Form) async throws {
        for budget in [false, true] {
            try await assertRefusal(boundary, form: form, budget: budget)
        }
    }

    @Test(arguments: RecoveryBoundary.all, [2.0, 3.0, 4.0])
    func obsoleteYearUsesInjectedFiftyYearWindow(_ boundary: RecoveryBoundary, _ offset: Double) async throws
    {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(
                status: 429, headers: ["Retry-After": "Wednesday, 01-Jan-70 00:00:03 GMT"], body: "busy"),
            boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        let sleeps = RecoveryLocked<[TimeInterval]>([])
        let observed = RecoveryLocked<RecoveryRetryAfter?>(nil)
        let wall = 1_577_836_800 + offset  // January 1, 2020, in UTC.
        let expected: TimeInterval = offset == 2 ? 3 : 3_155_760_003
        var policy = timedPolicy(recorder, wall: wall, sleeps: sleeps)
        policy.delayCeiling = 2_000_000_000
        policy.admission = { failure, _ in
            observed.withLock { $0 = failure.retryAfter }
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        #expect(observed.withLock { $0 } == .date(Date(timeIntervalSince1970: expected)))
        #expect(sleeps.withLock { $0 } == [max(0.5, expected - wall)])
        assertRecoveryRequests(recorder, server)
    }

    @Test(arguments: RecoveryStatusBoundary.all, [nil, "invalid", "-2", "2"] as [String?])
    func absenceInvalidityAndSecondsRemainDistinct(
        _ boundary: RecoveryStatusBoundary, _ header: String?
    ) async throws {
        let rejected = RecoveryReply(
            status: 429, headers: header.map { ["Retry-After": $0] } ?? [:], body: "busy",
        )
        let replies = [rejected, try success(boundary)]
        let server = try RecoveryLoopback(replies: replies)
        let recorder = RecoveryRecorder()
        let sleeps = RecoveryLocked<[TimeInterval]>([])
        let observed = RecoveryLocked<RecoveryRetryAfter?>(nil)
        var policy = timedPolicy(recorder, wall: 1, sleeps: sleeps)
        policy.admission = { failure, _ in
            observed.withLock { $0 = failure.retryAfter }
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        try await boundary.invoke(
            boundary.provider.gateway(server, policy: policy), delivered: RecoveryLocked([]),
        )
        let expected: RecoveryRetryAfter = header == nil ? .absent : header == "2" ? .seconds(2) : .invalid
        #expect(observed.withLock { $0 } == expected)
        #expect(sleeps.withLock { $0 } == [header == "2" ? 2 : 0.5])
        _ = try assertStatusWires(recorder, server: server, replies: replies)
    }

    private func assertRefusal(_ boundary: RecoveryStatusBoundary, form: Form, budget: Bool) async throws {
        let reply = RecoveryReply(
            status: 429, headers: ["Retry-After": form.header(seconds: 31)], body: "busy",
        )
        let server = try RecoveryLoopback(replies: [reply])
        let recorder = RecoveryRecorder()
        let sleeps = RecoveryLocked<[TimeInterval]>([])
        var policy = timedPolicy(recorder, wall: 0, sleeps: sleeps)
        if budget {
            // Four seconds have elapsed: a 34-second budget has only 30 seconds remaining.
            let clock = RecoveryLocked(0)
            policy.timing.monotonic = {
                clock.withLock { value in
                    defer { value += 1 }
                    return value == 0 ? 0 : 4
                }
            }
            policy.delayCeiling = 40
            policy.budget = 34
            // Admission also uses sleep for its budget timer; keep it pending until cancellation.
            policy.timing.sleep = { delay in
                sleeps.withLock { $0.append(delay) }
                try await Task.sleep(for: .seconds(60))
            }
        }
        let failure = try await recoveryFailure {
            try await boundary.invoke(
                boundary.provider.gateway(server, policy: policy), delivered: RecoveryLocked([]),
            )
        }
        #expect(failure.outcome == .limitRefused)
        #expect(sleeps.withLock { $0 }.allSatisfy { budget && $0 == 30 })
        let identities = try assertStatusWires(recorder, server: server, replies: [reply])
        assertDateFailure(failure.failure, identity: identities[0], seconds: 31)
        #expect(failure.logicalID == identities[0].logicalID)
        #expect(failure.history.count == 1)
        let retained = try #require(failure.history.first)
        assertDateFailure(retained, identity: identities[0], seconds: 31)
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition) == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .limitRefused,
            ])
        #expect(events.map(\.identity) == Array(repeating: identities[0], count: 5))
    }

    private func timedPolicy(
        _ recorder: RecoveryRecorder, wall: TimeInterval, sleeps: RecoveryLocked<[TimeInterval]>,
    ) -> CompletionRecoveryPolicy {
        var policy = recoveryPolicy(recorder)
        policy.baseDelay = 1
        policy.timing.wall = { Date(timeIntervalSince1970: wall) }
        policy.timing.monotonic = { 0 }
        policy.timing.jitter = { $0 / 2 }
        policy.timing.sleep = { delay in sleeps.withLock { $0.append(delay) } }
        return policy
    }

    private func success(_ boundary: RecoveryStatusBoundary) throws -> RecoveryReply {
        if boundary.operation == .tools || boundary.operation == .single {
            let streaming = StreamingBoundary(
                omlx: boundary.provider.omlx,
                single: boundary.operation == .single,
                openAI: boundary.provider.openAI,
                anthropic: boundary.provider.anthropic,
            )
            return try RecoveryReply(body: streaming.frame(content: "ok", done: true))
        }
        return try boundary.buffered.success()
    }

    private func assertDateFailure(_ failure: RecoveryFailure, identity: RecoveryIdentity, seconds: Int) {
        #expect(failure.identity == identity)
        #expect(failure.logicalID == identity.logicalID)
        #expect(failure.retryAfter == .date(Date(timeIntervalSince1970: Double(seconds))))
        #expect(failure.category == .http)
        #expect(failure.status == 429)
        #expect(failure.eligible)
        #expect(failure.reason == "selectedHTTPStatus")
        #expect(failure.acceptance == .unknown)
        #expect(failure.progress.rawBytes == 4)
        #expect(failure.progress.observed == RecoverySemanticProgress())
        #expect(failure.progress.delivered == RecoverySemanticProgress())
        #expect(failure.inspectEvidence().body == Data("busy".utf8))
        #expect((failure.inspectEvidence().cause as? RecoveryHTTPStatusFailure)?.status == 429)
    }
}
