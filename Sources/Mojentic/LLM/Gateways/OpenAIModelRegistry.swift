import Foundation

/// Classification of OpenAI model families.
public enum OpenAIModelType: String, Sendable, Hashable {
    /// Reasoning models (o1, o3, o4, gpt-5 series).
    case reasoning
    /// Standard chat models (gpt-4, gpt-4o, gpt-4.1 series).
    case chat
    /// Embedding models (text-embedding-3-* etc.).
    case embedding
}

/// Capability flags + token-parameter naming for an OpenAI model.
public struct OpenAIModelCapabilities: Sendable, Hashable {
    /// Coarse model family.
    public let modelType: OpenAIModelType
    /// Whether the model accepts the `tools` field.
    public let supportsTools: Bool
    /// Whether the model can be streamed.
    public let supportsStreaming: Bool
    /// Whether the model accepts image content.
    public let supportsVision: Bool
    /// Whether the model accepts `response_format: { type: "json_schema" }`.
    public let supportsJSONSchema: Bool
    /// Whether the model accepts the `temperature` parameter at non-default values.
    ///
    /// Reasoning models typically pin temperature at 1.0.
    public let supportsTemperatureControl: Bool
    /// Whether the model accepts the `reasoning_effort` parameter.
    public let supportsReasoningEffort: Bool

    /// Construct a capability record.
    public init(
        modelType: OpenAIModelType,
        supportsTools: Bool = true,
        supportsStreaming: Bool = true,
        supportsVision: Bool = false,
        supportsJSONSchema: Bool = true,
        supportsTemperatureControl: Bool = true,
        supportsReasoningEffort: Bool = false
    ) {
        self.modelType = modelType
        self.supportsTools = supportsTools
        self.supportsStreaming = supportsStreaming
        self.supportsVision = supportsVision
        self.supportsJSONSchema = supportsJSONSchema
        self.supportsTemperatureControl = supportsTemperatureControl
        self.supportsReasoningEffort = supportsReasoningEffort
    }

    /// JSON request key the model uses for its output-token limit.
    public var tokenLimitParameter: String {
        modelType == .reasoning ? "max_completion_tokens" : "max_tokens"
    }
}

/// Tiny registry of well-known OpenAI model IDs.
///
/// Used by ``OpenAIGateway`` to decide per-model request shaping (token
/// parameter name, temperature handling, reasoning effort routing). Lookups
/// fall back to coarse pattern matching when an explicit entry isn't
/// registered.
public struct OpenAIModelRegistry: Sendable {
    private let entries: [String: OpenAIModelCapabilities]
    private let patterns: [(String, OpenAIModelType)]

    /// Shared registry initialised with the default model set.
    public static let shared = OpenAIModelRegistry()

    /// Construct a registry pre-populated with the default model set.
    public init() {
        var registry: [String: OpenAIModelCapabilities] = [:]

        let reasoning = ["o1", "o1-mini", "o3", "o3-mini", "o4-mini", "gpt-5", "gpt-5-mini", "gpt-5-nano"]
        for name in reasoning {
            registry[name] = OpenAIModelCapabilities(
                modelType: .reasoning,
                supportsTools: true,
                supportsStreaming: true,
                supportsVision: false,
                supportsJSONSchema: true,
                supportsTemperatureControl: false,
                supportsReasoningEffort: true
            )
        }

        let chatVision = [
            "gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano",
        ]
        for name in chatVision {
            registry[name] = OpenAIModelCapabilities(
                modelType: .chat,
                supportsTools: true,
                supportsStreaming: true,
                supportsVision: true,
                supportsJSONSchema: true,
                supportsTemperatureControl: true,
                supportsReasoningEffort: false
            )
        }

        let chatBasic = ["gpt-4", "gpt-4-turbo", "gpt-3.5-turbo"]
        for name in chatBasic {
            registry[name] = OpenAIModelCapabilities(
                modelType: .chat,
                supportsTools: true,
                supportsStreaming: true,
                supportsVision: false,
                // Older chat models pre-date json_schema; fall back to json_object.
                supportsJSONSchema: false,
                supportsTemperatureControl: true,
                supportsReasoningEffort: false
            )
        }

        let embeddings = ["text-embedding-3-large", "text-embedding-3-small", "text-embedding-ada-002"]
        for name in embeddings {
            registry[name] = OpenAIModelCapabilities(
                modelType: .embedding,
                supportsTools: false,
                supportsStreaming: false,
                supportsVision: false,
                supportsJSONSchema: false,
                supportsTemperatureControl: false,
                supportsReasoningEffort: false
            )
        }

        self.entries = registry
        self.patterns = [
            ("gpt-5", .reasoning),
            ("o4", .reasoning),
            ("o3", .reasoning),
            ("o1", .reasoning),
            ("gpt-4o", .chat),
            ("gpt-4.1", .chat),
            ("gpt-4", .chat),
            ("gpt-3.5", .chat),
            ("text-embedding", .embedding),
        ]
    }

    /// Look up capabilities for `model`, falling back to a sensible default
    /// based on coarse pattern matching when the model is not explicitly
    /// registered.
    public func capabilities(for model: String) -> OpenAIModelCapabilities {
        if let direct = entries[model] { return direct }
        let lowered = model.lowercased()
        for (pattern, modelType) in patterns where lowered.contains(pattern) {
            return defaultCapabilities(for: modelType)
        }
        return defaultCapabilities(for: .chat)
    }

    private func defaultCapabilities(for modelType: OpenAIModelType) -> OpenAIModelCapabilities {
        switch modelType {
        case .reasoning:
            return OpenAIModelCapabilities(
                modelType: .reasoning,
                supportsTools: true,
                supportsStreaming: true,
                supportsVision: false,
                supportsJSONSchema: true,
                supportsTemperatureControl: false,
                supportsReasoningEffort: true
            )
        case .chat:
            return OpenAIModelCapabilities(
                modelType: .chat,
                supportsTools: true,
                supportsStreaming: true,
                supportsVision: false,
                supportsJSONSchema: true,
                supportsTemperatureControl: true,
                supportsReasoningEffort: false
            )
        case .embedding:
            return OpenAIModelCapabilities(
                modelType: .embedding,
                supportsTools: false,
                supportsStreaming: false,
                supportsVision: false,
                supportsJSONSchema: false,
                supportsTemperatureControl: false,
                supportsReasoningEffort: false
            )
        }
    }
}
