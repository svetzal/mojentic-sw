import Foundation
@testable import Mojentic
import Testing

@Suite("Recovery cancellation and capture boundaries")
struct RecoveryCancellationTests {
    @Test(arguments: RecoveryBoundary.all, ["request", "headers", "body"])
    func captureFailureIsTerminal(
        _ boundary: RecoveryBoundary,
        _ phase: String,
    ) async throws {
        let server = try RecoveryLoopback(replies: [boundary.success()])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.wireObserver = { event in
            switch (phase, event) {
            case ("request", .request), ("headers", .headers), ("body", .body):
                throw RecoveryCaptureSentinel()
            default: break
            }
        }
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.outcome == .captureFailed)
        #expect(failure.failure.inspectEvidence().cause is RecoveryCaptureSentinel)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(server.requests.withLock { $0.count } == (phase == "request" ? 0 : 1))
        if phase == "request" {
            #expect(failure.failure.identity == nil)
            #expect(failure.history.isEmpty)
            #expect(failure.failure.progress.rawBytes == 0)
        } else {
            #expect(failure.failure.identity?.wireNumber == 1)
            #expect(failure.history.count == 1)
            #expect(failure.failure.progress.headersReceived)
        }
    }

    @Test(arguments: RecoveryBoundary.all)
    func cancellationBeforeDispatchMakesZeroRequests(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [boundary.success()])
        let recorder = RecoveryRecorder()
        let ready = AsyncStream<Void>.makeStream()
        let start = AsyncStream<Void>.makeStream()
        let gateway = boundary.gateway(server, policy: recoveryPolicy(recorder))
        let task = Task {
            ready.continuation.yield(())
            var iterator = start.stream.makeAsyncIterator()
            _ = await iterator.next()
            return try await boundary.complete(gateway)
        }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        start.continuation.finish()
        let failure = try await recoveryFailure { _ = try await task.value }
        #expect(failure.outcome == .cancelled)
        #expect(failure.history.isEmpty)
        #expect(failure.failure.identity == nil)
        #expect(failure.failure.inspectEvidence().cause is CancellationError)
        #expect(server.requests.withLock { $0.isEmpty })
        #expect(recorder.events.withLock { $0.map(\.transition.rawValue) } == ["cancelled"])
    }

    @Test(arguments: RecoveryBoundary.all, ["active", "admission", "backoff", "success"])
    func cancellationWinsAtEveryBoundary(_ boundary: RecoveryBoundary, _ phase: String) async throws {
        let reply =
            if phase == "active" {
                RecoveryReply(body: " ", truncated: true, hold: true)
            } else {
                if phase == "success" {
                    try boundary.success(tools: true)
                } else {
                    RecoveryReply(status: 503, body: "busy")
                }
            }
        let server = try RecoveryLoopback(replies: [reply, boundary.success()])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let ready = AsyncStream<Void>.makeStream()
        let blocked = AsyncStream<Void>.makeStream()
        let decisions = AsyncStream<RecoveryAdmission>.makeStream()
        var policy = recoveryPolicy(recorder)
        if phase == "admission" {
            policy.admission = { _, _ in
                ready.continuation.yield(())
                return decisions.stream
            }
        }
        if phase == "backoff" {
            policy.timing.sleep = { _ in
                ready.continuation.yield(())
                var iterator = blocked.stream.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
        }
        if phase == "active" {
            policy.wireObserver = { event in
                if case .body = event {
                    ready.continuation.yield(())
                }
            }
        }
        let handle = RecoveryLocked<Task<LLMGatewayResponse, any Error>?>(nil)
        let launch = AsyncStream<Void>.makeStream()
        if phase == "success" {
            policy.wireObserver = { event in
                if case .body = event {
                    handle.withLock { $0?.cancel() }
                }
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
        if phase == "active" {
            var iterator = ready.stream.makeAsyncIterator()
            _ = await iterator.next()
            task.cancel()
        } else if phase != "success" {
            var iterator = ready.stream.makeAsyncIterator()
            _ = await iterator.next()
            #expect(server.requests.withLock { $0.count } == 1)
            task.cancel()
        }
        let failure = try await recoveryFailure { _ = try await task.value }
        #expect(failure.outcome == .cancelled)
        #expect(failure.failure.category == .cancellation)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(failure.history.count == 1)
        if phase == "active" {
            #expect(failure.failure.progress.rawBytes == 1)
            #expect(failure.failure.progress.headersReceived)
            #expect(failure.failure.inspectEvidence().body == Data(" ".utf8))
        }
        if phase == "success" {
            #expect(failure.failure.progress.observed.completedToolCalls == 1)
            #expect(failure.failure.progress.observed.reasoningBytes == 9)
        }
        let events = recorder.events.withLock { $0 }
        #expect(events.filter { $0.transition == .cancelled }.count == 1)
        #expect(events.last?.transition == .cancelled)
        #expect(events.contains { $0.transition == .attemptFailed })
        #expect(!events.contains { $0.transition == .attemptSucceeded || $0.transition == .retryStarted })
    }

    @Test(arguments: RecoveryBoundary.all)
    func healthyActiveGenerationOutlivesRecoveryBudget(
        _ boundary: RecoveryBoundary
    ) async throws {
        let reply = try boundary.success()
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: reply.body, hold: true)])
        let recorder = RecoveryRecorder()
        let now = RecoveryLocked<TimeInterval>(0)
        var policy = recoveryPolicy(recorder)
        policy.budget = 1
        policy.deadline = 1
        policy.timing.monotonic = { now.withLock { $0 } }
        let gateway = boundary.gateway(server, policy: policy)
        let task = Task { try await boundary.complete(gateway) }
        var iterator = server.arrivals.makeAsyncIterator()
        _ = await iterator.next()
        now.withLock { $0 = 100 }
        server.release()
        #expect(try await task.value.thinking == (boundary.openAI ? nil : "reasoning"))
        #expect(server.requests.withLock { $0.count } == 1)
    }
}
