import Foundation

// MARK: - Single-turn event stream

extension LLMBroker {
    /// Stream one turn with no tools and report whether the provider proved
    /// it complete.
    ///
    /// Yields ``CompletionStreamEvent/content(_:)`` events in order, then
    /// exactly one terminal event: ``CompletionStreamEvent/completed(_:)``
    /// with the provider's evidence, or ``CompletionStreamEvent/error(_:)``.
    /// Nothing follows the terminal event. Truncated or unfinished output is
    /// an error, never a result: content yielded before an error is evidence,
    /// not an answer.
    ///
    /// The broker sends one request, forces `maxToolIterations` to zero, and
    /// never retries or recurses. Stopping consumption (breaking the loop,
    /// dropping the stream or cancelling the task) cancels the request.
    ///
    /// The tracer records the call once the gateway accepts the request, and
    /// the response (content so far plus the provider's evidence) when the
    /// terminal event is reached. When the consumer stops early the call
    /// stays traced and no response is recorded; that is not an error. A
    /// gateway without support yields a single
    /// ``MojenticError/streamEventsUnsupported`` event, sends no request and
    /// records nothing.
    ///
    /// The stream is an `AsyncStream` rather than an `AsyncThrowingStream`:
    /// failures arrive as the terminal ``CompletionStreamEvent/error(_:)``
    /// event so the terminal event is always explicit.
    public nonisolated func generateStreamEvents(
        model: String,
        messages: [LLMMessage],
        config: CompletionConfig = CompletionConfig(),
        context: TracerContext = TracerContext(),
    ) -> AsyncStream<CompletionStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                let terminal = await self.relayStreamEvents(
                    model: model,
                    messages: messages,
                    config: config,
                    context: context,
                    continuation: continuation,
                )
                continuation.yield(terminal)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Forward content events and return the single terminal event, after
    /// recording the traced response.
    private func relayStreamEvents(
        model: String,
        messages: [LLMMessage],
        config: CompletionConfig,
        context: TracerContext,
        continuation: AsyncStream<CompletionStreamEvent>.Continuation,
    ) async -> CompletionStreamEvent {
        var singleTurn = config
        singleTurn.maxToolIterations = 0
        let upstream: AsyncStream<CompletionStreamEvent>
        do {
            upstream = try gateway.completeStreamEvents(
                model: model,
                messages: messages,
                config: singleTurn,
            )
        } catch {
            return .error(error)
        }
        let callPayload = LLMCallPayload(
            correlationId: context.correlationId,
            parentId: context.parentId,
            model: model,
            messages: messages,
            tools: nil,
        )
        await tracer.recordLLMCall(callPayload)
        let clock = ContinuousClock()
        let start = clock.now
        var content = ""
        var terminal: CompletionStreamEvent?
        for await event in upstream {
            if case .content(let text) = event {
                content += text
                continuation.yield(event)
                continue
            }
            terminal = event
            break
        }
        guard let outcome = terminal ?? (Task.isCancelled ? nil : .error(.incompleteStream(nil))) else {
            // The consumer stopped early: the call stays traced, no response is.
            return .error(.cancelled)
        }
        await tracer.recordLLMResponse(
            LLMResponsePayload(
                correlationId: context.correlationId,
                parentId: callPayload.id,
                duration: start.duration(to: clock.now),
                model: model,
                response: Self.tracedResponse(content: content, terminal: outcome),
            )
        )
        return outcome
    }

    private static func tracedResponse(
        content: String,
        terminal: CompletionStreamEvent,
    ) -> LLMGatewayResponse {
        let evidence: CompletionEvidence? =
            switch terminal {
            case .completed(let reported), .error(.incompleteCompletion(let reported)):
                reported
            case .error(.incompleteStream(let reported)):
                reported
            default:
                nil
            }
        return LLMGatewayResponse(
            content: content,
            finishReason: evidence?.finishReason.map { FinishReason(rawValue: $0) ?? .other },
            usage: evidence?.usage,
            providerFinishReason: evidence?.finishReason,
            providerModel: evidence?.providerModel,
            metadata: evidence?.metadata,
        )
    }
}

// MARK: - Single-turn event stream

