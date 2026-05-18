import Foundation

/// The role of a message in an LLM conversation.
public enum MessageRole: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// A single tool-call request emitted by an assistant turn, or attached to a
/// matching tool turn for traceability.
public struct LLMToolCall: Sendable, Codable, Hashable {
    /// Provider-supplied identifier when available; synthesised by the broker
    /// when the provider does not assign one.
    public let id: String?

    /// The tool name the model is asking to invoke.
    public let name: String

    /// JSON-shaped arguments supplied by the model.
    public let arguments: JSONValue

    /// Create a tool-call record.
    public init(id: String? = nil, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// A single message in an LLM conversation.
///
/// `LLMMessage` is a value type. Construct messages through the static
/// composer factories (`.system`, `.user`, `.assistant`, `.tool`) — direct
/// initialisation is available but the composers express intent better at
/// call sites.
public struct LLMMessage: Sendable, Codable, Hashable {
    /// The conversational role this message belongs to.
    public let role: MessageRole

    /// Text content of the message.
    ///
    /// Optional because assistant turns may carry only tool calls, and tool
    /// turns may carry only a serialised result.
    public let content: String?

    /// Tool-call requests (assistant turns) or the request a tool result
    /// satisfies (tool turns).
    public let toolCalls: [LLMToolCall]?

    /// Identifier of the tool call this message answers.
    ///
    /// Set only on `.tool` turns.
    public let toolCallId: String?

    /// Construct an `LLMMessage` directly.
    ///
    /// Prefer the composer factories at call sites for readability.
    public init(
        role: MessageRole,
        content: String? = nil,
        toolCalls: [LLMToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    // MARK: - Composer factories

    /// Build a system message from a plain string.
    public static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: text)
    }

    /// Build a user message from a plain string.
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: text)
    }

    /// Build an assistant message with optional content and optional tool calls.
    public static func assistant(_ text: String? = nil, toolCalls: [LLMToolCall]? = nil) -> LLMMessage {
        LLMMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }

    /// Build a tool-result message carrying a serialised response.
    public static func tool(callId: String, content: String) -> LLMMessage {
        LLMMessage(role: .tool, content: content, toolCallId: callId)
    }
}
