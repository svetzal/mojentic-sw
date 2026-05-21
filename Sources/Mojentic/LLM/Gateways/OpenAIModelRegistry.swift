import Foundation
import Logging

/// Classification of OpenAI model families.
public enum OpenAIModelType: String, Sendable, Hashable {
    /// Reasoning models (o1, o3, o4, gpt-5 series) — use `max_completion_tokens`.
    case reasoning
    /// Standard chat models (gpt-4, gpt-4o, gpt-4.1 series) — use `max_tokens`.
    case chat
    /// Text embedding models (text-embedding-3-* etc.).
    case embedding
    /// Content moderation models (text-moderation-*).
    case moderation
}

/// Capability flags, token limits, and API support for an OpenAI model.
///
/// Mirrors the `ModelCapabilities` interface in the other Mojentic ports
/// (`mojentic-ts`, `mojentic-py`, `mojentic-ex`, `mojentic-ru`) so callers
/// can make the same per-model request-shaping decisions in every language.
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
    /// Maximum input + output context window in tokens, when known.
    public let maxContextTokens: Int?
    /// Maximum number of output tokens the model can generate, when known.
    public let maxOutputTokens: Int?
    /// Allowed `temperature` values.
    ///
    /// - `nil` means every temperature is supported (no restriction).
    /// - An empty array means the `temperature` parameter is not accepted at all.
    /// - A populated array means only those exact values are accepted
    ///   (reasoning models typically pin temperature at `1.0`).
    public let supportedTemperatures: [Double]?
    /// Whether the model is served by the Chat Completions API (`/chat/completions`).
    public let supportsChatApi: Bool
    /// Whether the model is served by the legacy Completions API (`/completions`).
    public let supportsCompletionsApi: Bool
    /// Whether the model is served by the Responses API (`/responses`).
    public let supportsResponsesApi: Bool
    /// Whether the model accepts the `reasoning_effort` parameter.
    public let supportsReasoningEffort: Bool

    /// Construct a capability record.
    ///
    /// - Parameters:
    ///   - modelType: Coarse model family.
    ///   - supportsTools: Whether the model accepts the `tools` field.
    ///   - supportsStreaming: Whether the model can be streamed.
    ///   - supportsVision: Whether the model accepts image content.
    ///   - supportsJSONSchema: Whether the model accepts `json_schema` response format.
    ///   - maxContextTokens: Maximum context window in tokens, when known.
    ///   - maxOutputTokens: Maximum output tokens, when known.
    ///   - supportedTemperatures: Allowed temperature values; `nil` = unrestricted,
    ///     empty = parameter not accepted, populated = only those values.
    ///   - supportsChatApi: Whether the model is served by Chat Completions.
    ///   - supportsCompletionsApi: Whether the model is served by legacy Completions.
    ///   - supportsResponsesApi: Whether the model is served by the Responses API.
    ///   - supportsReasoningEffort: Whether the model accepts `reasoning_effort`.
    public init(
        modelType: OpenAIModelType,
        supportsTools: Bool = true,
        supportsStreaming: Bool = true,
        supportsVision: Bool = false,
        supportsJSONSchema: Bool = true,
        maxContextTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportedTemperatures: [Double]? = nil,
        supportsChatApi: Bool = true,
        supportsCompletionsApi: Bool = false,
        supportsResponsesApi: Bool = false,
        supportsReasoningEffort: Bool = false
    ) {
        self.modelType = modelType
        self.supportsTools = supportsTools
        self.supportsStreaming = supportsStreaming
        self.supportsVision = supportsVision
        self.supportsJSONSchema = supportsJSONSchema
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
        self.supportedTemperatures = supportedTemperatures
        self.supportsChatApi = supportsChatApi
        self.supportsCompletionsApi = supportsCompletionsApi
        self.supportsResponsesApi = supportsResponsesApi
        self.supportsReasoningEffort = supportsReasoningEffort
    }

    /// JSON request key the model uses for its output-token limit.
    public var tokenLimitParameter: String {
        modelType == .reasoning ? "max_completion_tokens" : "max_tokens"
    }

    /// Whether the model accepts the `temperature` parameter at non-default
    /// values.
    ///
    /// `true` when temperatures are unrestricted; `false` when the parameter
    /// is disallowed entirely or pinned to a single fixed value (e.g. the
    /// reasoning models that only accept `1.0`).
    public var supportsTemperatureControl: Bool {
        guard let supportedTemperatures else { return true }
        return supportedTemperatures.count > 1
    }

    /// Check whether the model accepts a specific `temperature` value.
    ///
    /// - Parameter temperature: The temperature value to test.
    /// - Returns: `true` when the value is permitted for this model.
    public func supportsTemperature(_ temperature: Double) -> Bool {
        guard let supportedTemperatures else { return true }
        if supportedTemperatures.isEmpty { return false }
        return supportedTemperatures.contains(temperature)
    }
}

