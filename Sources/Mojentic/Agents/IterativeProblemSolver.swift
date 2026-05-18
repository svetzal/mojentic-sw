import Foundation

/// Drives an iterative solve loop against a single ``ChatSession``.
///
/// Each iteration sends a refining prompt that asks the model to either
/// reply with `DONE`, `FAIL`, or continue making progress. Stops on the
/// first `DONE` / `FAIL` reply, after `maxIterations` rounds, or when the
/// caller cancels. Optionally shares state via ``SharedWorkingMemory`` so
/// downstream agents can read what was learned.
public actor IterativeProblemSolver {
    private let broker: LLMBroker
    private let model: String
    private let systemPrompt: String
    private let maxIterations: Int
    private let tools: [any LLMTool]
    private let memory: SharedWorkingMemory?
    private let config: CompletionConfig

    /// Create an iterative solver.
    public init(
        broker: LLMBroker,
        model: String,
        systemPrompt: String = IterativeProblemSolver.defaultSystemPrompt,
        maxIterations: Int = 3,
        tools: [any LLMTool] = [],
        memory: SharedWorkingMemory? = nil,
        config: CompletionConfig = CompletionConfig()
    ) {
        precondition(maxIterations > 0, "maxIterations must be positive")
        self.broker = broker
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxIterations = maxIterations
        self.tools = tools
        self.memory = memory
        self.config = config
    }

    /// Default system prompt mirroring the Python reference.
    public static let defaultSystemPrompt = """
        You are a problem-solving assistant that can solve complex problems step by step.
        You analyse problems, break them down into smaller parts, and solve them systematically.
        If you cannot solve a problem completely in one step, you make progress and identify
        what to do next.
        """

    /// Result of a solve attempt.
    public struct Outcome: Sendable {
        /// Final text reply from the model.
        public let summary: String
        /// Number of iterations the solver actually ran.
        public let iterations: Int
        /// Reason the loop stopped.
        public let stopReason: StopReason
    }

    /// Reasons the solver loop may stop.
    public enum StopReason: String, Sendable {
        /// Model emitted `DONE`.
        case done
        /// Model emitted `FAIL`.
        case failed
        /// `maxIterations` reached without a `DONE` / `FAIL` signal.
        case maxIterations
    }

    /// Solve `problem` and return the final outcome.
    public func solve(_ problem: String) async throws -> Outcome {
        let session = ChatSession(
            broker: broker,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            config: config
        )
        var iterations = 0
        var lastReply = ""
        var stopReason: StopReason = .maxIterations
        while iterations < maxIterations {
            try Task.checkCancellation()
            iterations += 1
            let response = try await session.send(buildPrompt(for: problem))
            lastReply = response.content
            let upper = response.content.uppercased()
            if upper.contains("FAIL") {
                stopReason = .failed
                break
            }
            if upper.contains("DONE") {
                stopReason = .done
                break
            }
        }
        let summary = try await session.send(
            "Summarise the final result, and only the final result, "
                + "without commenting on the process by which you achieved it."
        )
        if let memory {
            await memory.set(
                "iterative_solver.last_summary",
                to: .string(summary.content)
            )
        }
        return Outcome(
            summary: summary.content.isEmpty ? lastReply : summary.content,
            iterations: iterations,
            stopReason: stopReason
        )
    }

    private nonisolated func buildPrompt(for problem: String) -> String {
        """
        Given the user request:
        \(problem)

        Use the tools at your disposal to act on their request.
        You may wish to create a step-by-step plan for more complicated requests.

        If you cannot provide an answer, say only "FAIL".
        If you have the answer, say only "DONE".
        """
    }
}
