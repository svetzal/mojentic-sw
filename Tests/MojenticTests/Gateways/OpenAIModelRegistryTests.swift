import Foundation
import Testing

@testable import Mojentic

@Suite("OpenAIModelRegistry")
struct OpenAIModelRegistryTests {
    @Test("gpt-4o is registered as a chat+vision model with json_schema support")
    func chatVisionDefaults() {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: "gpt-4o")
        #expect(capabilities.modelType == .chat)
        #expect(capabilities.supportsTools)
        #expect(capabilities.supportsVision)
        #expect(capabilities.supportsJSONSchema)
        #expect(capabilities.tokenLimitParameter == "max_tokens")
        #expect(capabilities.maxContextTokens == 128_000)
        #expect(capabilities.maxOutputTokens == 16_384)
        #expect(capabilities.supportsChatApi)
        #expect(!capabilities.supportsCompletionsApi)
        #expect(!capabilities.supportsResponsesApi)
    }

    @Test("reasoning models use max_completion_tokens and lock temperature")
    func reasoningDefaults() {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: "o3-mini")
        #expect(capabilities.modelType == .reasoning)
        #expect(!capabilities.supportsTemperatureControl)
        #expect(capabilities.supportsReasoningEffort)
        #expect(capabilities.tokenLimitParameter == "max_completion_tokens")
        #expect(capabilities.maxContextTokens == 128_000)
        #expect(capabilities.maxOutputTokens == 32_768)
        #expect(capabilities.supportedTemperatures == [1.0])
        #expect(capabilities.supportsTemperature(1.0))
        #expect(!capabilities.supportsTemperature(0.5))
    }

    @Test("unknown models fall back via pattern matching")
    func patternFallback() {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: "gpt-4o-2099-12-31")
        #expect(capabilities.modelType == .chat)
        let reasoning = OpenAIModelRegistry.shared.capabilities(for: "o1-future-variant")
        #expect(reasoning.modelType == .reasoning)
    }

    @Test("pattern fallback yields nil token limits and never throws")
    func patternFallbackTokenLimits() {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: "totally-made-up-model")
        // No pattern match: defaults to chat with unknown limits.
        #expect(capabilities.modelType == .chat)
        #expect(capabilities.maxContextTokens == nil)
        #expect(capabilities.maxOutputTokens == nil)
    }

    @Test(
        "gpt-5.4 / gpt-5.5 families register as reasoning+vision models",
        arguments: [
            "gpt-5.4", "gpt-5.4-2026-03-05",
            "gpt-5.4-mini", "gpt-5.4-mini-2026-03-17",
            "gpt-5.4-nano", "gpt-5.4-nano-2026-03-17",
            "gpt-5.5", "gpt-5.5-2026-04-23",
            "gpt-5.5-pro", "gpt-5.5-pro-2026-04-23",
        ]
    )
    func gpt54And55Families(model: String) {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: model)
        #expect(capabilities.modelType == .reasoning)
        #expect(capabilities.supportsTools)
        #expect(capabilities.supportsStreaming)
        #expect(capabilities.supportsVision)
        #expect(capabilities.supportsJSONSchema)
        #expect(!capabilities.supportsTemperatureControl)
        #expect(capabilities.supportsReasoningEffort)
        #expect(capabilities.tokenLimitParameter == "max_completion_tokens")
        #expect(capabilities.maxOutputTokens == 128_000)
        #expect(capabilities.supportedTemperatures == [1.0])
        #expect(capabilities.supportsChatApi)
        #expect(!capabilities.supportsCompletionsApi)
        #expect(capabilities.supportsResponsesApi)
    }

    @Test("gpt-5.4 / gpt-5.5 context windows match the cross-port catalog")
    func gpt54And55ContextWindows() {
        let registry = OpenAIModelRegistry.shared
        #expect(registry.capabilities(for: "gpt-5.4").maxContextTokens == 1_050_000)
        #expect(registry.capabilities(for: "gpt-5.5").maxContextTokens == 1_050_000)
        #expect(registry.capabilities(for: "gpt-5.5-pro").maxContextTokens == 1_050_000)
        #expect(registry.capabilities(for: "gpt-5.4-mini").maxContextTokens == 400_000)
        #expect(registry.capabilities(for: "gpt-5.4-nano").maxContextTokens == 400_000)
    }

    @Test("unknown gpt-5.3/5.4/5.5 variants resolve to reasoning via pattern matching")
    func gpt5xPatternFallback() {
        for model in ["gpt-5.3-experimental", "gpt-5.4-2099-01-01", "gpt-5.5-future"] {
            let capabilities = OpenAIModelRegistry.shared.capabilities(for: model)
            #expect(capabilities.modelType == .reasoning)
        }
    }

    @Test("bare gpt-5 entries carry context, output, and API support data")
    func bareGpt5CapabilityData() {
        let registry = OpenAIModelRegistry.shared

        let gpt5 = registry.capabilities(for: "gpt-5")
        #expect(gpt5.modelType == .reasoning)
        #expect(gpt5.maxContextTokens == 300_000)
        #expect(gpt5.maxOutputTokens == 50_000)
        #expect(gpt5.supportsChatApi)
        #expect(!gpt5.supportsResponsesApi)

        let gpt5Mini = registry.capabilities(for: "gpt-5-mini")
        #expect(gpt5Mini.maxContextTokens == 200_000)
        #expect(gpt5Mini.maxOutputTokens == 32_768)
        // gpt-5-mini has incomplete tool support per the cross-port audit.
        #expect(!gpt5Mini.supportsTools)

        // gpt-5-pro is Responses-API only.
        let gpt5Pro = registry.capabilities(for: "gpt-5-pro")
        #expect(!gpt5Pro.supportsChatApi)
        #expect(gpt5Pro.supportsResponsesApi)
    }

    @Test("gpt-5.1 is served by both Chat Completions and legacy Completions")
    func gpt51DualEndpoint() {
        let gpt51 = OpenAIModelRegistry.shared.capabilities(for: "gpt-5.1")
        #expect(gpt51.supportsChatApi)
        #expect(gpt51.supportsCompletionsApi)
        #expect(!gpt51.supportsResponsesApi)
    }

    @Test("GPT-4 / GPT-4.1 / GPT-3.5 chat models carry context and output caps")
    func chatModelTokenLimits() {
        let registry = OpenAIModelRegistry.shared

        let gpt4 = registry.capabilities(for: "gpt-4")
        #expect(gpt4.modelType == .chat)
        #expect(gpt4.maxContextTokens == 32_000)
        #expect(gpt4.maxOutputTokens == 8_192)

        let gpt41 = registry.capabilities(for: "gpt-4.1")
        #expect(gpt41.maxContextTokens == 200_000)
        #expect(gpt41.maxOutputTokens == 32_768)

        let gpt41Mini = registry.capabilities(for: "gpt-4.1-mini")
        #expect(gpt41Mini.maxContextTokens == 128_000)
        #expect(gpt41Mini.maxOutputTokens == 16_384)

        let gpt35 = registry.capabilities(for: "gpt-3.5-turbo")
        #expect(gpt35.maxContextTokens == 16_385)
        #expect(gpt35.maxOutputTokens == 4_096)
        #expect(!gpt35.supportsJSONSchema)
    }

    @Test("search-preview chat models disallow the temperature parameter")
    func searchModelsDisallowTemperature() {
        let search = OpenAIModelRegistry.shared.capabilities(for: "gpt-4o-search-preview")
        #expect(search.supportedTemperatures == [])
        #expect(!search.supportsTemperatureControl)
        #expect(!search.supportsTemperature(1.0))
        #expect(!search.supportsTemperature(0.0))
    }

    @Test("gpt-4o-mini is served by both Chat Completions and legacy Completions")
    func gpt4oMiniDualEndpoint() {
        let mini = OpenAIModelRegistry.shared.capabilities(for: "gpt-4o-mini")
        #expect(mini.supportsChatApi)
        #expect(mini.supportsCompletionsApi)
        #expect(!mini.supportsResponsesApi)
    }

    @Test("audio chat models cannot stream and lack tool support")
    func audioModelsCapabilities() {
        let audio = OpenAIModelRegistry.shared.capabilities(for: "gpt-4o-audio-preview")
        #expect(audio.modelType == .chat)
        #expect(!audio.supportsStreaming)
        #expect(!audio.supportsTools)
    }

    @Test("embedding models expose no token limits and no API endpoints")
    func embeddingModelCapabilities() {
        let embedding = OpenAIModelRegistry.shared.capabilities(for: "text-embedding-3-large")
        #expect(embedding.modelType == .embedding)
        #expect(embedding.maxContextTokens == nil)
        #expect(embedding.maxOutputTokens == nil)
        #expect(!embedding.supportsChatApi)
        #expect(!embedding.supportsCompletionsApi)
        #expect(!embedding.supportsResponsesApi)
    }

    @Test("legacy babbage/davinci models are completions-only")
    func legacyCompletionsModels() {
        let registry = OpenAIModelRegistry.shared
        for model in ["babbage-002", "davinci-002"] {
            let capabilities = registry.capabilities(for: model)
            #expect(!capabilities.supportsChatApi)
            #expect(capabilities.supportsCompletionsApi)
            #expect(!capabilities.supportsResponsesApi)
            #expect(capabilities.maxContextTokens == 16_384)
        }
    }

    @Test("codex models register as reasoning with the expected endpoints")
    func codexModels() {
        let registry = OpenAIModelRegistry.shared

        let codexMini = registry.capabilities(for: "gpt-5.1-codex-mini")
        #expect(codexMini.modelType == .reasoning)
        #expect(codexMini.supportsCompletionsApi)
        #expect(!codexMini.supportsResponsesApi)

        let codexLatest = registry.capabilities(for: "codex-mini-latest")
        #expect(codexLatest.modelType == .reasoning)
        #expect(!codexLatest.supportsCompletionsApi)
        #expect(codexLatest.supportsResponsesApi)
    }

    @Test("text-moderation models infer the moderation type via pattern matching")
    func moderationPatternFallback() {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: "text-moderation-latest")
        #expect(capabilities.modelType == .moderation)
    }

    @Test("isReasoningModel reflects both registered and pattern-matched models")
    func isReasoningModelHelper() {
        let registry = OpenAIModelRegistry.shared
        #expect(registry.isReasoningModel("o3-mini"))
        #expect(registry.isReasoningModel("gpt-5.5-pro"))
        #expect(registry.isReasoningModel("o1-future-variant"))
        #expect(!registry.isReasoningModel("gpt-4o"))
        #expect(!registry.isReasoningModel("text-embedding-3-small"))
    }

    @Test("registeredModels exposes the explicit catalog")
    func registeredModelsCatalog() {
        let models = OpenAIModelRegistry.shared.registeredModels
        #expect(models.contains("gpt-5"))
        #expect(models.contains("gpt-5.4"))
        #expect(models.contains("gpt-4o"))
        #expect(models.contains("text-embedding-3-small"))
        #expect(models.contains("babbage-002"))
        // Pattern-only inferred models are not in the explicit catalog.
        #expect(!models.contains("totally-made-up-model"))
    }

    @Test("supportsTemperature treats nil as unrestricted")
    func unrestrictedTemperature() {
        let chat = OpenAIModelRegistry.shared.capabilities(for: "gpt-4o")
        #expect(chat.supportedTemperatures == nil)
        #expect(chat.supportsTemperatureControl)
        #expect(chat.supportsTemperature(0.0))
        #expect(chat.supportsTemperature(2.0))
    }
}