/// Registry of well-known OpenAI model IDs and their capabilities.
///
/// Used by ``OpenAIGateway`` to decide per-model request shaping (token
/// parameter name, temperature handling, reasoning effort routing, API
/// endpoint selection). Lookups fall back to coarse substring pattern
/// matching when an explicit entry isn't registered — pattern matching
/// warns and infers a sensible default; it never throws.
public struct OpenAIModelRegistry: Sendable {
    private let entries: [String: OpenAIModelCapabilities]
    private let patterns: [(String, OpenAIModelType)]
    private let logger = Logger(label: "mojentic.gateway.openai.registry")

    /// Shared registry initialised with the default model set.
    public static let shared = OpenAIModelRegistry()

    /// Construct a registry pre-populated with the default model set.
    public init() {
        var registry: [String: OpenAIModelCapabilities] = [:]

        Self.registerReasoningModels(into: &registry)
        Self.registerGpt4AndNewerChatModels(into: &registry)
        Self.registerGpt35Models(into: &registry)
        Self.registerEmbeddingModels(into: &registry)
        Self.registerLegacyAndCodexModels(into: &registry)
        Self.registerGpt54PlusModels(into: &registry)

        self.entries = registry
        // Order matters: longer / more-specific gpt-5.x prefixes are checked
        // before the bare `gpt-5` prefix so a future snapshot still resolves
        // to a reasoning profile.
        self.patterns = [
            ("o1", .reasoning),
            ("o3", .reasoning),
            ("o4", .reasoning),
            ("gpt-5.5", .reasoning),
            ("gpt-5.4", .reasoning),
            ("gpt-5.3", .reasoning),
            ("gpt-5.2", .reasoning),
            ("gpt-5.1", .reasoning),
            ("gpt-5", .reasoning),
            ("gpt-4", .chat),
            ("gpt-4.1", .chat),
            ("gpt-3.5", .chat),
            ("chatgpt", .chat),
            ("text-embedding", .embedding),
            ("text-moderation", .moderation),
        ]
    }

    // MARK: - Catalog construction

    /// Reasoning Models (o1, o3, o4, gpt-5 / 5.1 / 5.2 series).
    ///
    /// Per the cross-port API audit, all reasoning models support tools and
    /// streaming (except `gpt-5-mini` / `o4-mini`, which have incomplete tool
    /// support), pin temperature at `1.0`, and never accept image input.
    private static func registerReasoningModels(
        into registry: inout [String: OpenAIModelCapabilities]
    ) {
        let reasoningModels = [
            "o1", "o1-2024-12-17",
            "o3", "o3-2025-04-16",
            "o3-deep-research", "o3-deep-research-2025-06-26",
            "o3-mini", "o3-mini-2025-01-31",
            "o3-pro", "o3-pro-2025-06-10",
            "o4-mini", "o4-mini-2025-04-16",
            "o4-mini-deep-research", "o4-mini-deep-research-2025-06-26",
            "gpt-5", "gpt-5-2025-08-07",
            "gpt-5-codex",
            "gpt-5-mini", "gpt-5-mini-2025-08-07",
            "gpt-5-nano", "gpt-5-nano-2025-08-07",
            "gpt-5-pro", "gpt-5-pro-2025-10-06",
            "gpt-5.1", "gpt-5.1-2025-11-13", "gpt-5.1-chat-latest",
            "gpt-5.2", "gpt-5.2-2025-12-11", "gpt-5.2-chat-latest",
        ]

        for model in reasoningModels {
            let isDeepResearch = model.contains("deep-research")
            let isGpt5 = model.contains("gpt-5")
            let isMiniOrNano = model.contains("mini") || model.contains("nano")

            // All reasoning models support tools except gpt-5-mini / o4-mini.
            let supportsTools = !(model == "gpt-5-mini" || model == "o4-mini")

            let contextTokens: Int
            let outputTokens: Int
            if isGpt5 {
                contextTokens = isMiniOrNano ? 200_000 : 300_000
                outputTokens = isMiniOrNano ? 32_768 : 50_000
            } else if isDeepResearch {
                contextTokens = 200_000
                outputTokens = 100_000
            } else {
                contextTokens = 128_000
                outputTokens = 32_768
            }

            // Reasoning models pin temperature at 1.0.
            let supportedTemperatures: [Double] = [1.0]

            // API endpoint support flags.
            let isResponsesOnly =
                model.contains("pro") || isDeepResearch || model == "gpt-5-codex"
            let isBothEndpoint = model == "gpt-5.1" || model == "gpt-5.1-2025-11-13"

            registry[model] = OpenAIModelCapabilities(
                modelType: .reasoning,
                supportsTools: supportsTools,
                supportsStreaming: true,
                supportsVision: false,
                supportsJSONSchema: true,
                maxContextTokens: contextTokens,
                maxOutputTokens: outputTokens,
                supportedTemperatures: supportedTemperatures,
                supportsChatApi: !isResponsesOnly,
                supportsCompletionsApi: isBothEndpoint,
                supportsResponsesApi: isResponsesOnly,
                supportsReasoningEffort: true
            )
        }
    }

