import Foundation

/// Buffered Ollama chat envelope and provider evidence.
struct OllamaChatResponse: Decodable {
    let message: OllamaResponseMessage
    let done: Bool?
    let doneReason: String?
    let evidence: OllamaResponseEvidence

    enum CodingKeys: String, CodingKey {
        case message
        case done
        case doneReason = "done_reason"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(OllamaResponseMessage.self, forKey: .message)
        done = try container.decodeIfPresent(Bool.self, forKey: .done)
        doneReason = try container.decodeIfPresent(String.self, forKey: .doneReason)
        evidence = try OllamaResponseEvidence(from: decoder)
    }

    func toGatewayResponse() -> LLMGatewayResponse {
        let calls = (message.toolCalls ?? []).map { envelope -> LLMToolCall in
            LLMToolCall(
                id: envelope.id,
                name: envelope.function.name,
                arguments: envelope.function.arguments ?? .object([:]),
            )
        }
        return LLMGatewayResponse(
            content: message.content ?? "",
            toolCalls: calls,
            thinking: message.thinking,
            finishReason: mapFinishReason(doneReason, hasToolCalls: !calls.isEmpty),
            usage: evidence.usage,
            providerFinishReason: doneReason,
            providerModel: evidence.model,
            metadata: evidence.metadata,
        )
    }
}

struct OllamaResponseMessage: Decodable {
    let role: String?
    let content: String?
    let thinking: String?
    let toolCalls: [OllamaResponseToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case thinking
        case toolCalls = "tool_calls"
    }
}

struct OllamaResponseToolCall: Decodable {
    let id: String?
    let function: OllamaResponseToolFunction
}

struct OllamaResponseToolFunction: Decodable {
    let name: String
    let arguments: JSONValue?
}

func mapFinishReason(_ raw: String?, hasToolCalls: Bool) -> FinishReason? {
    if hasToolCalls {
        return .toolCalls
    }
    switch raw {
    case "stop", nil: return raw == nil ? nil : .stop
    case "length": return .length
    default: return .other
    }
}
