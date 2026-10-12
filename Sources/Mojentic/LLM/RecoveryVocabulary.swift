/// The completion provider used by a recovery request.
///
/// Cases and serialized values are shared by failures, admission observations and lifecycle events.
public enum RecoveryProvider: String, Sendable, Codable, Hashable, CaseIterable {
    /// Ollama completion APIs.
    case ollama
    /// oMLX completion APIs.
    case omlx
    /// OpenAI completion APIs.
    case openAI = "openai"
    /// Anthropic completion APIs, including when the provider trait is disabled.
    case anthropic
}

/// The completion operation used by every recovery adapter.
///
/// Serialized values are `ordinary`, `structured` and `streaming` for every provider.
/// Unknown values and former adapter-specific aliases are rejected during decoding.
public enum RecoveryOperation: String, Sendable, Codable, Hashable, CaseIterable {
    /// Buffered completion through `complete`.
    case ordinary
    /// Buffered structured completion through `completeStructured` or `completeJSON`.
    case structured
    /// Streaming completion through either recovery streaming API.
    case streaming
}
