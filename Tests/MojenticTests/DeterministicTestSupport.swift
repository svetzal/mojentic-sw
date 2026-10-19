import Foundation
@testable import Mojentic
import Testing

/// A cancellation rendezvous, with no timer or worker thread.
func waitForCancellation() async throws {
    let stream = AsyncStream<Void>.makeStream()
    defer { stream.continuation.finish() }
    for await _ in stream.stream {}
    try Task.checkCancellation()
}

/// Each test owns its time; transport callbacks explicitly advance this clock.
final class TestStreamClock: Sendable {
    @TaskLocal static var current: TestStreamClock?
    private let origin = ContinuousClock.now
    private let offset = RecoveryLocked<Int64>(0)
    var now: ContinuousClock.Instant { origin.advanced(by: .milliseconds(offset.withLock { $0 })) }
    var milliseconds: Int64 { offset.withLock { $0 } }
    func advance(_ milliseconds: Int64) { offset.withLock { $0 += milliseconds } }
}

struct DeterministicStreamTime: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }
    func provideScope(
        for _: Test, testCase _: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let clock = TestStreamClock()
        try await TestStreamClock.$current.withValue(clock) {
            let now: @Sendable () -> ContinuousClock.Instant = { clock.now }
            try await StreamMeasurement.$now.withValue(now) { try await function() }
        }
    }
}

/// Defaults cannot reach production clocks, random jitter or the real sleeper.
func deterministicRecoveryTiming() -> RecoveryTiming {
    var timing = RecoveryTiming()
    timing.monotonic = { 0 }
    timing.wall = { Date(timeIntervalSince1970: 0) }
    timing.jitter = { _ in 0 }
    timing.sleep = { delay in
        if delay > 0 {
            // The default virtual clock is frozen: a deadline guard must not win
            // an admission race merely because its sleeper was called.
            try await waitForCancellation()
        } else {
            await Task.yield()
            try Task.checkCancellation()
        }
    }
    return timing
}
