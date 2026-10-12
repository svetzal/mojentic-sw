import Foundation
@testable import Mojentic
import Testing

// Bound simultaneous loopback fixtures while retaining every public matrix case.
@Suite(.serialized)
struct RecoveryBoundedTimingTests {
    @Test(arguments: RecoveryStatusBoundary.all, [-1.0, 100.0, .nan, .infinity, -.infinity])
    func jitterClampThroughPublicCompletion(_ boundary: RecoveryStatusBoundary, _ sample: Double) async throws
    {
        let ceilings = RecoveryLocked<[Double]>([])
        let sleeps = RecoveryLocked<[Double]>([])
        let expected: [Double] = sample < 0 && sample.isFinite ? [0, 0] : [2, 4]
        let selection = RecoverySelection(eligible: true, delays: expected) { policy in
            policy.baseDelay = 2
            policy.delayCeiling = 10
            policy.timing.monotonic = { 0 }
            policy.timing.jitter = { ceiling in
                ceilings.withLock { $0.append(ceiling) }
                return sample
            }
            policy.timing.sleep = { delay in sleeps.withLock { $0.append(delay) } }
        }
        try await assertTerminalStatus(
            boundary, status: 504, attempts: 3, truncated: false, selection: selection)
        #expect(ceilings.withLock { $0 } == [2, 4])
        #expect(sleeps.withLock { $0 } == expected)
    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func ordinaryCeilingSaturation(_ boundary: RecoveryStatusBoundary) async throws {
        let ceilings = RecoveryLocked<[Double]>([])
        let sleeps = RecoveryLocked<[Double]>([])
        let expected: [Double] = [1, 2, 3, 3]
        let selection = RecoverySelection(eligible: true, delays: expected) { policy in
            policy.baseDelay = 1
            policy.delayCeiling = 3
            policy.timing.monotonic = { 0 }
            policy.timing.jitter = { ceiling in
                ceilings.withLock { $0.append(ceiling) }
                return ceiling
            }
            policy.timing.sleep = { delay in sleeps.withLock { $0.append(delay) } }
        }
        try await assertTerminalStatus(
            boundary, status: 504, attempts: 5, truncated: false, selection: selection)
        #expect(ceilings.withLock { $0 } == expected)
        #expect(sleeps.withLock { $0 } == expected)
    }

    // At attempt 1024 the capped product is exactly 2. At attempts 1025 and
    // 1026 an uncapped exponent overflows pow to infinity, saturating at 16.
    // A low delay ceiling would hide that regression.
    @Test(arguments: [RecoveryStatusBoundary.Operation.ordinary, .single])
    func exponentCapBeforeCeilingSaturation(_ operation: RecoveryStatusBoundary.Operation) async throws {
        let boundary = RecoveryStatusBoundary(
            provider: .init(omlx: false, structured: false), operation: operation)
        let ceilings = RecoveryLocked<[Double]>([])
        let sleeps = RecoveryLocked<[Double]>([])
        let expected = (0..<1026).map { pow(2, Double(min($0, 1023) - 1022)) }
        let selection = RecoverySelection(eligible: true, delays: expected) { policy in
            policy.baseDelay = Double.leastNormalMagnitude
            policy.delayCeiling = 16
            policy.timing.monotonic = { 0 }
            policy.timing.jitter = { ceiling in
                ceilings.withLock { $0.append(ceiling) }
                return ceiling
            }
            policy.timing.sleep = { delay in sleeps.withLock { $0.append(delay) } }
        }
        try await assertTerminalStatus(
            boundary, status: 504, attempts: 1027, truncated: false, selection: selection)
        #expect(ceilings.withLock { $0 } == expected)
        #expect(sleeps.withLock { $0 } == expected)
        #expect(Array(ceilings.withLock { $0 }.suffix(3)) == [2, 2, 2])
    }
}
