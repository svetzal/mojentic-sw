import Foundation

#if anthropic
    extension AnthropicGateway {
        /// Validate only opt-in responses; legacy finish handling remains unchanged.
        static func decodeRecoveryMessage(_ data: Data) throws -> LLMGatewayResponse {
            let root = try JSONDecoder().decode(JSONValue.self, from: data)
            if let error = root.objectValue?["error"] {
                throw MojenticError.providerError(status: nil, detail: error)
            }
            let wire = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
            for block in wire.content {
                switch block.type {
                case "text":
                    guard block.text != nil else { throw invalidRecoveryMessage() }
                case "thinking":
                    guard block.thinking != nil else { throw invalidRecoveryMessage() }
                case "redacted_thinking": break
                case "tool_use":
                    guard
                        let id = block.id,
                        !id.isEmpty,
                        let name = block.name,
                        !name.isEmpty,
                        block.input?.objectValue != nil
                    else { throw invalidRecoveryMessage() }
                default: throw invalidRecoveryMessage()
                }
            }
            if let usage = wire.usage {
                guard
                    (usage.inputTokens ?? 0) >= 0,
                    (usage.outputTokens ?? 0) >= 0,
                    !(usage.inputTokens ?? 0).addingReportingOverflow(usage.outputTokens ?? 0).overflow
                else { throw invalidRecoveryMessage() }
            }
            let response = wire.toGatewayResponse()
            guard wire.stopReason == "end_turn" || wire.stopReason == "tool_use" else {
                throw MojenticError.incompleteCompletion(
                    CompletionEvidence(
                        finishReason: wire.stopReason,
                        usage: response.usage,
                        providerModel: wire.model,
                        metadata: response.metadata,
                    )
                )
            }
            return response
        }

        private static func invalidRecoveryMessage() -> MojenticError {
            .decoding(message: "Malformed Anthropic Messages response")
        }
    }
#endif