    /// Chat Models (GPT-4, GPT-4.1, GPT-4o series, plus gpt-5 chat/search).
    private static func registerGpt4AndNewerChatModels(
        into registry: inout [String: OpenAIModelCapabilities]
    ) {
        let gpt4AndNewerModels = [
            "chatgpt-4o-latest",
            "gpt-4", "gpt-4-0125-preview", "gpt-4-0613", "gpt-4-1106-preview",
            "gpt-4-turbo", "gpt-4-turbo-2024-04-09", "gpt-4-turbo-preview",
            "gpt-4.1", "gpt-4.1-2025-04-14",
            "gpt-4.1-mini", "gpt-4.1-mini-2025-04-14",
            "gpt-4.1-nano", "gpt-4.1-nano-2025-04-14",
            "gpt-4o", "gpt-4o-2024-05-13", "gpt-4o-2024-08-06", "gpt-4o-2024-11-20",
            "gpt-4o-audio-preview", "gpt-4o-audio-preview-2024-12-17",
            "gpt-4o-audio-preview-2025-06-03",
            "gpt-4o-mini", "gpt-4o-mini-2024-07-18",
            "gpt-4o-mini-audio-preview", "gpt-4o-mini-audio-preview-2024-12-17",
            "gpt-4o-mini-search-preview", "gpt-4o-mini-search-preview-2025-03-11",
            "gpt-4o-search-preview", "gpt-4o-search-preview-2025-03-11",
            "gpt-5-chat-latest",
            "gpt-5-search-api", "gpt-5-search-api-2025-10-14",
        ]

        let bothEndpointModels: Set<String> = [
            "gpt-4.1-nano", "gpt-4.1-nano-2025-04-14",
            "gpt-4o-mini", "gpt-4o-mini-2024-07-18",
        ]

        for model in gpt4AndNewerModels {
            let isMiniOrNano = model.contains("mini") || model.contains("nano")
            let isAudio = model.contains("audio")
            let isSearch = model.contains("search")
            let isGpt41 = model.contains("gpt-4.1")
            let isGpt5Chat = model == "gpt-5-chat-latest"

            // chatgpt-4o-latest, gpt-4.1-nano, audio, and search models lack tools.
            let supportsTools =
                model != "chatgpt-4o-latest" && model != "gpt-4.1-nano"
                && !isSearch && !isAudio

            // Audio models require the audio modality and cannot stream.
            let supportsStreaming = !isAudio

            // Keep vision=true for gpt-4o (probe limitation, not a real change).
            let visionSupport =
                model.contains("gpt-4o") || model.contains("audio-preview")
                || model.contains("realtime")

            let contextTokens: Int
            let outputTokens: Int
            if isGpt5Chat {
                contextTokens = 300_000
                outputTokens = 50_000
            } else if isGpt41 {
                contextTokens = isMiniOrNano ? 128_000 : 200_000
                outputTokens = isMiniOrNano ? 16_384 : 32_768
            } else if model.contains("gpt-4o") {
                contextTokens = 128_000
                outputTokens = 16_384
            } else {
                // GPT-4 series.
                contextTokens = 32_000
                outputTokens = 8_192
            }

            // Search models do not accept the temperature parameter.
            let supportedTemperatures: [Double]? = isSearch ? [] : nil

            registry[model] = OpenAIModelCapabilities(
                modelType: .chat,
                supportsTools: supportsTools,
                supportsStreaming: supportsStreaming,
                supportsVision: visionSupport,
                supportsJSONSchema: true,
                maxContextTokens: contextTokens,
                maxOutputTokens: outputTokens,
                supportedTemperatures: supportedTemperatures,
                supportsChatApi: true,
                supportsCompletionsApi: bothEndpointModels.contains(model),
                supportsResponsesApi: false,
                supportsReasoningEffort: false
            )
        }
    }

