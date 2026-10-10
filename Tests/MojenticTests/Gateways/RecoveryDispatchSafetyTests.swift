import Foundation
import Testing

@testable import Mojentic

@Suite("Recovery dispatch safety")
struct RecoveryDispatchSafetyTests {
    @Test(arguments: RecoveryBoundary.all, [false, true])
    func expiryDuringRetryCapturePreventsResend(
        _ boundary: RecoveryBoundary, _ duringTransportSetup: Bool
    ) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "busy"), try boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        let readings = RecoveryLocked<[TimeInterval]>([])
        var policy = recoveryPolicy(recorder)
        policy.budget = 5
        policy.timing.monotonic = {
            readings.withLock { $0.isEmpty ? 0 : $0.removeFirst() }
        }
        // Script clock readings after capture: immediate expiry, or expiry during
        // URLSession setup after the engine's first final check has passed.
        policy.timing.sleep = { delay in
            if delay > 0 { try await Task.sleep(for: .seconds(60)) }
        }
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if case .request(let identity, _, _, _) = event, identity.wireNumber == 2 {
                readings.withLock { $0 = duringTransportSetup ? [0, 5] : [5] }
            }
        }
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.outcome == .limitRefused)
        let first = try #require(recorder.requests.withLock { $0.first })
        #expect(failure.failure.identity == first.0)
        #expect(failure.logicalID == first.0.logicalID)
        #expect(failure.history.count == 1)
        #expect(failure.history.first?.identity == first.0)
        #expect(failure.failure.progress.rawBytes == 4)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(failure.failure.inspectEvidence().body == Data("busy".utf8))
        #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        #expect(server.requests.withLock { $0 } == [first.1])
        let captures = recorder.requests.withLock { $0 }
        #expect(captures.count == 2)
        #expect(captures.last?.1 == first.1)
        #expect(captures.last?.0.logicalID == first.0.logicalID)
        #expect(captures.last?.0.attemptID != first.0.attemptID)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed,
                .delayScheduled, .limitRefused,
            ])
        #expect(recorder.events.withLock { $0.allSatisfy { $0.identity == first.0 } })
    }

    @Test(arguments: RecoveryBoundary.all)
    func slowInitialFailureStartsBudgetAndAdmittedRequestMayOutliveLimits(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: " ", truncated: true, hold: true), try boundary.success(),
        ])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let now = RecoveryLocked<TimeInterval>(0)
        let received = AsyncStream<Void>.makeStream()
        let report = RecoveryLocked<CompletionRecoveryReport?>(nil)
        var policy = recoveryPolicy(recorder)
        policy.budget = 5
        policy.deadline = 110
        policy.timing.monotonic = { now.withLock { $0 } }
        policy.timing.sleep = { delay in
            if delay > 0 { try await Task.sleep(for: .seconds(60)) }
        }
        policy.reportObserver = { value in report.withLock { $0 = value } }
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if case .body(let identity, _) = event {
                if identity.wireNumber == 1 {
                    received.continuation.yield(())
                } else {
                    // This request is already on the wire. Neither recovery limit
                    // may cut off its received response or turn success into refusal.
                    now.withLock { $0 = 1_000 }
                }
            }
        }
        let gateway = boundary.gateway(server, policy: policy)
        let task = Task { try await boundary.complete(gateway) }
        var iterator = received.stream.makeAsyncIterator()
        _ = await iterator.next()
        now.withLock { $0 = 100 }
        server.release()
        let response = try await task.value
        #expect(response.thinking == "reasoning")
        let captures = recorder.requests.withLock { $0 }
        #expect(captures.count == 2)
        let first = try #require(captures.first)
        let last = try #require(captures.last)
        #expect(first.1 == last.1)
        #expect(first.0.logicalID == last.0.logicalID)
        #expect(first.0.attemptID != last.0.attemptID)
        #expect(first.0.wireNumber == 1)
        #expect(last.0.wireNumber == 2)
        #expect(server.requests.withLock { $0 } == captures.map { $0.1 })
        let final = try #require(report.withLock { $0 })
        #expect(final.identity == last.0)
        #expect(final.history.count == 1)
        #expect(final.history.first?.identity == first.0)
        #expect(final.history.first?.inspectEvidence().cause is URLError)
        #expect(final.history.first?.inspectEvidence().body == Data(" ".utf8))
        #expect(final.history.first?.progress.observed == RecoverySemanticProgress())
        #expect(final.history.first?.progress.delivered == RecoverySemanticProgress())
        #expect(final.progress.observed == final.progress.delivered)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed,
                .delayScheduled, .retryStarted, .attemptStarted, .attemptSucceeded,
            ])
    }

    @Test(arguments: RecoveryBoundary.all)
    func expiryFromActualStartObserverDoesNotAbortAdmittedRequest(_ boundary: RecoveryBoundary) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "busy"), try boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        let now = RecoveryLocked<TimeInterval>(0)
        var policy = recoveryPolicy(recorder)
        policy.budget = 5
        policy.deadline = 5
        policy.timing.monotonic = { now.withLock { $0 } }
        policy.timing.sleep = { delay in
            if delay > 0 { try await Task.sleep(for: .seconds(60)) }
        }
        let observe = policy.observer
        policy.observer = { event in
            observe?(event)
            if event.transition == .retryStarted { now.withLock { $0 = 100 } }
        }
        let response = try await boundary.complete(boundary.gateway(server, policy: policy))
        #expect(response.thinking == "reasoning")
        let captures = recorder.requests.withLock { $0 }
        #expect(captures.count == 2)
        #expect(server.requests.withLock { $0 } == captures.map { $0.1 })
        #expect(captures.first?.1 == captures.last?.1)
        #expect(captures.first?.0.logicalID == captures.last?.0.logicalID)
        #expect(captures.first?.0.attemptID != captures.last?.0.attemptID)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed,
                .delayScheduled, .retryStarted, .attemptStarted, .attemptSucceeded,
            ])
    }

    @Test(arguments: RecoveryBoundary.all)
    func cancellationFromActualStartObserverCancelsLaunchedRequest(_ boundary: RecoveryBoundary) async throws
    {
        let success = try boundary.success()
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "busy"),
            RecoveryReply(body: success.body, hold: true, splitAt: 0),
        ])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let handle = RecoveryLocked<Task<LLMGatewayResponse, any Error>?>(nil)
        let launch = AsyncStream<Void>.makeStream()
        var policy = recoveryPolicy(recorder)
        let observe = policy.observer
        policy.observer = { event in
            observe?(event)
            if event.transition == .retryStarted {
                // Ensure a real second HTTP request, not just a launch marker.
                #expect(server.waitForRequest(2))
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
        let captures = recorder.requests.withLock { $0 }
        #expect(captures.count == 2)
        let first = try #require(captures.first)
        let last = try #require(captures.last)
        #expect(server.requests.withLock { $0 } == captures.map { $0.1 })
        #expect(first.1 == last.1)
        #expect(first.0.logicalID == last.0.logicalID)
        #expect(first.0.attemptID != last.0.attemptID)
        #expect(failure.outcome == .cancelled)
        #expect(failure.failure.identity == last.0)
        #expect(failure.failure.category == .cancellation)
        #expect(failure.failure.inspectEvidence().cause is CancellationError)
        #expect(failure.history.count == 2)
        #expect(failure.history.first?.identity == first.0)
        #expect(failure.history.first?.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        #expect(failure.history.first?.inspectEvidence().body == Data("busy".utf8))
        #expect(failure.history.last?.identity == last.0)
        #expect(failure.history.last?.inspectEvidence().cause is URLError)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed,
                .delayScheduled, .retryStarted, .attemptStarted, .attemptFailed, .cancelled,
            ])
    }

}
