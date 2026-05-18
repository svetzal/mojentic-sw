import Foundation

/// Event-type → agent subscription registry used by ``AsyncDispatcher``.
///
/// Subscribers are stored against the `ObjectIdentifier` of each event's
/// concrete Swift type, so multiple distinct event types route
/// independently. An agent may subscribe to several types; multiple agents
/// may subscribe to the same type (fan-out).
public actor Router {
    private var subscribers: [ObjectIdentifier: [any BaseAgent]] = [:]

    /// Create an empty router.
    public init() {}

    /// Subscribe `agent` to events of type `eventType`.
    public func subscribe<E: Event>(_ agent: any BaseAgent, to eventType: E.Type) {
        let key = ObjectIdentifier(eventType)
        var current = subscribers[key] ?? []
        if !current.contains(where: { $0 === agent }) {
            current.append(agent)
        }
        subscribers[key] = current
    }

    /// Remove `agent` from every event-type subscription.
    public func unsubscribe(_ agent: any BaseAgent) {
        for (key, list) in subscribers {
            subscribers[key] = list.filter { $0 !== agent }
        }
    }

    /// Return the agents subscribed to the concrete type of `event`.
    public func route(_ event: any Event) -> [any BaseAgent] {
        let key = ObjectIdentifier(type(of: event))
        return subscribers[key] ?? []
    }

    /// Return the total number of subscribed entries (used by tests).
    public func subscriberCount() -> Int {
        subscribers.values.map(\.count).reduce(0, +)
    }
}
