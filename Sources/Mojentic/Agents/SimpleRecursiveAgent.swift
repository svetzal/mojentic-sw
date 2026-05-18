import Foundation

/// Agent that self-recurses by calling a refinement closure until either
/// the closure signals completion or the depth cap is reached.
///
/// Useful for "keep refining the answer" loops. The depth cap throws
/// ``MojenticError/recursionDepthExceeded(limit:)`` so callers can
/// distinguish "couldn't converge" from other failures.
public actor SimpleRecursiveAgent {
    /// Decision returned by the refinement step.
    public enum Decision: Sendable {
        /// Stop and return the supplied text as the final answer.
        case complete(String)
        /// Continue with the supplied text as the next iteration's input.
        case refine(String)
    }

    /// Per-iteration step closure.
    public typealias Step = @Sendable (_ current: String, _ iteration: Int) async throws -> Decision

    private let maxDepth: Int
    private let step: Step

    /// Create the agent.
    public init(maxDepth: Int = 5, step: @escaping Step) {
        precondition(maxDepth > 0, "maxDepth must be positive")
        self.maxDepth = maxDepth
        self.step = step
    }

    /// Drive the loop starting from `seed`.
    public func solve(seed: String) async throws -> String {
        var current = seed
        for iteration in 1...maxDepth {
            try Task.checkCancellation()
            switch try await step(current, iteration) {
            case .complete(let final):
                return final
            case .refine(let next):
                current = next
            }
        }
        throw MojenticError.recursionDepthExceeded(limit: maxDepth)
    }
}
