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
}
