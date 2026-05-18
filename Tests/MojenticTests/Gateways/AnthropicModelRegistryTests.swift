import Foundation
import Testing

@testable import Mojentic

@Suite("AnthropicModelRegistry")
struct AnthropicModelRegistryTests {
    @Test("explicitly registered models surface their flags")
    func registeredLookup() {
        let registry = AnthropicModelRegistry.shared
        let sonnet = registry.capabilities(for: "claude-3-5-sonnet-latest")
        #expect(sonnet.supportsTools)
        #expect(sonnet.supportsVision)
        #expect(!sonnet.supportsExtendedThinking)

        let opus = registry.capabilities(for: "claude-opus-4-7")
        #expect(opus.supportsExtendedThinking)
    }

    @Test("unknown model names fall back via pattern matching")
    func patternFallback() {
        let registry = AnthropicModelRegistry.shared
        let unknown = registry.capabilities(for: "claude-3-5-sonnet-2099-01-01")
        #expect(unknown.supportsTools)
        #expect(unknown.supportsVision)
    }

    @Test("registeredModels returns a sorted, non-empty list")
    func listIsStable() {
        let models = AnthropicModelRegistry.shared.registeredModels()
        #expect(!models.isEmpty)
        #expect(models == models.sorted())
    }
}
