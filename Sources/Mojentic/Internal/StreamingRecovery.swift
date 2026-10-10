import Foundation

/// Reuses buffered admission and classification for one immutable streaming request.
enum StreamingRecovery {
    static func gatewayEvents(
        policy: CompletionRecoveryPolicy,
        provider: String,
        url: URL,
        headers: [String: String],
        body: some Encodable & Sendable,
        timeout: TimeInterval?
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        let delivery = RecoveryDelivery<GatewayStreamEvent>()
        let task = Task {
            do {
                let evidence = try await run(
                    policy: policy,
                    provider: provider,
                    endpoint: (url, headers),
                    body: body,
                    timeout: timeout,
                    singleTurn: false
                ) { event in try await delivery.send(event) }
                try Task.checkCancellation()
                try await delivery.send(
                    .done(
                        finishReason: evidence.finishReason.map { FinishReason(rawValue: $0) ?? .other },
                        usage: evidence.usage
                    ))
                delivery.finish()
            } catch { delivery.finish(error) }
        }
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
        timeout: TimeInterval?
    ) -> AsyncStream<CompletionStreamEvent> {
        let delivery = RecoveryDelivery<CompletionStreamEvent>()
        let task = Task {
            do {
                let evidence = try await run(
                    policy: policy,
                    provider: provider,
                    endpoint: (url, headers),
                    body: body,
                    timeout: timeout,
                    singleTurn: true
                ) { event in
                    let output: CompletionStreamEvent
                    switch event {
                    case .textDelta(let text): output = .content(text)
                    case .progress(let progress): output = .progress(progress)
                    case .metrics(let evidence): output = .metrics(evidence)
                    default: return
                    }
                    try await delivery.send(output)
                }
                try Task.checkCancellation()
                try await delivery.send(.completed(evidence))
            } catch let error as RecoveryError {
                delivery.terminal(.error(.recovery(error)))
            } catch {
                delivery.terminal(
                    .error(
                        Task.isCancelled ? .cancelled : .requestFailed(message: "Recovery setup failed")
                    ))
            }
            delivery.finish()
        }
        let owner = RecoveryProducer(task)
        return AsyncStream(
            unfolding: {
                do { return try await delivery.next() } catch { return nil }
            },
            onCancel: {
                delivery.cancel()
                owner.task.cancel()
            })
    }

    private static func run(
        policy: CompletionRecoveryPolicy,
        provider: String,
        endpoint: (URL, [String: String]),
        body: some Encodable & Sendable,
        timeout: TimeInterval?,
        singleTurn: Bool,
        deliver: @escaping @Sendable (GatewayStreamEvent) async throws -> Void
    ) async throws -> CompletionEvidence {
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
            let result = try await withThrowingTaskGroup(of: RecoveryHTTPResult?.self) { group in
                group.addTask {
                    for await event in decoder.events {
                        if Task.isCancelled { break }
                        do {
                            let output: GatewayStreamEvent
                            if case .progress(var progress) = event {
                                progress.delivered = decoder.snapshot().progress.delivered
                                output = .progress(progress)
                            } else {
                                output = event
                            }
                            try await deliver(output)
                            decoder.delivered(output)
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
                    stream: decoder
                )
                decoder.finish()
                while try await group.next() != nil {}
                return result
            }
            engine.wire = result
            let snapshot = decoder.snapshot()
            let progress = snapshot.progress
            let evidence = snapshot.evidence
            engine.progress = progress
            engine.progress.headersReceived = result.response != nil
            if Task.isCancelled {
                throw engine.terminal(
                    result.cause ?? CancellationError(), outcome: .cancelled, category: .cancellation)
            }
            if result.captureFailed {
                throw engine.terminal(
                    result.cause ?? CancellationError(), outcome: .captureFailed, category: .capture
                )
            }
            if let parserFailure = snapshot.failure {
                let outcome: RecoveryTransition =
                    progress.observed == RecoverySemanticProgress()
                    ? .malformedResponse : .interrupted
                let category: RecoveryCategory
                if case .providerError = parserFailure {
                    category = .providerResponse
                } else {
                    category = .protocolFailure
                }
                throw engine.terminal(parserFailure, outcome: outcome, category: category)
            }
            if snapshot.terminal {
                policy.reportObserver?(engine.report())
                if Task.isCancelled {
                    throw engine.terminal(CancellationError(), outcome: .cancelled, category: .cancellation)
                }
                engine.emit(.attemptSucceeded)
                if Task.isCancelled {
                    throw engine.terminal(CancellationError(), outcome: .cancelled, category: .cancellation)
                }
                return evidence
            }
            let status = result.response?.statusCode
            let category = BufferedRecovery.category(for: result)
            let failure = engine.makeFailure(
                category: category,
                cause: result.cause ?? status.map { RecoveryHTTPStatusFailure(status: $0) }
                    ?? MojenticError.incompleteStream(evidence), reason: "requestFailed"
            )
            engine.history.append(failure)
            engine.emit(.attemptFailed, category: category)
            if engine.started == nil { engine.started = policy.timing.monotonic() }
            if progress.observed != RecoverySemanticProgress() { throw engine.finish(.interrupted, failure) }
            try await engine.admit(failure, next: number + 1)
        }
        preconditionFailure("Attempt loop always returns or terminates")
    }
}
