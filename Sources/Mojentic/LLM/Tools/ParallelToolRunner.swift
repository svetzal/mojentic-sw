import Foundation

/// Tool runner that dispatches calls concurrently via `ThrowingTaskGroup`.
///
/// Output preserves input order. Cancellation propagates: if any tool throws
/// a non-recoverable error, siblings are cancelled via the task group. Outer
/// `Task.checkCancellation()` is honoured before scheduling and between
/// completions.
///
/// Use when several tool calls in the same batch are I/O-bound and benefit
/// from parallelism (e.g. multiple web searches). The default
/// ``LLMBroker`` still uses ``SerialToolRunner`` for predictable, stepwise
/// debugging — pass an instance of this runner explicitly to opt in.
public actor ParallelToolRunner: ToolRunner {
    /// Maximum number of in-flight tool calls per batch.
    public let maxConcurrency: Int

    /// Create a parallel runner.
    ///
    /// - Parameter maxConcurrency: Upper bound on concurrent tool executions.
    ///   Defaults to `4` — high enough to win on typical realtime turns
    ///   (2–3 concurrent function calls) but low enough that unbounded
    ///   fan-out into rate-limited APIs doesn't punish callers.
    public init(maxConcurrency: Int = 4) {
        precondition(maxConcurrency > 0, "maxConcurrency must be positive")
        self.maxConcurrency = maxConcurrency
    }

    /// Run the supplied batch concurrently, preserving input order in the
    /// returned outcomes.
    public func runBatch(
        _ calls: [ToolCallExecution],
        tools: [any LLMTool],
        tracer: any Tracer,
        context: TracerContext
    ) async throws -> [ToolCallOutcome] {
        try Task.checkCancellation()
        guard !calls.isEmpty else { return [] }
        let clock = ContinuousClock()
        let batchPayload = ToolBatchPayload(
            correlationId: context.correlationId,
            parentId: context.parentId,
            duration: .zero,
            count: calls.count
        )
        let childContext = context.child(parent: batchPayload.id)
        let start = clock.now
        let limit = maxConcurrency
        let outcomes = try await withThrowingTaskGroup(of: (Int, ToolCallOutcome).self) { group in
            var results: [ToolCallOutcome?] = Array(repeating: nil, count: calls.count)
            var nextIndex = 0
            var inFlight = 0
            while nextIndex < calls.count || inFlight > 0 {
                while inFlight < limit && nextIndex < calls.count {
                    let index = nextIndex
                    let call = calls[index]
                    group.addTask {
                        try Task.checkCancellation()
                        let outcome = await SerialToolRunner.execute(
                            call: call,
                            tools: tools,
                            tracer: tracer,
                            context: childContext
                        )
                        return (index, outcome)
                    }
                    nextIndex += 1
                    inFlight += 1
                }
                if let next = try await group.next() {
                    results[next.0] = next.1
                    inFlight -= 1
                }
            }
            return results.compactMap(\.self)
        }
        let duration = start.duration(to: clock.now)
        await tracer.recordToolBatch(
            ToolBatchPayload(
                id: batchPayload.id,
                correlationId: context.correlationId,
                parentId: context.parentId,
                duration: duration,
                count: calls.count
            )
        )
        return outcomes
    }
}
