extension OllamaGateway {
    /// Request status, remote cancellation and idempotency are unsupported by this adapter.
    public static var recoveryCapabilities: CompletionRecoveryCapabilities {
        CompletionRecoveryCapabilities()
    }
}

extension OMLXGateway {
    /// Request status, remote cancellation and idempotency are unsupported by this adapter.
    public static var recoveryCapabilities: CompletionRecoveryCapabilities {
        CompletionRecoveryCapabilities()
    }
}

extension OpenAIGateway {
    /// Request status, remote cancellation and idempotency are unsupported by this adapter.
    public static var recoveryCapabilities: CompletionRecoveryCapabilities {
        CompletionRecoveryCapabilities()
    }
}