extension LLMBroker {
    /// Stream one turn with no tools and report whether the provider proved
    /// it complete.
    ///
    /// Yields ``RecoveryCompletionStreamEvent/content(_:)`` events in order, then
    /// exactly one terminal event: ``RecoveryCompletionStreamEvent/completed(_:)``
    /// with the provider's evidence, ``RecoveryCompletionStreamEvent/error(_:)``,
    /// or ``RecoveryCompletionStreamEvent/recoveryFailure(_:)`` retaining typed causes and history.
    /// Nothing follows the terminal event. Truncated or unfinished output is
    /// an error, never a result: content yielded before an error is evidence,
    /// not an answer.
    ///
    /// The broker sends one request, forces `maxToolIterations` to zero, and
    /// never recurses; an enabled gateway may recover that one request. Stopping consumption (breaking the
    /// loop,
    /// dropping the stream or cancelling the task) cancels the request.
    ///
    /// The tracer records the call once the gateway accepts the request, and
    /// the response (content so far plus the provider's evidence) when the
    /// terminal event is reached. When the consumer stops early the call
    /// stays traced and no response is recorded; that is not an error. A
    /// gateway without support yields a single
    /// ``MojenticError/streamEventsUnsupported`` event, sends no request and
    /// records nothing.
    ///
    /// The stream is an `AsyncStream` rather than an `AsyncThrowingStream`:
    /// failures arrive as the terminal ``RecoveryCompletionStreamEvent/error(_:)``
    /// event so the terminal event is always explicit.
    public nonisolated func generateRecoveryStreamEvents(
        model: String,
        messages: [LLMMessage],
        config: CompletionConfig = CompletionConfig(),
        context: TracerContext = TracerContext(),
    ) -> AsyncStream<RecoveryCompletionStreamEvent> {
        if RecoveryCancellationScope.current != nil {
            return RecoveryScopedStreaming.completion { deliver in
                try await self.relayRecoveryStreamEvents(
                    model: model,
                    messages: messages,
                    config: config,
                    context: context,
                    deliver: deliver,
                )
            }
        }
        return AsyncStream { continuation in
            let task = Task {
                let terminal = try? await self.relayRecoveryStreamEvents(
                    model: model,
                    messages: messages,
                    config: config,
                    context: context,
                    deliver: { continuation.yield($0) },
                )
                continuation.yield(terminal ?? .error(.cancelled))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Forward content events and return the single terminal event, after
    /// recording the traced response.
    private func relayRecoveryStreamEvents(
        model: String,
        messages: [LLMMessage],
        config: CompletionConfig,
        context: TracerContext,
        deliver: @escaping @Sendable (RecoveryCompletionStreamEvent) async throws -> Void,
    ) async throws -> RecoveryCompletionStreamEvent {
        var singleTurn = config
        singleTurn.maxToolIterations = 0
        let upstream: AsyncStream<RecoveryCompletionStreamEvent>
        do {
            upstream = try gateway.completeStreamEventsRecovering(
                model: model,
                messages: messages,
                config: singleTurn,
            )
        } catch { return .error(error) }
        let callPayload = LLMCallPayload(
            correlationId: context.correlationId,
            parentId: context.parentId,
            model: model,
            messages: messages,
            tools: nil,
        )
        await tracer.recordLLMCall(callPayload)
        let clock = ContinuousClock()
        let start = clock.now
        var content = ""
        var terminal: RecoveryCompletionStreamEvent?
        for await event in upstream {
            if case .content(let text) = event {
                content += text
                try await deliver(event)
                continue
            }
            if !event.isTerminal {
                try await deliver(event)
                continue
            }
            terminal = event
            break
        }
        guard let outcome = terminal ?? (Task.isCancelled ? nil : .error(.incompleteStream(nil))) else {
            // The consumer stopped early: the call stays traced, no response is.
            return .error(.cancelled)
        }
        await tracer.recordLLMResponse(
            LLMResponsePayload(
                correlationId: context.correlationId,
                parentId: callPayload.id,
                duration: start.duration(to: clock.now),
                model: model,
                response: Self.tracedRecoveryResponse(content: content, terminal: outcome),
            )
        )
        return outcome
    }

    private static func tracedRecoveryResponse(
        content: String,
        terminal: RecoveryCompletionStreamEvent,
    ) -> LLMGatewayResponse {
        let evidence: CompletionEvidence? =
            switch terminal {
            case .completed(let reported), .error(.incompleteCompletion(let reported)): reported
            case .error(.incompleteStream(let reported)): reported
            default: nil
            }
        return LLMGatewayResponse(
            content: content,
            finishReason: evidence?.finishReason.map { FinishReason(rawValue: $0) ?? .other },
            usage: evidence?.usage,
            providerFinishReason: evidence?.finishReason,
            providerModel: evidence?.providerModel,
            metadata: evidence?.metadata,
        )
    }
}
