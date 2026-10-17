import Foundation
@testable import Mojentic
import Testing

@Suite("CompletionConfig defaults and serialisation")
struct CompletionConfigTests {
    @Test("unset request fields defer to the provider")
    func defaults() {
        let config = CompletionConfig()
        #expect(config.temperature == nil)
        #expect(config.maxTokens == nil)
        #expect(config.topP == nil)
        #expect(config.reasoning == nil)
        #expect(config.reasoningProfile == nil)
        #expect(!config.retainThinking)
        #expect(config.numCtx == nil)
        #expect(config.extraOptions.isEmpty)
        #expect(config.maxToolIterations == 25)
    }

    @Test("round-trips via Codable preserving reasoning effort", arguments: ReasoningEffort.allCases)
    func codableRoundTripWithReasoning(_ effort: ReasoningEffort) throws {
        let original = CompletionConfig(
            temperature: 0.2,
            maxTokens: 1024,
            topP: 0.95,
            reasoning: effort,
            reasoningProfile: .qwen38,
            retainThinking: true,
            numCtx: 8192,
            extraOptions: ["seed": .integer(42)],
            maxToolIterations: 5,
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompletionConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.reasoning == effort)
        #expect(decoded.extraOptions["seed"] == .integer(42))
    }

    @Test("ReasoningEffort has six distinct documented cases")
    func reasoningCases() {
        #expect(ReasoningEffort.allCases == [.disabled, .enabled, .low, .medium, .high, .xhigh])
    }
}
