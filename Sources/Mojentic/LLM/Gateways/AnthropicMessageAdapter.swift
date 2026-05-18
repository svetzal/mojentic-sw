import Foundation

/// Result of translating a Mojentic message list into Anthropic's wire format.
public struct AnthropicAdaptedMessages: Sendable, Hashable {
    /// Combined system prompt (Anthropic carries `system` at top-level, not as a role).
    public let system: String?
    /// Anthropic-shaped message array (user / assistant only).
    public let messages: [JSONValue]

    /// Construct an adapted payload.
    public init(system: String?, messages: [JSONValue]) {
        self.system = system
        self.messages = messages
    }
}

/// Translates between Mojentic's universal ``LLMMessage`` and Anthropic's
/// Messages API shape.
///
/// Notable shape differences captured here:
/// - `system` is a top-level request field — system messages are extracted
///   from the input and joined with `"\n\n"`.
/// - User content can be plain text or a content-array carrying text + image
///   blocks (`source: { type: "base64", media_type, data }` or
///   `source: { type: "url", url }`).
/// - Assistant tool calls become `tool_use` content blocks with `id`, `name`,
///   and `input`.
/// - Tool result messages become `role: "user"` messages carrying a
///   `tool_result` block referencing the original `tool_use_id`.
public enum AnthropicMessageAdapter {
    /// Convert Mojentic messages to Anthropic's request shape.
    public static func adapt(_ messages: [LLMMessage]) -> AnthropicAdaptedMessages {
        var systemFragments: [String] = []
        var output: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .system:
                if let content = message.content, !content.isEmpty {
                    systemFragments.append(content)
                }
            case .user:
                output.append(adaptUser(message))
            case .assistant:
                output.append(adaptAssistant(message))
            case .tool:
                output.append(adaptToolResult(message))
            }
        }
        let system = systemFragments.isEmpty ? nil : systemFragments.joined(separator: "\n\n")
        return AnthropicAdaptedMessages(system: system, messages: output)
    }

    // MARK: - Per-role builders

    private static func adaptUser(_ message: LLMMessage) -> JSONValue {
        let images = message.images ?? []
        if images.isEmpty {
            return [
                "role": "user",
                "content": .string(message.content ?? ""),
            ]
        }
        var parts: [JSONValue] = []
        if let text = message.content, !text.isEmpty {
            parts.append(["type": "text", "text": .string(text)])
        }
        for image in images {
            parts.append(imageBlock(for: image))
        }
        return [
            "role": "user",
            "content": .array(parts),
        ]
    }

    private static func imageBlock(for image: ImageContent) -> JSONValue {
        switch image.source {
        case .url(let url):
            return [
                "type": "image",
                "source": [
                    "type": "url",
                    "url": .string(url.absoluteString),
                ],
            ]
        case .data(let base64, let mimeType):
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": .string(mimeType),
                    "data": .string(base64),
                ],
            ]
        }
    }

    private static func adaptAssistant(_ message: LLMMessage) -> JSONValue {
        var blocks: [JSONValue] = []
        if let text = message.content, !text.isEmpty {
            blocks.append(["type": "text", "text": .string(text)])
        }
        if let calls = message.toolCalls {
            for call in calls {
                blocks.append([
                    "type": "tool_use",
                    "id": .string(call.id ?? ""),
                    "name": .string(call.name),
                    "input": call.arguments,
                ])
            }
        }
        let content: JSONValue =
            blocks.isEmpty ? .string(message.content ?? "") : .array(blocks)
        return [
            "role": "assistant",
            "content": content,
        ]
    }

    private static func adaptToolResult(_ message: LLMMessage) -> JSONValue {
        let id = message.toolCallId ?? ""
        let block: JSONValue = [
            "type": "tool_result",
            "tool_use_id": .string(id),
            "content": .string(message.content ?? ""),
        ]
        return [
            "role": "user",
            "content": .array([block]),
        ]
    }
}
