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
    }

    @Test("reasoning models use max_completion_tokens and lock temperature")
    func reasoningDefaults() {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: "o3-mini")
        #expect(capabilities.modelType == .reasoning)
        #expect(!capabilities.supportsTemperatureControl)
        #expect(capabilities.supportsReasoningEffort)
        #expect(capabilities.tokenLimitParameter == "max_completion_tokens")
    }

    @Test("unknown models fall back via pattern matching")
    func patternFallback() {
        let capabilities = OpenAIModelRegistry.shared.capabilities(for: "gpt-4o-2099-12-31")
        #expect(capabilities.modelType == .chat)
        let reasoning = OpenAIModelRegistry.shared.capabilities(for: "o1-future-variant")
        #expect(reasoning.modelType == .reasoning)
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
    }

    @Test("unknown gpt-5.3/5.4/5.5 variants resolve to reasoning via pattern matching")
    func gpt5xPatternFallback() {
        for model in ["gpt-5.3-experimental", "gpt-5.4-2099-01-01", "gpt-5.5-future"] {
            let capabilities = OpenAIModelRegistry.shared.capabilities(for: model)
            #expect(capabilities.modelType == .reasoning)
        }
    }
}
