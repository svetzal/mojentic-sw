import Foundation

/// Reuses buffered admission and classification for one immutable streaming request.
enum StreamingRecovery {
    private struct Delivery: Sendable {
        let events: @Sendable (RecoveryGatewayStreamEvent) async throws -> Void
        let terminal: @Sendable (CompletionEvidence) async throws -> Void
    }

    static func gatewayEvents(
        policy: CompletionRecoveryPolicy,
        provider: String,
        url: URL,
        headers: [String: String],
        body: some Encodable & Sendable,
        timeout: TimeInterval?,
    ) -> AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error> {
        let delivery = RecoveryDelivery<RecoveryGatewayStreamEvent>()
        let scope = RecoveryCancellationScope.current
        let producerID = UUID()
        scope?.prepare(producerID)
        let task = Task {
            defer { scope?.remove(producerID) }
            do {
                try await run(
                    policy: policy,
                    provider: provider,
                    endpoint: (url, headers),
                    body: body,
                    timeout: timeout,
                    singleTurn: false,
                    delivery: Delivery(
                        events: { event in
                            try await delivery.send(event)
                        },
                        terminal: { evidence in
                            try await delivery.send(
                                .done(
                                    finishReason: evidence.finishReason.map { reason in
                                        if provider == "anthropic" {
                                            return reason == "tool_use" ? .toolCalls : .stop
                                        }
                                        return FinishReason(rawValue: reason) ?? .other
                                    },
                                    usage: evidence.usage,
                                )
                            )
                        },
                    ),
                )
                delivery.finish()
            } catch { delivery.finish(error) }
        }
        scope?.register(task, id: producerID)
        let owner = RecoveryProducer(task)
        return AsyncThrowingStream(unfolding: {
            try await withTaskCancellationHandler {
                try await delivery.next()
            } onCancel: {
                delivery.cancel()
                owner.task.cancel()
            }
        })
    }

    static func completionEvents(
        policy: CompletionRecoveryPolicy,
        provider: String,
        url: URL,
        headers: [String: String],
        body: some Encodable & Sendable,
        timeout: TimeInterval?,
    ) -> AsyncStream<RecoveryCompletionStreamEvent> {
        let delivery = RecoveryDelivery<RecoveryCompletionStreamEvent>()
        let scope = RecoveryCancellationScope.current
        let producerID = UUID()
        scope?.prepare(producerID)
        let task = Task {
            defer { scope?.remove(producerID) }
            do {
                try await run(
                    policy: policy,
                    provider: provider,
                    endpoint: (url, headers),
                    body: body,
                    timeout: timeout,
                    singleTurn: true,
                    delivery: Delivery(
                        events: { event in
                            let output: RecoveryCompletionStreamEvent
                            switch event {
                            case .textDelta(let text): output = .content(text)
                            case .progress(let progress): output = .progress(progress)
                            case .metrics(let evidence): output = .metrics(evidence)
                            default: return
                            }
                            try await delivery.send(output)
                        },
                        terminal: { evidence in
                            try await delivery.send(.completed(evidence))
                        },
                    ),
                )
            } catch let error as RecoveryError { delivery.terminal(.recoveryFailure(error)) } catch {
                delivery.terminal(
                    .error(Task.isCancelled ? .cancelled : .requestFailed(message: "Recovery setup failed"))
                )
            }
            delivery.finish()
        }
        scope?.register(task, id: producerID)
        let owner = RecoveryProducer(task)
        return AsyncStream(
            unfolding: { do { return try await delivery.next() } catch { return nil } },
            onCancel: {
                delivery.cancel()
                owner.task.cancel()
            },
        )
    }

