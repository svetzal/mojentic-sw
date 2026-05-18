import Foundation
import Testing

@testable import Mojentic

@Suite("AsyncAggregatorAgent")
struct AsyncAggregatorAgentTests {
    @Test("fires CompositeEvent once expected events for a correlation arrive")
    func firesOnce() async throws {
        let aggregator = AsyncAggregatorAgent(expected: 2)
        let correlation = UUID()
        let first = try await aggregator.handle(
            TextEvent(content: "a", correlationId: correlation)
        )
        #expect(first.isEmpty)
        let second = try await aggregator.handle(
            TextEvent(content: "b", correlationId: correlation)
        )
        #expect(second.count == 1)
        let composite = second.first as? CompositeEvent
        #expect(composite?.components.count == 2)
        #expect(composite?.correlationId == correlation)
    }

    @Test("ignores stragglers under the same correlation after firing")
    func ignoresStragglers() async throws {
        let aggregator = AsyncAggregatorAgent(expected: 1)
        let correlation = UUID()
        _ = try await aggregator.handle(
            TextEvent(content: "fire", correlationId: correlation)
        )
        let straggler = try await aggregator.handle(
            TextEvent(content: "ignored", correlationId: correlation)
        )
        #expect(straggler.isEmpty)
    }

    @Test("different correlations track independently")
    func independentCorrelations() async throws {
        let aggregator = AsyncAggregatorAgent(expected: 2)
        let firstCorrelation = UUID()
        let secondCorrelation = UUID()
        _ = try await aggregator.handle(
            TextEvent(content: "a", correlationId: firstCorrelation)
        )
        let secondPartial = try await aggregator.handle(
            TextEvent(content: "x", correlationId: secondCorrelation)
        )
        #expect(secondPartial.isEmpty)
        let firstComposite = try await aggregator.handle(
            TextEvent(content: "b", correlationId: firstCorrelation)
        )
        #expect(firstComposite.count == 1)
    }
}
