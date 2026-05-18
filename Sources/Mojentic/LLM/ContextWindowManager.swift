import Foundation

/// Trims a message list to fit a model's context window.
///
/// Implementations decide what to evict and in what order. The default
/// `TokenBudgetContextWindowManager` pages out oldest non-system turns when
/// the estimated total exceeds the budget; consumers can plug in their own
/// policy (e.g. summarisation) by conforming to this protocol.
public protocol ContextWindowManager: Sendable {
    /// Return a trimmed copy of `messages` that fits within the budget,
    /// reserving `reserving` tokens for the next assistant turn.
    func trim(_ messages: [LLMMessage], reserving: Int) async throws -> [LLMMessage]
}

/// Default context-window manager: drops oldest non-system messages until
/// the estimated total fits.
///
/// Always preserves the system prompt and the most recent user turn so the
/// model never loses the immediate question.
public struct TokenBudgetContextWindowManager: ContextWindowManager {
    /// Per-model token budget used for trimming.
    public let budget: Int

    /// Model identifier passed to the tokenizer for per-model estimates.
    public let model: String

    /// Tokenizer used to estimate sizes.
    public let tokenizer: any TokenizerGateway

    /// Create a manager bound to a budget and a tokenizer.
    public init(budget: Int, model: String, tokenizer: any TokenizerGateway) {
        precondition(budget > 0, "budget must be positive")
        self.budget = budget
        self.model = model
        self.tokenizer = tokenizer
    }

    /// Trim `messages` to fit within `budget - reserving` tokens.
    public func trim(_ messages: [LLMMessage], reserving: Int) async throws -> [LLMMessage] {
        let cap = max(0, budget - max(0, reserving))
        var current = messages
        var total = try await tokenizer.count(current, model: model)
        if total <= cap { return current }
        let pinned = pinnedIndices(in: current)
        var index = 0
        while total > cap && index < current.count {
            if pinned.contains(index) {
                index += 1
                continue
            }
            // Evict the message at `index`; subsequent indices shift left so
            // we recompute pinned indices in the smaller list.
            current.remove(at: index)
            total = try await tokenizer.count(current, model: model)
            // Re-resolve pinned for the new layout, but stay at the same
            // logical position so we keep moving forward through the
            // (now-shifted) tail.
            let stillPinned = pinnedIndices(in: current)
            if stillPinned.contains(index) {
                index += 1
            }
        }
        return current
    }

    private func pinnedIndices(in messages: [LLMMessage]) -> Set<Int> {
        var pinned: Set<Int> = []
        for (idx, message) in messages.enumerated() where message.role == .system {
            pinned.insert(idx)
        }
        if let lastUser = messages.lastIndex(where: { $0.role == .user }) {
            pinned.insert(lastUser)
        }
        return pinned
    }
}
