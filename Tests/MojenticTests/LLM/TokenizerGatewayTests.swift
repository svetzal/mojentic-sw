import Foundation
import Testing

@testable import Mojentic

@Suite("ApproximateTokenizerGateway")
struct TokenizerGatewayTests {
    @Test("empty text is zero tokens")
    func emptyIsZero() async throws {
        let tokenizer = ApproximateTokenizerGateway()
        let count = try await tokenizer.count("", model: "any")
        #expect(count == 0)
    }

    @Test("non-empty text is never zero tokens")
    func nonEmptyIsPositive() async throws {
        let tokenizer = ApproximateTokenizerGateway()
        let count = try await tokenizer.count("a", model: "any")
        #expect(count >= 1)
    }

    @Test("longer text produces more tokens than shorter text")
    func monotonicity() async throws {
        let tokenizer = ApproximateTokenizerGateway()
        let short = try await tokenizer.count("short", model: "any")
        let long = try await tokenizer.count(String(repeating: "x", count: 400), model: "any")
        #expect(long > short)
    }

    @Test("message overhead is applied per message")
    func messageOverhead() async throws {
        let tokenizer = ApproximateTokenizerGateway()
        let one = try await tokenizer.count([.user("hello")], model: "any")
        let two = try await tokenizer.count([.user("hello"), .user("hello")], model: "any")
        #expect(two > one)
    }
}
