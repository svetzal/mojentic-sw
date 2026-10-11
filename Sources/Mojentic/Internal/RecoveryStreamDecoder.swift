import Foundation

/// A synchronized copy of the streaming attempt evidence.
struct RecoveryStreamSnapshot {
    let progress: RecoveryProgress
    let terminal: Bool
    let failure: MojenticError?
    let evidence: CompletionEvidence
}

/// Serializes wire parsing and capture-before-delivery without retaining safe-event payloads.
///
/// URLSession callbacks are serial; the lock also protects the async consumer's snapshot.
final class RecoveryStreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private let provider: String
    private let singleTurn: Bool
    private var buffer = Data()
    private var progress = RecoveryProgress()
    private var pending: [RecoveryGatewayStreamEvent] = []
    private var tools: [LLMToolCall] = []
    private var fragments: [Int: ToolBuilder] = [:]

    private struct ToolBuilder {
        var id: String?
        var name: String?
        var arguments = ""
    }

    private var legacy = OpenAILegacyStreamParser(surfacesReasoning: true)
    private var openAI = OpenAICompletionEventParser()
    private var evidence = CompletionEvidence()
    private var terminal = false
    private var failure: MojenticError?
    let events: AsyncStream<RecoveryGatewayStreamEvent>
    private let continuation: AsyncStream<RecoveryGatewayStreamEvent>.Continuation

    init(provider: String, singleTurn: Bool) {
        self.provider = provider
        self.singleTurn = singleTurn
        let pair = AsyncStream<RecoveryGatewayStreamEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func snapshot() -> RecoveryStreamSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RecoveryStreamSnapshot(
            progress: progress,
            terminal: terminal,
            failure: failure,
            evidence: evidence,
        )
    }

    func finish() {
        continuation.finish()
    }

    func observe(_ data: Data, status: Int?) -> RecoverySemanticProgress {
        lock.lock()
        defer { lock.unlock() }
        progress.headersReceived = status != nil
        progress.rawBytes += data.count
        guard status.map({ (200..<300).contains($0) }) == true else { return progress.observed }
        buffer.append(data)
        while !terminal, let newline = buffer.firstIndex(of: 10) {
            let bytes = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let line = String(data: bytes, encoding: .utf8) else {
                fail(.invalidStreamEvent(message: "Invalid UTF-8"))
                break
            }
            parse(line)
        }
        return progress.observed
    }

    /// Capture has succeeded; only now may semantic values enter the consumer queue.
    func deliver() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for event in pending {
            continuation.yield(event)
        }
        pending.removeAll()
        return terminal
    }

    /// The public relay acknowledges semantic delivery separately from wire observation.
    func delivered(_ event: RecoveryGatewayStreamEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .textDelta(let text): progress.delivered.contentBytes += text.utf8.count
        case .thinkingDelta(let text):
            if !singleTurn {
                progress.delivered.reasoningBytes += text.utf8.count
            }
        case .toolCallRequest:
            progress.delivered.toolFragments += 1
            progress.delivered.completedToolCalls += 1
        default: break
        }
    }

    private func parse(_ line: String) {
        var payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "omlx" || provider == "openai" {
            guard payload.hasPrefix("data:") else { return }
            payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                finishOpenAI(line)
                return
            }
        } else if payload.isEmpty {
            return
        }
        do {
            let data = Data(payload.utf8)
            guard let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
                throw MojenticError.invalidStreamEvent(message: "Expected object")
            }
            if let error = object["error"] {
                throw MojenticError.providerError(status: nil, detail: error)
            }
            if provider == "ollama" {
                try parseOllama(data)
            } else {
                try parseOpenAI(data, object: object, line: line)
            }
        } catch let error as MojenticError { fail(error) } catch {
            fail(.invalidStreamEvent(message: "Malformed provider frame"))
        }
    }

    private func parseOllama(_ data: Data) throws {
        let chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)
        if let calls = chunk.message?.toolCalls {
            for call in calls {
                guard
                    !call.function.name.isEmpty,
                    call.function.arguments.map({ $0.objectValue != nil }) ?? true
                else { throw invalidFrame() }
            }
        }
        // Validate every field before accepting semantic or metric evidence.
        let frame = chunk.evidence
        for count in [
            frame.promptEvalCount, frame.evalCount, frame.totalDuration, frame.loadDuration,
            frame.promptEvalDuration, frame.evalDuration,
        ] {
            if let count, count < 0 {
                throw invalidFrame()
            }
        }
        guard !(frame.promptEvalCount ?? 0).addingReportingOverflow(frame.evalCount ?? 0).overflow else {
            throw invalidFrame()
        }
        let events = chunk.toEvents().map(RecoveryStreamBridge.lift)
        evidence = CompletionEvidence(
            finishReason: chunk.doneReason ?? evidence.finishReason,
            usage: frame.usage ?? evidence.usage,
            providerModel: frame.model ?? evidence.providerModel,
            metadata: frame.metadata.map { (evidence.metadata ?? [:]).merging($0) { _, new in new } }
                ?? evidence.metadata,
        )
        observeSemantic(events)
        let rejected = chunk.done == true && chunk.doneReason != "stop"
        if !rejected {
            for event in events {
                if case .toolCallRequest(let call) = event {
                    tools.append(call)
                } else {
                    pending.append(event)
                }
            }
        }
        pending.append(.progress(progress))
        let numeric = frame.metadata?.filter { $0.value.intValue != nil }
        let metrics = CompletionEvidence(usage: frame.usage, metadata: numeric)
        if metrics != CompletionEvidence() {
            pending.append(.metrics(metrics))
        }
        if singleTurn, !rejected, progress.observed.toolFragments > 0 {
            throw MojenticError.unexpectedToolCalls
        }
        if chunk.done == true {
            terminal = true
            if rejected {
                failure = .incompleteCompletion(evidence)
                return
            }
            pending += tools.map(RecoveryGatewayStreamEvent.toolCallRequest)
        }
    }

    private func parseOpenAI(_ data: Data, object: [String: JSONValue], line: String) throws {
        // Typed decoding validates metric types before they can be exposed.
        let frame = try JSONDecoder().decode(OpenAIStreamEvidence.self, from: data)
        let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
        for count in [frame.usage?.promptTokens, frame.usage?.completionTokens, frame.usage?.totalTokens] {
            if let count, count < 0 {
                throw invalidFrame()
            }
        }
        guard case .array(let choices)? = object["choices"] else {
            throw MojenticError.invalidStreamEvent(message: "Missing choices")
        }
        if provider == "openai" {
            try validateOpenAIChoices(choices, usage: frame.usage)
        }
        for choice in choices {
            guard let fields = choice.objectValue else { throw invalidFrame() }
            if let reason = fields["finish_reason"], reason != .null, reason.stringValue == nil {
                throw invalidFrame()
            }
            if let delta = fields["delta"], delta != .null {
                guard let values = delta.objectValue else { throw invalidFrame() }
                for key in ["content", "reasoning_content"] {
                    if let value = values[key], value != .null, value.stringValue == nil {
                        throw invalidFrame()
                    }
                }
                if let calls = values["tool_calls"], calls != .null {
                    guard case .array(let fragments) = calls else { throw invalidFrame() }
                    // Validate the legacy accumulator's typed wire shape as well.
                    _ = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                    progress.observed.toolFragments += fragments.count
                    if singleTurn, !fragments.isEmpty {
                        observeRejectedOpenAITools(values)
                        throw MojenticError.unexpectedToolCalls
                    }
                }
            }
        }
        for choice in chunk.choices {
            for fragment in choice.delta.toolCalls ?? [] {
                var builder = fragments[fragment.index] ?? ToolBuilder()
                if let id = fragment.id {
                    builder.id = id
                }
                if let name = fragment.function?.name {
                    builder.name = name
                }
                builder.arguments += fragment.function?.arguments ?? ""
                fragments[fragment.index] = builder
            }
        }
        let reason = choices.first?.objectValue?["finish_reason"]?.stringValue
        evidence = CompletionEvidence(
            finishReason: reason ?? evidence.finishReason,
            usage: frame.usage?.toUsage() ?? evidence.usage,
            providerModel: frame.model ?? evidence.providerModel,
            metadata: frame.envelope.metadata ?? evidence.metadata,
        )
        let events = legacy.consume(line: line).map(RecoveryStreamBridge.lift)
        observeSemantic(events)
        enqueueOpenAIEvents(events, usage: frame.usage)
        // The no-tool evidence parser supplies only provider-reported fields.
        let reported = openAI.consume(line: line)
        if singleTurn, let partial = openAI.partialEvidence {
            evidence = partial
        }
        if singleTurn, case .error(let error)? = reported.last {
            throw error
        }
    }

    /// Rejected tools cannot erase other validated semantic evidence in the same frame.
    private func observeRejectedOpenAITools(_ delta: [String: JSONValue]) {
        guard provider == "openai" else { return }
        progress.observed.contentBytes += delta["content"]?.stringValue?.utf8.count ?? 0
        progress.observed.reasoningBytes += delta["reasoning_content"]?.stringValue?.utf8.count ?? 0
    }

    private func enqueueOpenAIEvents(_ events: [RecoveryGatewayStreamEvent], usage: OpenAIUsage?) {
        pending += events.filter { event in
            if provider == "openai", case .thinkingDelta = event {
                return false
            }
            return true
        }
        if provider == "openai", let usage = usage?.toUsage() {
            pending.append(.metrics(CompletionEvidence(usage: usage)))
        }
    }

    private func validateOpenAIChoices(_ choices: [JSONValue], usage: OpenAIUsage?) throws {
        guard choices.count == 1 || (choices.isEmpty && usage != nil) else { throw invalidFrame() }
    }

    private func finishOpenAI(_ line: String) {
        let final = legacy.finish()
        let reason = final.compactMap { event -> FinishReason? in
            if case .done(let reason, _) = event {
                return reason
            }
            return nil
        }.last
        terminal = true
        if reason != .stop, reason != .toolCalls {
            failure = .incompleteCompletion(evidence)
            return
        }
        if singleTurn {
            let result = openAI.consume(line: line)
            if case .error(let error)? = result.last {
                failure = error
                return
            }
            if case .completed(let value)? = result.last {
                evidence = value
            }
        }
        var calls: [LLMToolCall] = []
        for index in fragments.keys.sorted() {
            guard
                let builder = fragments[index], let name = builder.name, !name.isEmpty,
                let arguments = try? JSONDecoder().decode(
                    JSONValue.self,
                    from: Data((builder.arguments.isEmpty ? "{}" : builder.arguments).utf8),
                ),
                arguments.objectValue != nil
            else {
                fail(invalidFrame())
                return
            }
            calls.append(LLMToolCall(id: builder.id, name: name, arguments: arguments))
        }
        progress.observed.completedToolCalls = calls.count
        pending += calls.map(RecoveryGatewayStreamEvent.toolCallRequest)
    }

    private func observeSemantic(_ events: [RecoveryGatewayStreamEvent]) {
        for event in events {
            switch event {
            case .textDelta(let text): progress.observed.contentBytes += text.utf8.count
            case .thinkingDelta(let text): progress.observed.reasoningBytes += text.utf8.count
            case .toolCallRequest:
                progress.observed.toolFragments += 1
                progress.observed.completedToolCalls += 1
            default: break
            }
        }
    }

    private func invalidFrame() -> MojenticError {
        .invalidStreamEvent(message: "Malformed provider frame")
    }

    private func fail(_ error: MojenticError) {
        terminal = true
        failure = error
    }
}
