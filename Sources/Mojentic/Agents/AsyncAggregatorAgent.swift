import Foundation

/// Aggregates a fixed expected number of correlated events and fires a
/// single ``CompositeEvent`` once the threshold is met.
///
/// Events past the threshold for a given `correlationId` are dropped (the
/// aggregator only fires once per correlation). Mirrors the Python
/// `AsyncAggregatorAgent` contract — the simpler "count of expected
/// responses" form, sufficient for the per-port parity row.
public actor AsyncAggregatorAgent: BaseAgent {
    private let expected: Int
    private var pending: [UUID: [any Event]] = [:]
    private var fired: Set<UUID> = []

    /// Create an aggregator that fires after `expected` events for a
    /// correlation id have been observed.
    public init(expected: Int) {
        precondition(expected > 0, "expected must be positive")
        self.expected = expected
    }

    /// Capture an incoming event; emit a CompositeEvent once expected count reached.
    public func handle(_ event: any Event) async throws -> [any Event] {
        let id = event.correlationId
        if fired.contains(id) { return [] }
        var bucket = pending[id] ?? []
        bucket.append(event)
        if bucket.count >= expected {
            fired.insert(id)
            pending.removeValue(forKey: id)
            return [
                CompositeEvent(
                    components: bucket,
                    correlationId: id,
                    parentId: event.parentId
                )
            ]
        }
        pending[id] = bucket
        return []
    }
}