    /// Chat Models (GPT-3.5 series). `instruct` variants are completions-only.
    private static func registerGpt35Models(
        into registry: inout [String: OpenAIModelCapabilities]
    ) {
        let gpt35Models = [
            "gpt-3.5-turbo", "gpt-3.5-turbo-0125", "gpt-3.5-turbo-1106",
            "gpt-3.5-turbo-16k",
            "gpt-3.5-turbo-instruct", "gpt-3.5-turbo-instruct-0914",
        ]

        for model in gpt35Models {
            let isInstruct = model.contains("instruct")
            registry[model] = OpenAIModelCapabilities(
                modelType: .chat,
                supportsTools: !isInstruct,
                supportsStreaming: !isInstruct,
                supportsVision: false,
                // GPT-3.5 pre-dates json_schema; callers fall back to json_object.
                supportsJSONSchema: false,
                maxContextTokens: 16_385,
                maxOutputTokens: 4_096,
                supportedTemperatures: nil,
                supportsChatApi: !isInstruct,
                supportsCompletionsApi: isInstruct,
                supportsResponsesApi: false,
                supportsReasoningEffort: false
            )
        }
    }

    /// Text embedding models.
    private static func registerEmbeddingModels(
        into registry: inout [String: OpenAIModelCapabilities]
    ) {
        let embeddingModels = [
            "text-embedding-3-large", "text-embedding-3-small",
            "text-embedding-ada-002",
        ]

        for model in embeddingModels {
            registry[model] = OpenAIModelCapabilities(
                modelType: .embedding,
                supportsTools: false,
                supportsStreaming: false,
                supportsVision: false,
                supportsJSONSchema: false,
                maxContextTokens: nil,
                maxOutputTokens: nil,
                supportedTemperatures: nil,
                supportsChatApi: false,
                supportsCompletionsApi: false,
                supportsResponsesApi: false,
                supportsReasoningEffort: false
            )
        }
    }

    /// Legacy completions-only models and the Codex-mini reasoning models.
    private static func registerLegacyAndCodexModels(
        into registry: inout [String: OpenAIModelCapabilities]
    ) {
        registry["babbage-002"] = OpenAIModelCapabilities(
            modelType: .chat,
            supportsTools: false,
            supportsStreaming: false,
            supportsVision: false,
            supportsJSONSchema: false,
            maxContextTokens: 16_384,
            maxOutputTokens: 4_096,
            supportedTemperatures: nil,
            supportsChatApi: false,
            supportsCompletionsApi: true,
            supportsResponsesApi: false,
            supportsReasoningEffort: false
        )
        registry["davinci-002"] = OpenAIModelCapabilities(
            modelType: .chat,
            supportsTools: false,
            supportsStreaming: false,
            supportsVision: false,
            supportsJSONSchema: false,
            maxContextTokens: 16_384,
            maxOutputTokens: 4_096,
            supportedTemperatures: nil,
            supportsChatApi: false,
            supportsCompletionsApi: true,
            supportsResponsesApi: false,
            supportsReasoningEffort: false
        )
        registry["gpt-5.1-codex-mini"] = OpenAIModelCapabilities(
            modelType: .reasoning,
            supportsTools: false,
            supportsStreaming: false,
            supportsVision: false,
            supportsJSONSchema: true,
            maxContextTokens: 200_000,
            maxOutputTokens: 32_768,
            supportedTemperatures: nil,
            supportsChatApi: false,
            supportsCompletionsApi: true,
            supportsResponsesApi: false,
            supportsReasoningEffort: true
        )
        registry["codex-mini-latest"] = OpenAIModelCapabilities(
            modelType: .reasoning,
            supportsTools: false,
            supportsStreaming: false,
            supportsVision: false,
            supportsJSONSchema: true,
            maxContextTokens: 200_000,
            maxOutputTokens: 32_768,
            supportedTemperatures: nil,
            supportsChatApi: false,
            supportsCompletionsApi: false,
            supportsResponsesApi: true,
            supportsReasoningEffort: true
        )
    }

