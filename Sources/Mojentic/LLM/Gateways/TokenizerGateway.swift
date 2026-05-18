import Foundation

/// Estimates token counts for messages and free text.
///
/// Phase 2 ships `ApproximateTokenizerGateway` — a deliberately simple
/// `chars / 4` heuristic suitable for budgeting context-window trims. It is
/// approximate; consumers that need accurate token accounting (cost
/// reporting, hard limits) should plug in a real tokenizer (e.g. a
/// `tiktoken-swift` implementation when stable) by conforming to this
/// protocol.
public protocol TokenizerGateway: Sendable {
    /// Estimate the token count for an arbitrary string against `model`.
    func count(_ text: String, model: String) async throws -> Int

    /// Estimate the total token count for the supplied message list against
    /// `model`. Implementations are free to add per-message overhead.
    func count(_ messages: [LLMMessage], model: String) async throws -> Int
}

/// Default tokenizer gateway.
///
/// Estimates tokens with a `chars / 4` heuristic plus a small per-message
/// overhead. Use it for context-window budgeting where approximate accuracy
/// is acceptable; do not use it for cost reporting or strict provider-side
/// limit enforcement.
public struct ApproximateTokenizerGateway: TokenizerGateway {
    /// Approximate characters per token.
    ///
    /// The OpenAI rule-of-thumb is ~4 characters per token for English text.
    public let charactersPerToken: Int

    /// Per-message overhead added to account for role + delimiter tokens.
    public let perMessageOverhead: Int

    /// Create an estimator.
    ///
    /// Defaults match the published OpenAI guidance for English text.
    public init(charactersPerToken: Int = 4, perMessageOverhead: Int = 4) {
        precondition(charactersPerToken > 0, "charactersPerToken must be positive")
        precondition(perMessageOverhead >= 0, "perMessageOverhead must be non-negative")
        self.charactersPerToken = charactersPerToken
        self.perMessageOverhead = perMessageOverhead
    }

    /// Estimate tokens for a plain string.
    public func count(_ text: String, model _: String) async throws -> Int {
        Self.estimate(text: text, charactersPerToken: charactersPerToken)
    }

    /// Estimate tokens for a message list, adding per-message overhead.
    public func count(_ messages: [LLMMessage], model _: String) async throws -> Int {
        var total = 0
        for message in messages {
            total += perMessageOverhead
            if let content = message.content {
                total += Self.estimate(text: content, charactersPerToken: charactersPerToken)
            }
            if let calls = message.toolCalls {
                for call in calls {
                    total += Self.estimate(text: call.name, charactersPerToken: charactersPerToken)
                    if let data = try? JSONEncoder().encode(call.arguments),
                        let serialised = String(data: data, encoding: .utf8)
                    {
                        total += Self.estimate(
                            text: serialised, charactersPerToken: charactersPerToken
                        )
                    }
                }
            }
        }
        return total
    }

    private static func estimate(text: String, charactersPerToken: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        // Round up so non-empty input is never counted as zero tokens.
        return max(1, (text.count + charactersPerToken - 1) / charactersPerToken)
    }
}
