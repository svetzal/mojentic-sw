import Foundation

/// Translates between Mojentic's universal ``LLMMessage`` and OpenAI's
/// chat-message JSON shape (role, content, tool_calls, tool_call_id, and
/// multimodal content parts).
///
/// Pure functions / value types — no I/O. Lives separately from
/// ``OpenAIGateway`` so message-shape changes can be unit-tested without
/// touching the HTTP boundary.
public enum OpenAIMessageAdapter {
    /// Convert Mojentic messages to OpenAI Chat Completions message JSON.
    public static func adapt(_ messages: [LLMMessage]) -> [JSONValue] {
        messages.map(adaptSingle)
    }

    private static func adaptSingle(_ message: LLMMessage) -> JSONValue {
        switch message.role {
        case .system:
            return [
                "role": "system",
                "content": .string(message.content ?? ""),
            ]
        case .user:
            return adaptUser(message)
        case .assistant:
            return adaptAssistant(message)
        case .tool:
            var dict: [String: JSONValue] = [
                "role": "tool",
                "content": .string(message.content ?? ""),
            ]
            if let id = message.toolCallId {
                dict["tool_call_id"] = .string(id)
            }
            return .object(dict)
        }
    }

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
            parts.append(imagePart(image))
        }
        return [
            "role": "user",
            "content": .array(parts),
        ]
    }

    private static func imagePart(_ image: ImageContent) -> JSONValue {
        let urlString: String
        switch image.source {
        case .url(let url):
            urlString = url.absoluteString
        case .data(let base64, let mimeType):
            urlString = "data:\(mimeType);base64,\(base64)"
        }
        var imageURL: [String: JSONValue] = ["url": .string(urlString)]
        if let detail = image.detail {
            imageURL["detail"] = .string(detail)
        }
        return [
            "type": "image_url",
            "image_url": .object(imageURL),
        ]
    }

    private static func adaptAssistant(_ message: LLMMessage) -> JSONValue {
        var dict: [String: JSONValue] = [
            "role": "assistant",
            "content": .string(message.content ?? ""),
        ]
        if let calls = message.toolCalls, !calls.isEmpty {
            dict["tool_calls"] = .array(calls.map(adaptToolCall))
        }
        return .object(dict)
    }

    private static func adaptToolCall(_ call: LLMToolCall) -> JSONValue {
        let argumentsString: String
        if let data = try? JSONEncoder().encode(call.arguments),
            let string = String(data: data, encoding: .utf8)
        {
            argumentsString = string
        } else {
            argumentsString = "{}"
        }
        return [
            "id": .string(call.id ?? ""),
            "type": "function",
            "function": [
                "name": .string(call.name),
                "arguments": .string(argumentsString),
            ],
        ]
    }
}
