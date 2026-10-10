import Foundation

extension OMLXGateway {
    /// Stream with opt-in recovery telemetry and typed failures.
    public func streamRecovering(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig,
    ) -> AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error> {
        let body = Self.chatBody(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            stream: true,
            responseFormat: config.responseFormat.map(OpenAIGateway.responseFormatPayload),
        )
        let settings = recoveryStreamConfiguration
        if let recovery = settings.policy {
            return StreamingRecovery.gatewayEvents(
                policy: recovery,
                provider: "omlx",
                url: settings.url,
                headers: settings.headers,
                body: body,
                timeout: settings.timeout,
            )
        }
        return RecoveryStreamBridge.lift(
            stream(model: model, messages: messages, tools: tools, config: config))
    }

    /// Stream with opt-in recovery telemetry and typed failures.
    public func completeStreamEventsRecovering(
        model: String,
        messages: [LLMMessage],
        config: CompletionConfig,
    ) -> AsyncStream<RecoveryCompletionStreamEvent> {
        var body = Self.chatBody(
            model: model,
            messages: messages,
            tools: nil,
            config: config,
            stream: true,
            responseFormat: config.responseFormat.map(OpenAIGateway.responseFormatPayload),
        )
        if case .object(var fields) = body {
            fields["stream_options"] = ["include_usage": true]
            body = .object(fields)
        }
        let settings = recoveryStreamConfiguration
        if let recovery = settings.policy {
            return StreamingRecovery.completionEvents(
                policy: recovery,
                provider: "omlx",
                url: settings.url,
                headers: settings.headers,
                body: body,
                timeout: settings.timeout,
            )
        }
        return RecoveryStreamBridge.lift(
            completeStreamEvents(model: model, messages: messages, config: config))
    }

}

/// Immutable settings for the opt-in streaming boundary.
struct OMLXRecoveryStreamConfiguration: Sendable {
    let policy: CompletionRecoveryPolicy?
    let url: URL
    let headers: [String: String]
    let timeout: TimeInterval
}
