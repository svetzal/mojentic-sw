import Foundation

extension LLMBroker {
    func streamRecursive(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool],
        config: CompletionConfig,
        remaining: Int?,
        context: TracerContext,
        deliver: @escaping @Sendable (StreamEvent) async throws -> Void,
        retained: [LLMMessage] = [],
    ) async throws {
        if let remaining, remaining <= 0 {
            throw MojenticError.toolDepthExceeded(limit: config.maxToolIterations ?? remaining)
        }
        try Task.checkCancellation()
        let callPayload = LLMCallPayload(
            correlationId: context.correlationId,
            parentId: context.parentId,
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools.map(\.descriptor.name),
        )
        await tracer.recordLLMCall(callPayload)
        var accumulatedContent = ""
        var accumulatedThinking = ""
        var accumulatedCalls: [LLMToolCall] = []
        var completed = false
        var finishReason: FinishReason?
        var usage: Usage?

        let clock = ContinuousClock()
        let start = clock.now
        let upstream = gateway.streamRecovering(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            config: config,
        )
        for try await event in upstream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                accumulatedContent += delta
                try await deliver(.textDelta(delta))
            case .progress, .metrics: break
            case .thinkingDelta(let delta):
                accumulatedThinking += delta
                try await deliver(.thinkingDelta(delta))
            case .toolCallRequest(let call):
                accumulatedCalls.append(call)
                try await deliver(.toolCallRequested(call))
            case .done(let reason, let reportedUsage):
                completed = true
                finishReason = reason
                usage = reportedUsage
            }
        }
        try Task.checkCancellation()
        if config.retainThinking, !completed {
            throw MojenticError.incompleteStream(nil)
        }
        if !accumulatedCalls.isEmpty {
            // This turn completed; tool execution and subsequent requests are separate attempts.
            RecoveryTerminalAccounting.current?.settle()
        }
        let toolContext = await recordStreamResponse(
            context: context,
            callID: callPayload.id,
            model: model,
            duration: start.duration(to: clock.now),
            response: LLMGatewayResponse(
                content: accumulatedContent,
                toolCalls: accumulatedCalls,
                thinking: accumulatedThinking.isEmpty ? nil : accumulatedThinking,
                finishReason: finishReason,
                usage: usage
            )
        )

        if !accumulatedCalls.isEmpty {
            let dispatched = try await dispatchStream(
                toolCalls: accumulatedCalls,
                tools: tools,
                context: toolContext,
                deliver: deliver
            )
            let nextMessages = appendToolExchange(
                to: messages,
                pairs: dispatched,
                content: accumulatedContent,
                thinking: accumulatedThinking.isEmpty ? nil : accumulatedThinking,
                retain: config.retainThinking
            )
            try await streamRecursive(
                model: model,
                messages: nextMessages,
                tools: tools,
                config: config,
                remaining: remaining.map { $0 - 1 },
                context: context,
                deliver: deliver,
                retained: retained + Array(nextMessages.dropFirst(messages.count)),
            )
            return
        }

        let response = retainedStreamResponse(
            content: accumulatedContent,
            thinking: accumulatedThinking.isEmpty ? nil : accumulatedThinking,
            finishReason: finishReason,
            usage: usage,
            retained: config.retainThinking ? retained : nil
        )
        try Task.checkCancellation()
        try await deliver(.done(response))
    }

    private func recordStreamResponse(
        context: TracerContext,
        callID: UUID,
        model: String,
        duration: Duration,
        response: LLMGatewayResponse
    ) async -> TracerContext {
        let payload = LLMResponsePayload(
            correlationId: context.correlationId,
            parentId: callID,
            duration: duration,
            model: model,
            response: response
        )
        await tracer.recordLLMResponse(payload)
        return context.child(parent: payload.id)
    }

    private func dispatchStream(
        toolCalls: [LLMToolCall],
        tools: [any LLMTool],
        context: TracerContext,
        deliver: @escaping @Sendable (StreamEvent) async throws -> Void
    ) async throws -> [(LLMToolCall, ToolCallOutcome)] {
        let dispatched = try await RecoveryTerminalAccounting.$current.withValue(nil) {
            try await dispatch(
                toolCalls: toolCalls,
                tools: tools,
                context: context,
            )
        }
        for (call, outcome) in dispatched {
            let result: JSONValue =
                switch outcome.kind {
                case .success(let value): value
                case .failure(let message): ["error": .string(message)]
                }
            try await deliver(
                .toolCallResult(
                    callId: call.id ?? outcome.id,
                    result: result))
        }
        return dispatched
    }

    private func retainedStreamResponse(
        content: String,
        thinking: String?,
        finishReason: FinishReason?,
        usage: Usage?,
        retained: [LLMMessage]?
    ) -> LLMResponse {
        LLMResponse(
            content: content,
            thinking: thinking,
            finishReason: finishReason,
            usage: usage,
            retainedMessages: retained.map {
                $0 + [
                    .assistant(
                        content,
                        thinking: thinking)
                ]
            } ?? []
        )
    }

}
