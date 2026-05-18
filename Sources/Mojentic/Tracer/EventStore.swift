import Foundation

/// In-memory store of recorded tracer events.
///
/// `actor` because multiple concurrent broker invocations can record into
/// the same store from different tasks. Backing storage is an append-only
/// array of ``TracerEvent``; queries return value-type snapshots so callers
/// can iterate without holding the actor.
public actor EventStore {
    private var events: [TracerEvent] = []

    /// Create an empty event store.
    public init() {}

    /// Append an event to the store.
    public func record(_ event: TracerEvent) {
        events.append(event)
    }

    /// Return all recorded events in insertion order.
    public func allEvents() -> [TracerEvent] {
        events
    }

    /// Return events matching the supplied predicate.
    public func events(
        matching predicate: @Sendable (TracerEvent) -> Bool
    ) -> [TracerEvent] {
        events.filter(predicate)
    }

    /// Return every event whose correlation tree resolves to `correlationId`.
    ///
    /// An event qualifies when:
    /// - its `correlationId == correlationId`, or
    /// - its `parentId` chain (followed through prior recorded events)
    ///   ultimately resolves to one of those root-correlated events.
    public func events(correlatedTo correlationId: UUID) -> [TracerEvent] {
        let roots = events.filter { $0.correlationId == correlationId }
        guard !roots.isEmpty else { return [] }
        let known = Set(roots.map(\.id))
        var ancestry: [UUID: UUID?] = [:]
        for event in events {
            ancestry[event.id] = event.parentId
        }
        var qualifying = known
        var changed = true
        while changed {
            changed = false
            for event in events where !qualifying.contains(event.id) {
                if let parent = event.parentId, qualifying.contains(parent) {
                    qualifying.insert(event.id)
                    changed = true
                }
            }
        }
        return events.filter { qualifying.contains($0.id) }
    }
}
