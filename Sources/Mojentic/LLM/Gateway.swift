import Foundation

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

    /// Issue a structured-output completion and return the decoded JSON
    /// together with the gateway response that carried it.
    ///
    /// The broker uses this so structured calls trace the provider's usage,
    /// model, finish reason and metadata. The default implementation calls
    /// ``completeJSON(model:messages:schema:config:)`` and reports no
    /// provider evidence.
    func completeStructured(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> StructuredGatewayResponse

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

    /// Issue one streaming request for a single turn, with no tools, and
    /// report completion evidence.
    ///
    /// The returned stream yields content, then exactly one terminal event
    /// decided by the provider's own completion rules. Terminating the
    /// stream cancels the request. Throws
    /// ``MojenticError/streamEventsUnsupported`` before sending anything when
    /// the gateway does not support this API; that is the default.
    func completeStreamEvents(
        model: String,
        messages: [LLMMessage],
        config: CompletionConfig
    ) throws(MojenticError) -> AsyncStream<CompletionStreamEvent>
}

extension LLMGateway {
    /// Default implementation: the gateway does not support single-turn
    /// event streams.
    ///
    /// Throws ``MojenticError/streamEventsUnsupported`` without sending a request.
    public func completeStreamEvents(
        model _: String,
        messages _: [LLMMessage],
        config _: CompletionConfig
    ) throws(MojenticError) -> AsyncStream<CompletionStreamEvent> {
        throw .streamEventsUnsupported
    }

    /// Default implementation that reports no provider evidence.
    ///
    /// Delegates to ``completeJSON(model:messages:schema:config:)`` and
    /// uses the re-encoded JSON value as the response content.
    public func completeStructured(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> StructuredGatewayResponse {
        let value = try await completeJSON(
            model: model,
            messages: messages,
            schema: schema,
            config: config
        )
        let content = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return StructuredGatewayResponse(value: value, response: LLMGatewayResponse(content: content))
    }
}
