import Foundation
@testable import Mojentic
import Testing

struct StreamingRecoveryCancellationTests {
    @Test(arguments: StreamingBoundary.all, ["active", "admission", "backoff"])
    func cancellationRetainsActualAttempt(_ boundary: StreamingBoundary, _ phase: String) async throws {
        let firstReply =
            if phase == "active" {
                RecoveryReply(body: "\n", truncated: true, hold: true)
            } else {
                RecoveryReply(status: 503, body: "busy")
            }
        let server = try RecoveryLoopback(replies: [
            firstReply, RecoveryReply(body: boundary.frame(done: true)),
        ])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let ready = AsyncStream<Void>.makeStream()
        let decisions = AsyncStream<RecoveryAdmission>.makeStream()
        let blocked = AsyncStream<Void>.makeStream()
        var policy = recoveryPolicy(recorder)
        if phase == "active" {
            policy.wireObserver = { event in
                if case .body = event {
                    ready.continuation.yield(())
                }
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
        let task = Task { try await boundary.consume(gateway) }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        let failure = try await recoveryFailure { try await task.value }
        #expect(failure.outcome == .cancelled)
        #expect(failure.history.count == 1)
        #expect(failure.history.first?.identity?.wireNumber == 1)
        #expect(failure.failure.inspectEvidence().cause is CancellationError)
        #expect(server.requests.withLock { $0.count } == 1)
        let transitions = recorder.events.withLock { $0.map(\.transition) }
        #expect(transitions.filter { $0 == .cancelled }.count == 1)
        let failedIndex = try #require(transitions.firstIndex(of: .attemptFailed))
        let cancelledIndex = try #require(transitions.firstIndex(of: .cancelled))
        #expect(failedIndex < cancelledIndex)
        #expect(!transitions.contains(.attemptSucceeded))
    }

    @Test(arguments: [false, true])
    func pausedTerminalTelemetryCannotSucceed(_ single: Bool) async throws {
        let boundary = StreamingBoundary(omlx: false, single: single)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: boundary.frame(tool: !single, done: true, metrics: true))
        ])
        let recorder = RecoveryRecorder()
        let cleaned = AsyncStream<CompletionRecoveryReport>.makeStream()
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { cleaned.continuation.yield($0) }
        let ready = AsyncStream<Void>.makeStream()
        let paused = RecoveryConsumerPause()
        let gateway = boundary.gateway(server, policy)
        let task = Task {
            try await withRecoveryStreamCancellation {
                if single {
                    let stream = try gateway.completeStreamEventsRecovering(
                        model: "fixture", messages: [], config: .init(),
                    )
                    var iterator = stream.makeAsyncIterator()
                    guard case .progress? = await iterator.next() else {
                        Issue.record("Expected progress")
                        return
                    }
                    ready.continuation.yield(())
                    await paused.wait()
                    let next = await iterator.next()
                    // AsyncStream returns nil when next() begins on an already cancelled task.
                    #expect(next == nil)
                } else {
                    let stream = gateway.streamRecovering(
                        model: "fixture", messages: [], tools: nil, config: .init())
                    var iterator = stream.makeAsyncIterator()
                    guard case .progress? = try await iterator.next() else {
                        Issue.record("Expected progress")
                        return
                    }
                    ready.continuation.yield(())
                    await paused.wait()
                    let next = try await iterator.next()
                    #expect(next == nil)
                }
            }
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        #expect(!recorder.events.withLock { $0.map(\.transition) }.contains(.attemptSucceeded))
        task.cancel()
        var cleanup = cleaned.stream.makeAsyncIterator()
        let report = try #require(await cleanup.next())
        #expect(report.history.count == 1)
        #expect(report.progress.delivered.completedToolCalls == 0)
        #expect(recorder.events.withLock { $0.suffix(2).map(\.transition) } == [.attemptFailed, .cancelled])
        #expect(server.requests.withLock { $0.count } == 1)
        paused.resume()
        try await task.value
    }
}
