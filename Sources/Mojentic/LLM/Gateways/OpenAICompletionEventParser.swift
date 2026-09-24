import Foundation

/// Parses OpenAI-compatible SSE lines into single-turn completion events.
///
/// Success requires a `finish_reason` of `stop` **and** the `data: [DONE]`
/// marker. `[DONE]` with any other finish reason is an incomplete completion
/// carrying the evidence seen so far.
struct OpenAICompletionEventParser: CompletionEventParser {
    private(set) var isTerminal = false
    private var finishReason: String?
    private var usage: Usage?
    private var providerModel: String?
    private var metadata: [String: JSONValue]?

    var partialEvidence: CompletionEvidence? {
        evidence == CompletionEvidence() ? nil : evidence
    }

    private var evidence: CompletionEvidence {
        CompletionEvidence(
            finishReason: finishReason,
            usage: usage,
            providerModel: providerModel,
            metadata: metadata
        )
    }

    mutating func consume(line: String) -> [CompletionStreamEvent] {
        guard !isTerminal, let payload = Self.dataPayload(from: line) else { return [] }
        if payload == "[DONE]" {
            return terminate(
                finishReason == "stop" ? .completed(evidence) : .error(.incompleteCompletion(evidence))
            )
        }
        let data = Data(payload.utf8)
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
            return terminate(.error(.invalidStreamEvent(message: payload)))
        }
        if let error = object["error"] {
            return terminate(.error(.providerError(status: nil, detail: error)))
        }
        guard case .array(let choices)? = object["choices"],
            let chunk = try? JSONDecoder().decode(OpenAIStreamEvidence.self, from: data)
        else {
            return terminate(.error(.invalidStreamEvent(message: payload)))
        }
        absorbEvidence(chunk)
        guard let choice = choices.first else { return [] }
        return consume(choice: choice, payload: payload)
    }

    private mutating func consume(choice: JSONValue, payload: String) -> [CompletionStreamEvent] {
        let delta = choice.objectValue?["delta"]?.objectValue ?? [:]
        if Self.containsToolCalls(delta) {
            return terminate(.error(.unexpectedToolCalls))
        }
        if let reason = choice.objectValue?["finish_reason"]?.stringValue {
            finishReason = reason
        }
        switch delta["content"] {
        case nil, .null?:
            return []
        case .string(let text)?:
            return text.isEmpty ? [] : [.content(text)]
        default:
            return terminate(.error(.invalidStreamEvent(message: payload)))
        }
    }

    private mutating func absorbEvidence(_ chunk: OpenAIStreamEvidence) {
        if let reported = chunk.usage?.toUsage() { usage = reported }
        if let model = chunk.model { providerModel = model }
        if let reported = chunk.envelope.metadata { metadata = reported }
    }

    private mutating func terminate(_ event: CompletionStreamEvent) -> [CompletionStreamEvent] {
        isTerminal = true
        return [event]
    }

    private static func containsToolCalls(_ delta: [String: JSONValue]) -> Bool {
        if case .array(let calls)? = delta["tool_calls"], !calls.isEmpty { return true }
        if case .object? = delta["function_call"] { return true }
        return false
    }

    /// The payload of an SSE `data:` line; `nil` for comments, other fields
    /// and blank lines.
    private static func dataPayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        return String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Evidence fields of one OpenAI stream chunk.
private struct OpenAIStreamEvidence: Decodable {
    let usage: OpenAIUsage?
    let model: String?
    let envelope: OpenAIResponseEnvelope

    enum CodingKeys: String, CodingKey {
        case usage
        case model
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decodeIfPresent(OpenAIUsage.self, forKey: .usage)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        envelope = try OpenAIResponseEnvelope(from: decoder)
    }
}
