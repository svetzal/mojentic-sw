import Foundation

/// Base contract every agent that participates in the dispatcher must implement.
///
/// Agents are stateful coordinators — typically `actor` types — that receive
/// events and emit zero or more follow-up events. Conformance to `AnyObject`
/// keeps agent identity stable so the ``Router`` can subscribe and
/// unsubscribe specific instances.
///
/// The protocol is async-first by design (per SWIFT.md §4 Layer 3). There is
/// no separate synchronous variant; ``BaseAsyncAgent`` is provided only as a
/// readability alias for callers carrying the term over from other ports.
public protocol BaseAgent: Sendable, AnyObject {
    /// Handle an event and return follow-up events for the dispatcher.
    func handle(_ event: any Event) async throws -> [any Event]
}

/// Readability alias for ``BaseAgent``.
///
/// Swift's async-first model makes the sync/async distinction moot at the
/// protocol level, so we expose a single contract under two names rather
/// than duplicate the surface (see SWIFT.md §4 Layer 3 "Async-first
/// subsumption").
public typealias BaseAsyncAgent = BaseAgent
