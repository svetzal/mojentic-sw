import Foundation

/// Reasoning + Acting agent that loops Thought → Action → Observation
/// until the model produces a final answer or the step cap is reached.
///
/// Implementation strategy: drive a single ``LLMBroker`` with the supplied
/// tools. The broker already performs the tool-call loop natively, so this
/// agent is a thin wrapper that injects a ReAct-style system prompt,
/// enforces a maximum number of iterations (via the broker's
/// `maxToolIterations`), and surfaces a typed ``Result``.
public actor ReActAgent {
    private let broker: LLMBroker
    private let model: String
    private let tools: [any LLMTool]
    private let maxSteps: Int
    private let systemPrompt: String

    /// Default ReAct system prompt.
    public static let defaultSystemPrompt = """
        You are a ReAct agent. Reason step-by-step about the user's request.
        For each step, output a brief "Thought:" line. When you need to call a
        tool, do so via the function-calling interface — that is the "Action"
        step. When you have enough information to answer, write a single line
        prefixed "Final Answer:" followed by the answer. Do not include any
        commentary after the final answer.
        """

    /// Final outcome of a ReAct run.
    public struct Outcome: Sendable {
        /// Final answer text (the content of the last assistant turn).
        public let answer: String
        /// Whether the loop stopped because the model produced a final answer
        /// (`true`) or hit the step cap (`false`).
        public let converged: Bool
    }

    /// Create a ReAct agent.
    public init(
        broker: LLMBroker,
        model: String,
        tools: [any LLMTool],
        maxSteps: Int = 8,
        systemPrompt: String = ReActAgent.defaultSystemPrompt
    ) {
        precondition(maxSteps > 0, "maxSteps must be positive")
        self.broker = broker
        self.model = model
        self.tools = tools
        self.maxSteps = maxSteps
        self.systemPrompt = systemPrompt
    }

    /// Run the ReAct loop against `question`.
    public func run(_ question: String) async throws -> Outcome {
        let messages: [LLMMessage] = [
            .system(systemPrompt),
            .user(question),
        ]
        let config = CompletionConfig(maxToolIterations: maxSteps)
        do {
            let response = try await broker.complete(
                model: model,
                messages: messages,
                tools: tools,
                config: config
            )
            let answer = Self.extractFinalAnswer(from: response.content)
            return Outcome(answer: answer, converged: true)
        } catch MojenticError.toolDepthExceeded {
            return Outcome(answer: "", converged: false)
        }
    }

    private static func extractFinalAnswer(from text: String) -> String {
        guard let range = text.range(of: "Final Answer:") else { return text }
        let answer = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return answer
    }
}
