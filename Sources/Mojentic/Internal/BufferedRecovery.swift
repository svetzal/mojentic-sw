import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Request recovery owns no broker state and never executes tools.
struct BufferedRecovery {
    let policy: CompletionRecoveryPolicy
    let provider: String
    let operation: String
    let logicalID = UUID()
    var identity: RecoveryIdentity?
    var progress = RecoveryProgress()
    var history: [RecoveryFailure] = []
    var wire: RecoveryHTTPResult?
    var started: TimeInterval?

    mutating func run(
        url: URL,
        headers: [String: String],
        body: some Encodable,
        timeout: TimeInterval?,
        decode: @Sendable (Data, [HTTPHeader]) throws -> LLMGatewayResponse
    ) async throws -> LLMGatewayResponse {
        try await run(
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            decode: decode,
            project: { $0 }
        )
    }

    mutating func run<Result: Sendable>(
        url: URL,
        headers: [String: String],
        body: some Encodable,
        timeout: TimeInterval?,
        decode: @Sendable (Data, [HTTPHeader]) throws -> LLMGatewayResponse,
        project: (LLMGatewayResponse) throws -> Result
    ) async throws -> Result {
        try validatePolicy()
        let bytes: Data
        do {
            try Task.checkCancellation()
            bytes = try JSONEncoder().encode(body)
        } catch {
            throw terminal(
                error,
                outcome: Task.isCancelled ? .cancelled : .encoding,
                category: .protocolFailure
            )
        }
        for number in 1...policy.maximumAttempts {
            let result = try await dispatch(
                url: url,
                headers: headers,
                bytes: bytes,
                timeout: timeout,
                number: number
            )
            wire = result
            progress.headersReceived = result.response != nil
            progress.rawBytes = result.body.count
            progress.observed = result.observed
            var decoded: LLMGatewayResponse?
            var decodeCause: (any Error)?
            let successfulStatus = result.response.map { (200..<300).contains($0.statusCode) } == true
            // Received semantic evidence must be accounted for before sensitive capture.
            if successfulStatus {
                do {
                    decoded = try decode(
                        result.body,
                        result.headers.map { HTTPHeader(name: $0.key, value: $0.value) }
                    )
                    if let decoded { observe(decoded) }
                } catch { decodeCause = error }
            }
            if result.captureFailed {
                throw terminal(
                    result.cause ?? CancellationError(),
                    outcome: .captureFailed,
                    category: .capture
                )
            }
            if Task.isCancelled {
                throw terminal(
                    result.cause ?? CancellationError(),
                    outcome: .cancelled,
                    category: .cancellation
                )
            }
            if successfulStatus, result.cause == nil, let decoded {
                let projected: Result
                do {
                    projected = try project(decoded)
                    try Task.checkCancellation()
                } catch {
                    throw terminal(
                        error,
                        outcome: Task.isCancelled ? .cancelled : .malformedResponse,
                        category: .protocolFailure
                    )
                }
                progress.delivered = progress.observed
                policy.reportObserver?(report())
                if Task.isCancelled {
                    progress.delivered = RecoverySemanticProgress()
                    throw terminal(CancellationError(), outcome: .cancelled, category: .cancellation)
                }
                emit(.attemptSucceeded)
                if Task.isCancelled {
                    progress.delivered = RecoverySemanticProgress()
                    throw terminal(CancellationError(), outcome: .cancelled, category: .cancellation)
                }
                return projected
            }
            let category = Self.category(for: result)
            let failure = makeFailure(
                category: category,
                cause: result.cause ?? decodeCause
                    ?? result.response.map { RecoveryHTTPStatusFailure(status: $0.statusCode) },
                reason: "requestFailed"
            )
            if started == nil { started = policy.timing.monotonic() }
            history.append(failure)
            emit(.attemptFailed, category: category)
            try await admit(failure, next: number + 1)
        }
        preconditionFailure("Attempt loop always returns or terminates")
    }

