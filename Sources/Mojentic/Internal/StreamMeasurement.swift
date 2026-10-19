import Foundation

/// Per-completion wire observations shared by sequential attempts and HTTP callbacks.
///
/// The lock protects the monotonic origin and first observation across cancellation.
final class StreamMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    /// Captured per completion so inherited tasks share a caller's test clock.
    @TaskLocal static var now: @Sendable () -> ContinuousClock.Instant = { .now }

    private let clock = StreamMeasurement.now
    private var started: ContinuousClock.Instant?
    private var first: (Double, String)?
    private var buffer = Data()
    private var ended = false
    private var reported = CompletionEvidence()

    func start() {
        lock.lock()
        defer { lock.unlock() }
        if started == nil { started = clock() }
    }

    func observe(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(bytes: buffer[..<newline], encoding: .utf8)
            buffer.removeSubrange(...newline)
            if let line { observeLine(line) }
        }
    }

    func observe(line: String) { observe(Data((line + "\n").utf8)) }

    func beginAttempt() {
        lock.lock()
        defer { lock.unlock() }
        reported = CompletionEvidence()
        buffer.removeAll()
        ended = false
    }

    func retain(_ evidence: CompletionEvidence) {
        lock.lock()
        defer { lock.unlock() }
        var metadata = reported.metadata ?? [:]
        metadata.merge(evidence.metadata ?? [:]) { _, parsed in parsed }
        var retained = CompletionEvidence(
            finishReason: evidence.finishReason,
            usage: evidence.usage,
            providerModel: evidence.providerModel,
            metadata: metadata.isEmpty ? nil : metadata)
        retained.identity = evidence.identity
        retained.frameIndex = evidence.frameIndex
        reported = retained
    }

    func finishAttempt() {
        lock.lock()
        defer { lock.unlock() }
        if let line = String(bytes: buffer, encoding: .utf8), !line.isEmpty { observeLine(line) }
        buffer.removeAll()
    }

    func evidence(_ supplied: CompletionEvidence? = nil) -> CompletionEvidence {
        lock.lock()
        defer { lock.unlock() }
        let reported = supplied ?? self.reported
        guard let started else { return reported }
        var metadata = self.reported.metadata ?? [:]
        metadata.merge(reported.metadata ?? [:]) { _, supplied in supplied }
        metadata["request_duration_ms"] = .number(milliseconds(started.duration(to: clock())))
        if let first {
            metadata["time_to_first_token_ms"] = .number(first.0)
            metadata["first_token_kind"] = .string(first.1)
        }
        var result = CompletionEvidence(
            finishReason: reported.finishReason ?? self.reported.finishReason,
            usage: reported.usage ?? self.reported.usage,
            providerModel: reported.providerModel ?? self.reported.providerModel,
            metadata: metadata)
        result.identity = reported.identity
        result.frameIndex = reported.frameIndex
        return result
    }

    private var dispatched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started != nil
    }

    func failure(_ error: any Error, reported: CompletionEvidence? = nil) -> any Error {
        guard dispatched else { return error }
        if var recovery = error as? RecoveryError {
            recovery.evidence = evidence(reported ?? recovery.evidence ?? CompletionEvidence())
            return recovery
        }
        return MojenticError.streamFailure(
            StreamFailure(cause: error, evidence: evidence(reported ?? CompletionEvidence())))
    }

    func error(_ error: MojenticError) -> MojenticError {
        guard dispatched else { return error }
        let reported: CompletionEvidence?
        switch error {
        case .incompleteCompletion(let evidence), .incompleteStream(.some(let evidence)):
            reported = evidence
        default: reported = nil
        }
        return .streamFailure(
            StreamFailure(cause: error, evidence: evidence(reported ?? CompletionEvidence())))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private func observeLine(_ line: String) {
        guard !ended, let started else { return }
        var payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("data:") {
            payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if payload == "[DONE]" {
            ended = true
            return
        }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
            let object = root.objectValue, object["model"] != .string("keepalive")
        else { return }
        defer {
            if object["done"] == .bool(true) || object["type"] == .string("message_stop")
                || object["error"] != nil
            {
                ended = true
            }
        }
        let messageEnvelope =
            object["type"] == .string("message_start") ? object["message"]?.objectValue : nil
        var metadata = reported.metadata ?? [:]
        for key in [
            "id", "created", "created_at", "total_duration", "load_duration",
            "prompt_eval_duration", "eval_duration", "time_to_first_token", "generation_duration",
            "total_time",
        ] {
            if let value = object[key] ?? messageEnvelope?[key] { metadata[key] = value }
        }
        let usageObject = object["usage"]?.objectValue ?? [:]
        for key in ["time_to_first_token", "prompt_eval_duration", "generation_duration", "total_time"] {
            if let value = usageObject[key] { metadata[key] = value }
        }
        let choices: [JSONValue]
        if case .array(let values) = object["choices"] { choices = values } else { choices = [] }
        let finishReason =
            object["done_reason"]?.stringValue
            ?? choices.first?.objectValue?["finish_reason"]?.stringValue
            ?? object["delta"]?.objectValue?["stop_reason"]?.stringValue
            ?? reported.finishReason
        let usage: Usage?
        if let data = try? JSONEncoder().encode(object["usage"]),
            let value = try? JSONDecoder().decode(OpenAIUsage.self, from: data)
        {
            usage = value.toUsage()
        } else {
            usage = reported.usage
        }
        reported = CompletionEvidence(
            finishReason: finishReason,
            usage: usage,
            providerModel: object["model"]?.stringValue ?? messageEnvelope?["model"]?.stringValue
                ?? reported.providerModel,
            metadata: metadata.isEmpty ? nil : metadata)
        guard first == nil else { return }
        // Anthropic starts tools with a placeholder input object, including for
        // zero-argument calls. Only a nonempty input_json_delta starts timing.
        if object["type"]?.stringValue == "content_block_start",
            object["content_block"]?.objectValue?["type"]?.stringValue == "tool_use"
        {
            return
        }
        let delta =
            object["message"]?.objectValue
            ?? choices.first?.objectValue?["delta"]?.objectValue
            ?? object["delta"]?.objectValue
            ?? object["content_block"]?.objectValue ?? [:]
        let kind: String?
        if present(delta["thinking"]) || present(delta["reasoning_content"]) {
            kind = "thinking"
        } else if present(delta["content"]) || present(delta["text"]) {
            kind = "content"
        } else if present(delta["partial_json"]) || arguments(delta) {
            kind = "tool_call"
        } else {
            kind = nil
        }
        if let kind { first = (milliseconds(started.duration(to: clock())), kind) }
    }

    private func present(_ value: JSONValue?) -> Bool {
        value?.stringValue.map { !$0.isEmpty } ?? false
    }

    private func arguments(_ delta: [String: JSONValue]) -> Bool {
        if present(delta["function_call"]?.objectValue?["arguments"]) { return true }
        guard case .array(let calls) = delta["tool_calls"] else { return false }
        return calls.contains { call in
            let arguments = call.objectValue?["function"]?.objectValue?["arguments"]
            return present(arguments) || arguments?.objectValue != nil
        }
    }
}
