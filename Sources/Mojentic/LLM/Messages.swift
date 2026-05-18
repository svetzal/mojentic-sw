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

/// Image content attached to a user message for multimodal models.
///
/// Phase 2 ships two source shapes:
/// - `url` — a remote `http(s)://` URL the provider fetches itself.
/// - `data` — raw base64-encoded image bytes plus a MIME type, embedded in
///   the request payload (`data:image/png;base64,...` for OpenAI; bare base64
///   in the `images` array for Ollama).
public struct ImageContent: Sendable, Codable, Hashable {
    /// Discriminated payload describing where the image data lives.
    public enum Source: Sendable, Codable, Hashable {
        /// Provider fetches the image from this URL itself.
        case url(URL)
        /// Image is supplied inline as base64-encoded bytes.
        case data(base64: String, mimeType: String)
    }

    /// Where the image data lives.
    public let source: Source

    /// Optional description used by some providers as `alt` text or detail hint.
    public let detail: String?

    /// Create an `ImageContent` carrying a remote URL.
    public init(url: URL, detail: String? = nil) {
        self.source = .url(url)
        self.detail = detail
    }

    /// Create an `ImageContent` carrying inline base64-encoded data.
    public init(base64: String, mimeType: String, detail: String? = nil) {
        self.source = .data(base64: base64, mimeType: mimeType)
        self.detail = detail
    }

    /// Load an image from disk and wrap it as inline base64 content.
    ///
    /// Throws `MojenticError.invalidArgument` if the file cannot be read.
    public static func loadingFromDisk(at path: URL, mimeType: String? = nil) throws -> ImageContent {
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw MojenticError.invalidArgument(
                message: "Could not read image at \(path.path): \(error.localizedDescription)"
            )
        }
        let resolvedMime = mimeType ?? Self.inferMimeType(from: path)
        return ImageContent(base64: data.base64EncodedString(), mimeType: resolvedMime)
    }

    private static func inferMimeType(from path: URL) -> String {
        switch path.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
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

    /// Image attachments.
    ///
    /// Set only on `.user` turns; ignored elsewhere.
    public let images: [ImageContent]?

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
        images: [ImageContent]? = nil,
        toolCalls: [LLMToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.images = images
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

    /// Build a multimodal user message combining text and image attachments.
    public static func user(text: String, images: [ImageContent]) -> LLMMessage {
        LLMMessage(role: .user, content: text, images: images)
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
