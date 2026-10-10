import Foundation

/// An opt-in streaming boundary that preserves telemetry and typed recovery failures.
public protocol RecoveryStreamingGateway: LLMGateway {
    /// Stream chat events with recovery metadata when a recovery policy is configured.
    func streamRecovering(
        model: String, messages: [LLMMessage], tools: [any LLMTool]?, config: CompletionConfig
    ) -> AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error>

    /// Stream one turn with explicit terminal recovery failures and provider telemetry.
    func completeStreamEventsRecovering(
        model: String, messages: [LLMMessage], config: CompletionConfig
    ) -> AsyncStream<RecoveryCompletionStreamEvent>
}

extension LLMGateway {
    /// Use the opt-in boundary when supported, otherwise lift the legacy event stream.
    public func streamRecovering(
        model: String, messages: [LLMMessage], tools: [any LLMTool]?, config: CompletionConfig
    ) -> AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error> {
        if let recovering = self as? any RecoveryStreamingGateway {
            return recovering.streamRecovering(model: model, messages: messages, tools: tools, config: config)
        }
        return RecoveryStreamBridge.lift(
            stream(model: model, messages: messages, tools: tools, config: config))
    }

    /// Use the opt-in single-turn boundary when supported, otherwise preserve legacy completion events.
    public func completeStreamEventsRecovering(
        model: String, messages: [LLMMessage], config: CompletionConfig
    ) throws(MojenticError) -> AsyncStream<RecoveryCompletionStreamEvent> {
        if let recovering = self as? any RecoveryStreamingGateway {
            return recovering.completeStreamEventsRecovering(model: model, messages: messages, config: config)
        }
        return RecoveryStreamBridge.lift(
            try completeStreamEvents(model: model, messages: messages, config: config))
    }
}

/// Lifts legacy events without adding telemetry or interpreting provider completion evidence.
enum RecoveryStreamBridge {
    static func lift(_ event: GatewayStreamEvent) -> RecoveryGatewayStreamEvent {
        switch event {
        case .textDelta(let text): .textDelta(text)
        case .thinkingDelta(let text): .thinkingDelta(text)
        case .toolCallRequest(let call): .toolCallRequest(call)
        case .done(let reason, let usage): .done(finishReason: reason, usage: usage)
        }
    }

    static func lift(
        _ upstream: AsyncThrowingStream<GatewayStreamEvent, any Error>
    ) -> AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error> {
        RecoveryScopedStreaming.throwing { deliver in
            for try await event in upstream {
                try await deliver(lift(event))
            }
        }
    }

    static func lift(
        _ upstream: AsyncStream<CompletionStreamEvent>
    ) -> AsyncStream<RecoveryCompletionStreamEvent> {
        RecoveryScopedStreaming.completion { deliver in
            for await event in upstream {
                switch event {
                case .content(let text): try await deliver(.content(text))
                case .completed(let evidence): return .completed(evidence)
                case .error(let error): return .error(error)
                }
            }
            return .error(.cancelled)
        }
    }
}
