/// Token-usage accounting reported by the provider for a single completion.
public struct Usage: Sendable, Codable, Hashable {
    /// Tokens in the prompt as reported by the provider, if any.
    public let promptTokens: Int?
    /// Tokens in the completion as reported by the provider, if any.
    public let completionTokens: Int?
    /// Combined prompt + completion tokens as reported by the provider, if any.
    public let totalTokens: Int?

    /// Create a `Usage` record from the provider-reported counts.
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

/// Reason a completion stopped, as reported by the provider.
public enum FinishReason: String, Sendable, Codable, Hashable {
    /// The model finished its turn naturally.
    case stop
    /// The model emitted tool-call requests instead of (or in addition to) text.
    case toolCalls = "tool_calls"
    /// The completion hit the model's token cap.
    case length
    /// The provider terminated the response for safety or policy reasons.
    case contentFilter = "content_filter"
    /// Anything else.
    case other
}

/// The raw, single-pass response a gateway returns to the broker, before any
/// tool-call recursion or post-processing.
public struct LLMGatewayResponse: Sendable, Codable, Hashable {
    /// Text content the model produced.
    ///
    /// May be empty when the model responded only with tool calls.
    public let content: String

    /// Tool-call requests the model wants to invoke before producing its
    /// final answer.
    public let toolCalls: [LLMToolCall]

    /// Optional reasoning trace surfaced by providers that expose one
    /// (Ollama with `think: true`, OpenAI reasoning models).
    public let thinking: String?

    /// Reason the model stopped generating, when reported.
    public let finishReason: FinishReason?

    /// Token usage as reported by the provider, when reported.
    ///
    /// Never estimated: `nil` means the provider did not report usage.
    public let usage: Usage?

    /// Finish reason exactly as the provider reported it (for example
    /// OpenAI `finish_reason`, Ollama `done_reason`, Anthropic `stop_reason`),
    /// when reported.
    ///
    /// ``finishReason`` is the typed mapping and collapses unknown values to
    /// ``FinishReason/other``; this keeps the provider's own string.
    public let providerFinishReason: String?

    /// Model name the provider reported serving the request, when reported.
    ///
    /// May differ from the requested model (for example a dated snapshot).
    public let providerModel: String?

    /// Provider-reported response fields with no typed home, kept as reported.
    ///
    /// Examples are response ids, timestamps, fingerprints and durations.
    /// `nil` when the provider reported none.
    public let metadata: [String: JSONValue]?

    /// Create a raw gateway response payload.
    public init(
        content: String,
        toolCalls: [LLMToolCall] = [],
        thinking: String? = nil,
        finishReason: FinishReason? = nil,
        usage: Usage? = nil,
        providerFinishReason: String? = nil,
        providerModel: String? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.thinking = thinking
        self.finishReason = finishReason
        self.usage = usage
        self.providerFinishReason = providerFinishReason
        self.providerModel = providerModel
        self.metadata = metadata
    }
}

/// A structured-output gateway response: the decoded JSON value plus the
/// gateway response that carried it, with its provider evidence.
public struct StructuredGatewayResponse: Sendable, Hashable {
    /// JSON value decoded from the provider's content.
    public let value: JSONValue

    /// The gateway response, including raw content, usage, provider model,
    /// finish reason and metadata as reported.
    public let response: LLMGatewayResponse

    /// Create a structured gateway response.
    public init(value: JSONValue, response: LLMGatewayResponse) {
        self.value = value
        self.response = response
    }
}

/// The broker-level response surfaced to library consumers after any
/// tool-call recursion has been resolved.
public struct LLMResponse: Sendable, Codable, Hashable {
    /// Final assistant text returned to the caller.
    public let content: String

    /// Reasoning trace, if any, from the final assistant turn.
    public let thinking: String?

    /// Reason the model stopped generating, when reported.
    public let finishReason: FinishReason?

    /// Token usage as reported by the provider for the final turn.
    public let usage: Usage?

    /// Create a broker-level response payload.
    public init(
        content: String,
        thinking: String? = nil,
        finishReason: FinishReason? = nil,
        usage: Usage? = nil
    ) {
        self.content = content
        self.thinking = thinking
        self.finishReason = finishReason
        self.usage = usage
    }
}
