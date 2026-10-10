import Foundation

struct OllamaStreamChunk: Decodable {
    let message: OllamaResponseMessage?
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
        message = try container.decodeIfPresent(OllamaResponseMessage.self, forKey: .message)
        done = try container.decodeIfPresent(Bool.self, forKey: .done)
        doneReason = try container.decodeIfPresent(String.self, forKey: .doneReason)
        evidence = try OllamaResponseEvidence(from: decoder)
    }

    func toEvents() -> [GatewayStreamEvent] {
        guard let message else { return [] }
        var events: [GatewayStreamEvent] = []
        if let content = message.content, !content.isEmpty {
            events.append(.textDelta(content))
        }
        if let thinking = message.thinking, !thinking.isEmpty {
            events.append(.thinkingDelta(thinking))
        }
        if let calls = message.toolCalls {
            for (index, call) in calls.enumerated() {
                events.append(
                    .toolCallRequest(
                        LLMToolCall(
                            id: call.id ?? "call-\(index)",
                            name: call.function.name,
                            arguments: call.function.arguments ?? .object([:]),
                        )
                    )
                )
            }
        }
        return events
    }

    func toFinishReason() -> FinishReason? {
        mapFinishReason(doneReason, hasToolCalls: message?.toolCalls?.isEmpty == false)
    }
}
