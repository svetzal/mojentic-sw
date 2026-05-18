import Foundation

/// Agent that turns ``TextEvent`` / ``LLMRequestEvent`` events into broker
/// completions and emits the resulting ``LLMResponseEvent`` back into the
/// dispatcher.
///
/// Propagates the inbound event's `correlationId` into the broker's
/// ``TracerContext`` so the full tracer correlation tree extends across
/// agent boundaries.
public actor AsyncLLMAgent: BaseAgent {
    private let broker: LLMBroker
    private let model: String
    private let systemPrompt: String?
    private let tools: [any LLMTool]
    private let config: CompletionConfig

    /// Create an LLM-backed agent.
    public init(
        broker: LLMBroker,
        model: String,
        systemPrompt: String? = nil,
        tools: [any LLMTool] = [],
        config: CompletionConfig = CompletionConfig()
    ) {
        self.broker = broker
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.config = config
    }

    /// Handle a TextEvent or LLMRequestEvent by invoking the broker.
    public func handle(_ event: any Event) async throws -> [any Event] {
        let context = TracerContext(
            correlationId: event.correlationId,
            parentId: event.parentId
        )
        let messages: [LLMMessage]
        let modelName: String
        switch event {
        case let textEvent as TextEvent:
            messages = prepend(system: systemPrompt, to: [.user(textEvent.content)])
            modelName = model
        case let requestEvent as LLMRequestEvent:
            messages = requestEvent.messages
            modelName = requestEvent.model ?? model
        default:
            return []
        }
        let response = try await broker.complete(
            model: modelName,
            messages: messages,
            tools: tools,
            config: config,
            context: context
        )
        return [
            LLMResponseEvent(
                response: response,
                correlationId: event.correlationId,
                parentId: event.parentId
            )
        ]
    }

    private nonisolated func prepend(system: String?, to messages: [LLMMessage]) -> [LLMMessage] {
        guard let system, !system.isEmpty else { return messages }
        return [.system(system)] + messages
    }
}
