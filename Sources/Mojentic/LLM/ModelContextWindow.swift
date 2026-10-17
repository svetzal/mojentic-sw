/// A provider-advertised context limit and its provenance.
public struct ModelContextWindow: Sendable, Equatable {
    /// Maximum advertised token count.
    public let maxContextTokens: Int
    /// Provider field that advertised the limit.
    public let field: String
    /// Ollama model parameter used when the request has no context override.
    public let modelNumCtx: Int?

    /// Create an advertised limit with optional model configuration.
    public init(maxContextTokens: Int, field: String, modelNumCtx: Int? = nil) {
        self.maxContextTokens = maxContextTokens
        self.field = field
        self.modelNumCtx = modelNumCtx
    }
}

/// Calculate Ollama's effective upper bound without changing request configuration.
///
/// An explicit request limit takes precedence over the model parameter. Without
/// either, the advertised limit is an upper bound because server defaults are unknown.
/// Unknown metadata stays unknown even when the caller supplies a context size.
public func effectiveContextWindow(_ window: ModelContextWindow?, config: CompletionConfig) -> Int? {
    guard let window else { return nil }
    return min(window.maxContextTokens, config.numCtx ?? window.modelNumCtx ?? window.maxContextTokens)
}
