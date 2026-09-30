import Foundation

/// Parses Ollama NDJSON lines into single-turn completion events.
///
/// Success requires a final frame with `done: true` and a `done_reason` of
/// `stop`. Any other `done_reason` is an incomplete completion carrying the
/// evidence reported across the frames. A final frame without `done_reason` (servers too
/// old to report one) is also an incomplete completion.
struct OllamaCompletionEventParser: CompletionEventParser {
    private(set) var isTerminal = false
    private var providerModel: String?
    private var promptTokens: Int?
    private var completionTokens: Int?

    private var usage: Usage? {
        guard promptTokens != nil || completionTokens != nil else { return nil }
        return Usage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: (promptTokens ?? 0) + (completionTokens ?? 0))
    }
    private var metadata: [String: JSONValue]?
    private var finishReason: String?

    private var evidence: CompletionEvidence {
        CompletionEvidence(
            finishReason: finishReason, usage: usage, providerModel: providerModel, metadata: metadata)
    }

    var partialEvidence: CompletionEvidence? {
        evidence == CompletionEvidence() ? nil : evidence
    }

    mutating func consume(line: String) -> [CompletionStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isTerminal, !trimmed.isEmpty else { return [] }
        let data = Data(trimmed.utf8)
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue,
            let frame = try? JSONDecoder().decode(OllamaResponseEvidence.self, from: data)
        else {
            return terminate(.error(.invalidStreamEvent(message: trimmed)))
        }
        if let error = object["error"] {
            return terminate(.error(.providerError(status: nil, detail: error)))
        }
        guard
            Self.validOptional(
                object["done"],
                kind: {
                    if case .bool = $0 { return true }
                    return false
                }),
            Self.validOptional(object["done_reason"], kind: { $0.stringValue != nil }),
            Self.validOptional(object["message"], kind: { $0.objectValue != nil })
        else { return terminate(.error(.invalidStreamEvent(message: trimmed))) }
        if let model = frame.model { providerModel = model }
        if let reported = frame.promptEvalCount { promptTokens = reported }
        if let reported = frame.evalCount { completionTokens = reported }
        if let reported = frame.metadata { metadata = (metadata ?? [:]).merging(reported) { _, new in new } }
        if let reason = object["done_reason"]?.stringValue { finishReason = reason }
        let message = object["message"]?.objectValue ?? [:]
        guard
            Self.validOptional(
                message["tool_calls"],
                kind: {
                    if case .array = $0 { return true }
                    return false
                })
        else { return terminate(.error(.invalidStreamEvent(message: trimmed))) }
        if case .array(let calls)? = message["tool_calls"], !calls.isEmpty {
            return terminate(.error(.unexpectedToolCalls))
        }
        var events: [CompletionStreamEvent] = []
        switch message["content"] {
        case nil, .null?:
            break
        case .string(let text)?:
            if !text.isEmpty { events.append(.content(text)) }
        default:
            return terminate(.error(.invalidStreamEvent(message: trimmed)))
        }
        guard case .bool(true)? = object["done"] else { return events }
        let doneReason = object["done_reason"]?.stringValue
        finishReason = doneReason
        return events
            + terminate(doneReason == "stop" ? .completed(evidence) : .error(.incompleteCompletion(evidence)))
    }

    private static func validOptional(_ value: JSONValue?, kind: (JSONValue) -> Bool) -> Bool {
        guard let value, value != .null else { return true }
        return kind(value)
    }

    private mutating func terminate(_ event: CompletionStreamEvent) -> [CompletionStreamEvent] {
        isTerminal = true
        return [event]
    }
}
