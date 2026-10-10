import Foundation
@testable import Mojentic
import Testing

@Suite("CompletionConfig defaults and serialisation")
struct CompletionConfigTests {
    @Test("default values match SWIFT.md baseline")
    func defaults() {
        let config = CompletionConfig()
        #expect(config.temperature == 1.0)
        #expect(config.maxTokens == 16384)
        #expect(config.topP == nil)
        #expect(config.reasoning == nil)
        #expect(config.numCtx == 32768)
        #expect(config.extraOptions.isEmpty)
        #expect(config.maxToolIterations == 25)
    }

    @Test("round-trips via Codable preserving reasoning effort")
    func codableRoundTripWithReasoning() throws {
        let original = CompletionConfig(
            temperature: 0.2,
            maxTokens: 1024,
            topP: 0.95,
            reasoning: .medium,
            numCtx: 8192,
            extraOptions: ["seed": .integer(42)],
            maxToolIterations: 5,
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompletionConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.reasoning == .medium)
        #expect(decoded.extraOptions["seed"] == .integer(42))
    }

    @Test("ReasoningEffort has the three documented cases")
    func reasoningCases() {
        #expect(ReasoningEffort.allCases == [.low, .medium, .high])
    }
}
