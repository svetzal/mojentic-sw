import Foundation
import Testing

@testable import Mojentic

@Suite("TokenBudgetContextWindowManager")
struct ContextWindowManagerTests {
    private func makeManager(budget: Int) -> TokenBudgetContextWindowManager {
        TokenBudgetContextWindowManager(
            budget: budget,
            model: "test",
            tokenizer: ApproximateTokenizerGateway(charactersPerToken: 4, perMessageOverhead: 0)
        )
    }

    @Test("returns input unchanged when it already fits")
    func passThroughWhenFits() async throws {
        let manager = makeManager(budget: 1_000)
        let messages: [LLMMessage] = [.system("rules"), .user("hi")]
        let trimmed = try await manager.trim(messages, reserving: 0)
        #expect(trimmed == messages)
    }

    @Test("evicts oldest non-system messages when over budget")
    func evictOldest() async throws {
        let manager = makeManager(budget: 15)
        let messages: [LLMMessage] = [
            .system("pinned system prompt"),
            .user(String(repeating: "a", count: 80)),
            .assistant(String(repeating: "b", count: 80)),
            .user("latest question"),
        ]
        let trimmed = try await manager.trim(messages, reserving: 0)
        #expect(trimmed.first?.role == .system)
        #expect(trimmed.last?.content == "latest question")
        // The middle filler turns must be evicted.
        #expect(trimmed.count < messages.count)
    }

    @Test("always preserves the most recent user turn")
    func preservesLatestUser() async throws {
        let manager = makeManager(budget: 5)
        let messages: [LLMMessage] = [
            .system("rules"),
            .user(String(repeating: "x", count: 200)),
            .user("only the latest matters"),
        ]
        let trimmed = try await manager.trim(messages, reserving: 0)
        #expect(trimmed.contains(where: { $0.content == "only the latest matters" }))
        #expect(trimmed.first?.role == .system)
    }
}