    private static func run(
        policy: CompletionRecoveryPolicy,
        provider: String,
        endpoint: (URL, [String: String]),
        body: some Encodable & Sendable,
        timeout: TimeInterval?,
        singleTurn: Bool,
        delivery: Delivery,
    ) async throws {
        var engine = BufferedRecovery(policy: policy, provider: provider, operation: "streaming")
        try engine.validatePolicy()
        let bytes: Data
        do {
            try Task.checkCancellation()
            bytes = try JSONEncoder().encode(body)
        } catch {
            throw engine.terminal(error, outcome: .encoding, category: .protocolFailure, recordAttempt: false)
        }
        for number in 1...policy.maximumAttempts {
            let decoder = RecoveryStreamDecoder(provider: provider, singleTurn: singleTurn)
            let result = try await dispatch(
                engine: &engine,
                endpoint: endpoint,
                bytes: bytes,
                timeout: timeout,
                number: number,
                decoder: decoder,
                deliver: delivery.events,
            )
            engine.wire = result
            let snapshot = decoder.snapshot()
            let progress = snapshot.progress
            let evidence = snapshot.evidence
            engine.progress = progress
            engine.progress.headersReceived = result.response != nil
            if Task.isCancelled {
                throw engine.terminal(
                    result.cause ?? CancellationError(),
                    outcome: .cancelled,
                    category: .cancellation,
                )
            }
            if result.captureFailed {
                throw engine.terminal(
                    result.cause ?? CancellationError(),
                    outcome: .captureFailed,
                    category: .capture,
                )
            }
            if let parserFailure = snapshot.failure {
                let outcome: RecoveryTransition =
                    if progress.observed == RecoverySemanticProgress() {
                        .malformedResponse
                    } else {
                        .interrupted
                    }
                let category: RecoveryCategory =
                    if case .providerError = parserFailure {
                        .providerResponse
                    } else {
                        .protocolFailure
                    }
                throw engine.terminal(parserFailure, outcome: outcome, category: category)
            }
            if snapshot.terminal {
                try await deliverTerminal(engine, evidence: evidence, send: delivery.terminal)
                return
            }
            let status = result.response?.statusCode
            let category = BufferedRecovery.category(for: result)
            let failure = engine.makeFailure(
                category: category,
                cause: result.cause ?? status.map { RecoveryHTTPStatusFailure(status: $0) }
                    ?? MojenticError.incompleteStream(evidence),
                reason: "requestFailed",
            )
            engine.history.append(failure)
            engine.emit(.attemptFailed, category: category)
            if engine.started == nil {
                engine.started = policy.timing.monotonic()
            }
            if progress.observed != RecoverySemanticProgress() {
                throw engine.finish(.interrupted, failure)
            }
            try await engine.admit(failure, next: number + 1)
        }
        preconditionFailure("Attempt loop always returns or terminates")
    }

    private static func deliverTerminal(
        _ attempt: BufferedRecovery,
        evidence: CompletionEvidence,
        send: @Sendable (CompletionEvidence) async throws -> Void,
    ) async throws {
        var engine = attempt
        if let accounting = RecoveryTerminalAccounting.current {
            accounting.retain { cause in
                var retained = attempt
                if let cause {
                    return retained.terminal(cause, outcome: .cancelled, category: .cancellation)
                }
                retained.emit(.attemptSucceeded)
                retained.policy.reportObserver?(retained.report())
                return nil
            }
            do {
                try await send(evidence)
            } catch {
                throw accounting.settle(error) ?? error
            }
        } else {
            do {
                try await send(evidence)
            } catch {
                throw engine.terminal(error, outcome: .cancelled, category: .cancellation)
            }
            engine.emit(.attemptSucceeded)
            engine.policy.reportObserver?(engine.report())
        }
    }

    private static func dispatch(
        engine: inout BufferedRecovery,
        endpoint: (URL, [String: String]),
        bytes: Data,
        timeout: TimeInterval?,
        number: Int,
        decoder: RecoveryStreamDecoder,
        deliver: @escaping @Sendable (RecoveryGatewayStreamEvent) async throws -> Void,
    ) async throws -> RecoveryHTTPResult {
        try await withThrowingTaskGroup(of: RecoveryHTTPResult?.self) { group in
            group.addTask {
                for await event in decoder.events {
                    if Task.isCancelled {
                        break
                    }
                    do {
                        let output: RecoveryGatewayStreamEvent
                        if case .progress(var progress) = event {
                            progress.delivered = decoder.snapshot().progress.delivered
                            output = .progress(progress)
                        } else {
                            output = event
                        }
                        try await deliver(output)
                        decoder.delivered(output)
                        RecoveryDeliveryScheduling.didDeliver?()
                    } catch { break }
                }
                return nil
            }
            let result = try await engine.dispatch(
                url: endpoint.0,
                headers: endpoint.1,
                bytes: bytes,
                timeout: timeout,
                number: number,
                stream: decoder,
            )
            decoder.finish()
            while try await group.next() != nil {}
            return result
        }
    }
}
