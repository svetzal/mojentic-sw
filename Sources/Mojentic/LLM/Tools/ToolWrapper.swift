import Foundation

/// Adapts an ``LLMBroker`` invocation into an ``LLMTool``.
///
/// Useful for the "broker-as-tool" / "agent-as-tool" pattern: a specialised
/// LLM (e.g. a summariser, a translator) exposed to a parent broker as if
/// it were a plain tool. The wrapped broker's tracer events nest correctly
/// under the parent's correlation tree thanks to ``TracerContextAwareTool``.
///
/// The wrapped broker runs with the same `model`, `tools`, and `config` on
/// every invocation; the LLM passes its instruction as the `input` field of
/// the tool arguments.
public struct ToolWrapper: TracerContextAwareTool {
    private let broker: LLMBroker
    private let model: String
    private let systemPrompt: String?
    private let tools: [any LLMTool]
    private let config: CompletionConfig
    /// Descriptor surfaced to the parent LLM.
    public let descriptor: ToolDescriptor

    /// Create a tool that wraps a broker invocation.
    ///
    /// - Parameters:
    ///   - broker: The broker to invoke when this tool fires.
    ///   - model: Model identifier passed to the wrapped broker.
    ///   - name: Tool name surfaced to the parent broker.
    ///   - description: Tool description surfaced to the parent broker.
    ///   - systemPrompt: Optional system prompt prepended to every wrapped call.
    ///   - tools: Tools the wrapped broker may use itself.
    ///   - config: Completion configuration for the wrapped broker.
    public init(
        broker: LLMBroker,
        model: String,
        name: String,
        description: String,
        systemPrompt: String? = nil,
        tools: [any LLMTool] = [],
        config: CompletionConfig = CompletionConfig()
    ) {
        self.broker = broker
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.config = config
        self.descriptor = ToolDescriptor(
            name: name,
            description: description,
            parameters: [
                "type": "object",
                "properties": ["input": ["type": "string"]],
                "required": ["input"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the wrapped broker with no tracer context.
    ///
    /// Prefer ``executeWithContext(arguments:tracer:context:)`` so events nest
    /// under the parent's correlation tree. The runner picks the contextual
    /// overload automatically via ``TracerContextAwareTool``.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        try await executeWithContext(
            arguments: arguments,
            tracer: NullTracer(),
            context: TracerContext()
        )
    }

    /// Execute the wrapped broker, threading the parent's tracer context.
    public func executeWithContext(
        arguments: JSONValue,
        tracer _: any Tracer,
        context: TracerContext
    ) async throws -> JSONValue {
        guard let input = arguments.objectValue?["input"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "\(descriptor.name) requires 'input'")
        }
        var messages: [LLMMessage] = []
        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(input))
        let response = try await broker.complete(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            context: context
        )
        return ["response": .string(response.content)]
    }
}
