import Foundation

/// Parses Ollama NDJSON lines into single-turn completion events.
///
/// Success requires a final frame with `done: true` and a `done_reason` of
/// `stop`. Any other `done_reason` is an incomplete completion carrying the
/// final frame's evidence. A final frame without `done_reason` (servers too
/// old to report one) is also an incomplete completion.
struct OllamaCompletionEventParser: CompletionEventParser {
    private(set) var isTerminal = false
    private var providerModel: String?

    var partialEvidence: CompletionEvidence? {
        providerModel.map { CompletionEvidence(providerModel: $0) }
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
        if let model = frame.model { providerModel = model }
        let message = object["message"]?.objectValue ?? [:]
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
        let evidence = CompletionEvidence(
            finishReason: doneReason,
            usage: frame.usage,
            providerModel: frame.model,
            metadata: frame.metadata
        )
        return events
            + terminate(doneReason == "stop" ? .completed(evidence) : .error(.incompleteCompletion(evidence)))
    }

    private mutating func terminate(_ event: CompletionStreamEvent) -> [CompletionStreamEvent] {
        isTerminal = true
        return [event]
    }
}
