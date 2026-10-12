extension OllamaGateway {
    /// Documented recovery facilities for Ollama.
    ///
    /// Endpoint: `POST /api/chat`. Every value below was inspected on October 12, 2026.
    /// [Provider reference](https://docs.ollama.com/api/chat) is the evidence for the endpoint facilities.
    /// [URLSessionTask cancellation](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
    /// establishes local task cancellation only.
    ///
    /// | Facility | Support | Evidence in the inspected reference |
    /// | --- | --- | --- |
    /// | Local request cancellation | supported | Local task cancellation; no remote guarantee |
    /// | Remote request cancellation | unsupported | No active-request cancellation operation described |
    /// | Request status | unsupported | No active exact-attempt status query described |
    /// | Idempotency | unknown | No inference deduplication guarantee specified |
    /// | Exact-attempt termination | unknown | No evidence for one particular attempt |
    ///
    /// See <doc:RecoveryCapabilities> for the capability criteria and limits.
    public static var recoveryCapabilities: CompletionRecoveryCapabilities {
        CompletionRecoveryCapabilities()
    }
}

extension OMLXGateway {
    /// Documented recovery facilities for oMLX.
    ///
    /// Endpoint: `POST /v1/chat/completions`. Every value below was inspected on October 12, 2026.
    /// [Provider reference](https://github.com/jundot/omlx) is the evidence for the endpoint facilities.
    /// [URLSessionTask cancellation](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
    /// establishes local task cancellation only.
    ///
    /// | Facility | Support | Evidence in the inspected reference |
    /// | --- | --- | --- |
    /// | Local request cancellation | supported | Local task cancellation; no remote guarantee |
    /// | Remote request cancellation | unsupported | No active-request cancellation operation described |
    /// | Request status | unsupported | No active exact-attempt status query described |
    /// | Idempotency | unknown | No inference deduplication guarantee specified |
    /// | Exact-attempt termination | unknown | No evidence for one particular attempt |
    ///
    /// See <doc:RecoveryCapabilities> for the capability criteria and limits.
    public static var recoveryCapabilities: CompletionRecoveryCapabilities {
        CompletionRecoveryCapabilities()
    }
}

extension OpenAIGateway {
    /// Documented recovery facilities for OpenAI Chat Completions.
    ///
    /// Endpoint: `POST https://api.openai.com/v1/chat/completions`. Every value below was inspected on October 12, 2026.
    /// [Provider reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) is the evidence for the endpoint facilities.
    /// [URLSessionTask cancellation](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
    /// establishes local task cancellation only.
    ///
    /// | Facility | Support | Evidence in the inspected reference |
    /// | --- | --- | --- |
    /// | Local request cancellation | supported | Local task cancellation; no remote guarantee |
    /// | Remote request cancellation | unsupported | No active-request cancellation operation described |
    /// | Request status | unsupported | No active exact-attempt status query described |
    /// | Idempotency | unknown | No inference deduplication guarantee specified |
    /// | Exact-attempt termination | unknown | No evidence for one particular attempt |
    ///
    /// See <doc:RecoveryCapabilities> for the capability criteria and limits.
    public static var recoveryCapabilities: CompletionRecoveryCapabilities {
        CompletionRecoveryCapabilities()
    }
}

#if anthropic
    extension AnthropicGateway {
        /// Documented recovery facilities for Anthropic Messages.
        ///
        /// Endpoint: `POST https://api.anthropic.com/v1/messages`. Every value below was inspected on October 12, 2026.
        /// [Provider reference](https://platform.claude.com/docs/en/api/messages/create) is the evidence for the endpoint facilities.
        /// [URLSessionTask cancellation](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
        /// establishes local task cancellation only.
        ///
        /// | Facility | Support | Evidence in the inspected reference |
        /// | --- | --- | --- |
        /// | Local request cancellation | supported | Local task cancellation; no remote guarantee |
        /// | Remote request cancellation | unsupported | No active-request cancellation operation described |
        /// | Request status | unsupported | No active exact-attempt status query described |
        /// | Idempotency | unknown | No inference deduplication guarantee specified |
        /// | Exact-attempt termination | unknown | No evidence for one particular attempt |
        ///
        /// See <doc:RecoveryCapabilities> for the capability criteria and limits.
        public static var recoveryCapabilities: CompletionRecoveryCapabilities {
            CompletionRecoveryCapabilities()
        }
    }
#endif