    /// GPT-5.4 / GPT-5.5 era reasoning models — Added 2026-05-21.
    ///
    /// These break the older gpt-5 context/output formula (1.05M or 400K
    /// context, 128K output, image input, both Chat Completions + Responses
    /// APIs), so they are registered explicitly rather than via the
    /// reasoning-model loop.
    private static func registerGpt54PlusModels(
        into registry: inout [String: OpenAIModelCapabilities]
    ) {
        let gpt54PlusModels: [(name: String, contextTokens: Int)] = [
            ("gpt-5.4", 1_050_000),
            ("gpt-5.4-2026-03-05", 1_050_000),
            ("gpt-5.4-mini", 400_000),
            ("gpt-5.4-mini-2026-03-17", 400_000),
            ("gpt-5.4-nano", 400_000),
            ("gpt-5.4-nano-2026-03-17", 400_000),
            ("gpt-5.5", 1_050_000),
            ("gpt-5.5-2026-04-23", 1_050_000),
            ("gpt-5.5-pro", 1_050_000),
            ("gpt-5.5-pro-2026-04-23", 1_050_000),
        ]

        for entry in gpt54PlusModels {
            registry[entry.name] = OpenAIModelCapabilities(
                modelType: .reasoning,
                supportsTools: true,
                supportsStreaming: true,
                supportsVision: true,
                supportsJSONSchema: true,
                maxContextTokens: entry.contextTokens,
                maxOutputTokens: 128_000,
                supportedTemperatures: [1.0],
                supportsChatApi: true,
                supportsCompletionsApi: false,
                supportsResponsesApi: true,
                supportsReasoningEffort: true
            )
        }
    }

    // MARK: - Lookup

    /// Look up capabilities for `model`.
    ///
    /// Falls back to a sensible default based on coarse substring pattern
    /// matching when the model is not explicitly registered. Pattern matching
    /// logs a warning and infers a profile — it never throws.
    ///
    /// - Parameter model: The OpenAI model identifier.
    /// - Returns: The capabilities for the model.
    public func capabilities(for model: String) -> OpenAIModelCapabilities {
        if let direct = entries[model] { return direct }

        let lowered = model.lowercased()
        for (pattern, modelType) in patterns where lowered.contains(pattern) {
            logger.warning(
                "Using pattern matching for unknown model",
                metadata: [
                    "model": .string(model),
                    "pattern": .string(pattern),
                    "inferred": .string(modelType.rawValue),
                ]
            )
            return defaultCapabilities(for: modelType)
        }

        logger.warning(
            "Unknown model, defaulting to chat model capabilities",
            metadata: ["model": .string(model)]
        )
        return defaultCapabilities(for: .chat)
    }

    /// Whether `model` resolves to a reasoning-family model.
    ///
    /// - Parameter model: The OpenAI model identifier.
    /// - Returns: `true` when the model is (or infers to) a reasoning model.
    public func isReasoningModel(_ model: String) -> Bool {
        capabilities(for: model).modelType == .reasoning
    }

    /// All explicitly registered model identifiers.
    public var registeredModels: [String] {
        Array(entries.keys)
    }

    private func defaultCapabilities(
        for modelType: OpenAIModelType
    ) -> OpenAIModelCapabilities {
        switch modelType {
        case .reasoning:
            return OpenAIModelCapabilities(
                modelType: .reasoning,
                supportsTools: false,
                supportsStreaming: false,
                supportsVision: false,
                supportsJSONSchema: true,
                maxContextTokens: nil,
                maxOutputTokens: nil,
                supportedTemperatures: nil,
                supportsChatApi: true,
                supportsCompletionsApi: false,
                supportsResponsesApi: false,
                supportsReasoningEffort: true
            )
        case .chat:
            return OpenAIModelCapabilities(
                modelType: .chat,
                supportsTools: true,
                supportsStreaming: true,
                supportsVision: false,
                supportsJSONSchema: true,
                maxContextTokens: nil,
                maxOutputTokens: nil,
                supportedTemperatures: nil,
                supportsChatApi: true,
                supportsCompletionsApi: false,
                supportsResponsesApi: false,
                supportsReasoningEffort: false
            )
        case .embedding:
            return OpenAIModelCapabilities(
                modelType: .embedding,
                supportsTools: false,
                supportsStreaming: false,
                supportsVision: false,
                supportsJSONSchema: false,
                maxContextTokens: nil,
                maxOutputTokens: nil,
                supportedTemperatures: nil,
                supportsChatApi: false,
                supportsCompletionsApi: false,
                supportsResponsesApi: false,
                supportsReasoningEffort: false
            )
        case .moderation:
            return OpenAIModelCapabilities(
                modelType: .moderation,
                supportsTools: false,
                supportsStreaming: false,
                supportsVision: false,
                supportsJSONSchema: false,
                maxContextTokens: nil,
                maxOutputTokens: nil,
                supportedTemperatures: nil,
                supportsChatApi: false,
                supportsCompletionsApi: false,
                supportsResponsesApi: false,
                supportsReasoningEffort: false
            )
        }
    }
}
