/// Streaming event surfaced by `LLMGateway.stream`.
///
/// Gateways emit a normalised stream of these so the broker can run its
/// tool-call recursion uniformly across providers.
public enum GatewayStreamEvent: Sendable {
    /// A delta of assistant text content.
    case textDelta(String)

    /// A delta of model reasoning trace (provider-supplied).
    case thinkingDelta(String)

    /// One fully-assembled tool-call request the model wants to invoke.
    case toolCallRequest(LLMToolCall)

    /// The provider declared the stream complete. May carry finish reason
    /// and usage when reported.
    case done(finishReason: FinishReason?, usage: Usage?)
}

/// Abstraction over an LLM provider.
///
/// Phase 1 ships `OllamaGateway`; OpenAI and Anthropic follow in later phases.
///
/// Gateways are thin transport wrappers — they own request shaping, the
/// HTTP/WebSocket transport, and response normalisation. Business decisions
/// (recursion, retries, tool dispatch) live in the broker.
public protocol LLMGateway: Sendable {
    /// Issue a non-streaming completion request and return the single
    /// response payload.
    func complete(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) async throws -> LLMGatewayResponse

    /// Issue a structured-output completion request and return raw JSON
    /// matching `schema`.
    func completeJSON(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> JSONValue

    /// List models available on the provider.
    func availableModels() async throws -> [String]

    /// Issue a streaming completion. Events arrive as `GatewayStreamEvent`s
    /// over an `AsyncThrowingStream`. Cancellation propagates via the
    /// stream's continuation.
    func stream(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error>
}