    private mutating func dispatch(
        url: URL,
        headers: [String: String],
        bytes: Data,
        timeout: TimeInterval?,
        number: Int
    ) async throws -> RecoveryHTTPResult {
        // Request capture is pre-dispatch; its failure consumes no wire attempt.
        let candidate = RecoveryIdentity(logicalID: logicalID, attemptID: UUID(), wireNumber: number)
        do {
            try Task.checkCancellation()
            try policy.wireObserver?(.request(candidate, url, headers, bytes))
            try Task.checkCancellation()
        } catch {
            throw terminal(
                error,
                outcome: Task.isCancelled ? .cancelled : .captureFailed,
                category: .capture,
                recordAttempt: false
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bytes
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let timeout { request.timeoutInterval = timeout }
        let previous = self
        // Capture can run arbitrary caller code. Keep the failed actual attempt until
        // its proposed successor has passed the final cancellation and limit checks.
        if number > 1, !withinLimits(delay: 0), let failure = history.last {
            throw finish(.limitRefused, failure)
        }
        if Task.isCancelled {
            throw terminal(
                CancellationError(), outcome: .cancelled, category: .cancellation, recordAttempt: false)
        }
        progress = RecoveryProgress()
        wire = nil
        identity = candidate
        let transport: any BufferedRecoveryTransport = RecoveryHTTP(
            identity: candidate,
            observer: policy.wireObserver,
            semantics: { [provider] data in Self.semanticEvidence(data, provider: provider) },
            didStart: { [current = self] in
                current.emit(number == 1 ? .attemptStarted : .retryStarted)
                if number > 1 { current.emit(.attemptStarted) }
            },
            mayStart: { [current = previous] in number == 1 || current.withinLimits(delay: 0) }
        )
        let result = await transport.send(request)
        if !result.dispatched {
            self = previous
            if !Task.isCancelled, result.cause == nil, let failure = history.last {
                throw finish(.limitRefused, failure)
            }
            throw terminal(
                CancellationError(), outcome: .cancelled, category: .cancellation, recordAttempt: false)
        }
        return result
    }

    private mutating func observe(_ response: LLMGatewayResponse) {
        progress.observed.contentBytes = response.content.utf8.count
        progress.observed.reasoningBytes = response.thinking?.utf8.count ?? 0
        progress.observed.completedToolCalls = response.toolCalls.count
        progress.observed.toolFragments = response.toolCalls.count
    }

    private mutating func admit(_ failure: RecoveryFailure, next: Int) async throws {
        if Task.isCancelled {
            throw finish(.cancelled, failure)
        }
        guard failure.eligible else { throw finish(.ineligible, failure) }
        guard next <= policy.maximumAttempts else { throw finish(.exhausted, failure) }
        guard withinLimits(delay: 0) else { throw finish(.limitRefused, failure) }
        guard let admission = policy.admission else { throw finish(.admissionRequired, failure) }
        emit(.admissionPending, category: failure.category)
        do {
            try Task.checkCancellation()
            let decision = try await admissionDecision(admission(failure, next))
            try Task.checkCancellation()
            guard decision == .allow else { throw finish(.admissionRejected, failure) }
            emit(.admissionAllowed, category: failure.category)
            try Task.checkCancellation()
            let delay = backoff(failure)
            guard delay <= policy.delayCeiling, withinLimits(delay: delay) else {
                throw finish(.limitRefused, failure)
            }
            try Task.checkCancellation()
            emit(.delayScheduled, category: failure.category, delay: delay)
            try Task.checkCancellation()
            try await policy.timing.sleep(delay)
            try Task.checkCancellation()
            guard withinLimits(delay: 0) else { throw finish(.limitRefused, failure) }
        } catch let error as RecoveryError {
            throw error
        } catch is RecoveryAdmissionLimit {
            throw finish(.limitRefused, failure)
        } catch {
            throw terminal(error, outcome: .cancelled, category: .cancellation, recordAttempt: false)
        }
    }

    private func admissionDecision(
        _ stream: AsyncStream<RecoveryAdmission>
    ) async throws -> RecoveryAdmission? {
        let now = policy.timing.monotonic()
        let ends = [policy.deadline, policy.budget.flatMap { budget in started.map { $0 + budget } }]
            .compactMap { $0 }
        guard let end = ends.min() else {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let sleep = policy.timing.sleep
        return try await withThrowingTaskGroup(of: RecoveryAdmission?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try await sleep(max(0, end - now))
                throw RecoveryAdmissionLimit()
            }
            defer { group.cancelAll() }
            guard let decision = try await group.next() else { return nil }
            return decision
        }
    }

    private func report() -> CompletionRecoveryReport {
        CompletionRecoveryReport(
            logicalID: logicalID,
            identity: identity,
            progress: progress,
            history: history
        )
    }

    private func withinLimits(delay: TimeInterval) -> Bool {
        let now = policy.timing.monotonic()
        if let budget = policy.budget, let started, now - started + delay >= budget { return false }
        if let deadline = policy.deadline, now + delay >= deadline { return false }
        return true
    }

    private func backoff(_ failure: RecoveryFailure) -> TimeInterval {
        let exponent = min((identity?.wireNumber ?? 1) - 1, 1023)
        let ceiling = min(policy.delayCeiling, policy.baseDelay * pow(2, Double(exponent)))
        let sample = policy.timing.jitter(ceiling)
        let jitter = sample.isFinite ? max(0, min(ceiling, sample)) : ceiling
        switch failure.retryAfter {
        case .seconds(let seconds): return max(jitter, seconds)
        case .date(let date): return max(jitter, max(0, date.timeIntervalSince(policy.timing.wall())))
        case .absent, .invalid: return jitter
        }
    }

    private var currentPhase: RecoveryPhase? {
        guard progress.headersReceived else { return nil }
        return wire?.cause == nil ? .decoding : .receiving
    }

    private func makeFailure(
        category: RecoveryCategory,
        cause: (any Error)?,
        reason: String
    ) -> RecoveryFailure {
        let status = wire?.response?.statusCode
        let permanent = status.map { [400, 401, 403].contains($0) } ?? false
        let eligible =
            !permanent && progress.observed == RecoverySemanticProgress()
            && policy.retryableCategories.contains(category)
            && (category == .http
                ? status.map(policy.retryableStatuses.contains) == true
                : [.transport, .clientTimeout].contains(category))
        return RecoveryFailure(
            logicalID: logicalID,
            identity: identity,
            provider: provider,
            operation: operation,
            category: category,
            status: status,
            retryAfter: retryAfter(),
            progress: progress,
            phase: currentPhase,
            eligible: eligible,
            reason: reason == "requestFailed"
                ? classificationReason(category, permanent: permanent, eligible: eligible) : reason,
            evidence: RecoveryEvidence(
                headers: wire?.headers ?? [:],
                body: wire?.body ?? Data(),
                cause: cause
            )
        )
    }

    private func classificationReason(
        _ category: RecoveryCategory,
        permanent: Bool,
        eligible: Bool
    ) -> String {
        if permanent { return "permanentHTTPStatus" }
        if progress.observed != RecoverySemanticProgress() { return "observedSemanticOutput" }
        switch category {
        case .http: return eligible ? "selectedHTTPStatus" : "unselectedHTTPStatus"
        case .transport: return eligible ? "transientTransport" : "nonTransientTransport"
        case .clientTimeout: return "clientTimeout"
        case .protocolFailure: return "malformedResponse"
        case .providerResponse: return "providerResponse"
        case .cancellation: return "callerCancelled"
        case .capture: return "captureFailed"
        }
    }

    private func retryAfter() -> RecoveryRetryAfter {
        guard let value = wire?.headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else {
            return .absent
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
            let seconds = Double(trimmed), seconds.isFinite
        {
            return .seconds(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        if let date = formatter.date(from: trimmed) { return .date(date) }
        return .invalid
    }

    private mutating func terminal(
        _ cause: any Error,
        outcome: RecoveryTransition,
        category: RecoveryCategory,
        recordAttempt: Bool = true
    ) -> RecoveryError {
        let cancelled = Task.isCancelled || category == .cancellation
        let failure = makeFailure(
            category: cancelled ? .cancellation : category,
            cause: cause,
            reason: cancelled ? "callerCancelled" : outcome.rawValue
        )
        if recordAttempt, identity != nil {
            history.append(failure)
            emit(.attemptFailed, category: failure.category)
        }
        return finish(cancelled ? .cancelled : outcome, failure)
    }

    private func finish(_ outcome: RecoveryTransition, _ failure: RecoveryFailure) -> RecoveryError {
        // All terminal refusals converge here, including limits observed by hooks.
        // A cancellation never replaces the already recorded actual failure.
        let outcome = Task.isCancelled ? RecoveryTransition.cancelled : outcome
        let failure =
            outcome == .cancelled
            ? makeFailure(category: .cancellation, cause: CancellationError(), reason: "callerCancelled")
            : failure
        emit(outcome, category: failure.category)
        policy.reportObserver?(report())
        return RecoveryError(logicalID: logicalID, outcome: outcome, failure: failure, history: history)
    }

    private func emit(
        _ transition: RecoveryTransition,
        category: RecoveryCategory? = nil,
        delay: TimeInterval? = nil
    ) {
        policy.observer?(
            RecoveryEvent(
                logicalID: logicalID,
                transition: transition,
                identity: identity,
                progress: progress,
                category: category,
                status: wire?.response?.statusCode,
                delay: delay,
                provider: provider,
                operation: operation,
                phase: currentPhase,
                acceptance: identity == nil ? .no : .unknown,
                eligible: category.map {
                    makeFailure(category: $0, cause: wire?.cause, reason: "requestFailed").eligible
                },
                reason: category.map {
                    makeFailure(category: $0, cause: wire?.cause, reason: "requestFailed").reason
                }
            )
        )
    }
}

private struct RecoveryAdmissionLimit: Error {}

extension BufferedRecovery {
    private func validatePolicy() throws {
        guard policy.maximumAttempts > 0,
            policy.baseDelay.isFinite, policy.baseDelay >= 0,
            policy.delayCeiling.isFinite, policy.delayCeiling >= 0,
            policy.budget.map({ $0.isFinite && $0 >= 0 }) ?? true,
            policy.deadline.map(\.isFinite) ?? true
        else {
            throw MojenticError.invalidArgument(message: "Invalid buffered recovery limits")
        }
    }

}
