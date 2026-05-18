import Foundation

/// Base protocol every event flowing through the dispatcher must conform to.
///
/// Events carry a `correlationId` so the dispatcher and tracer can stitch a
/// chain of events together; `parentId` optionally records the immediate
/// event that caused this one. Event types are identified at routing time
/// by their concrete Swift type — keep them small, focused value types.
public protocol Event: Sendable, Hashable {
    /// Root identifier for the chain of events this one belongs to.
    var correlationId: UUID { get }
    /// Optional identifier of the immediate parent event.
    var parentId: UUID? { get }
}

/// Plain-text event the agent system dispatches as a starting point.
public struct TextEvent: Event, Codable {
    /// Root correlation identifier.
    public let correlationId: UUID
    /// Parent event identifier, when nested.
    public let parentId: UUID?
    /// Text payload.
    public let content: String

    /// Construct a text event.
    public init(content: String, correlationId: UUID = UUID(), parentId: UUID? = nil) {
        self.correlationId = correlationId
        self.parentId = parentId
        self.content = content
    }
}

/// Request to invoke the LLM with a prepared message list, optionally
/// constrained to a specific model + tool set.
public struct LLMRequestEvent: Event, Codable {
    /// Root correlation identifier.
    public let correlationId: UUID
    /// Parent event identifier, when nested.
    public let parentId: UUID?
    /// Conversation prefix for the request.
    public let messages: [LLMMessage]
    /// Optional explicit model name; agents may default this themselves.
    public let model: String?
    /// Tool names the agent expects to make available.
    public let toolNames: [String]?

    /// Construct an LLM request event.
    public init(
        messages: [LLMMessage],
        model: String? = nil,
        toolNames: [String]? = nil,
        correlationId: UUID = UUID(),
        parentId: UUID? = nil
    ) {
        self.correlationId = correlationId
        self.parentId = parentId
        self.messages = messages
        self.model = model
        self.toolNames = toolNames
    }
}

/// Response produced by an LLM-backed agent in reply to an `LLMRequestEvent`
/// or `TextEvent`.
public struct LLMResponseEvent: Event, Codable {
    /// Root correlation identifier.
    public let correlationId: UUID
    /// Parent event identifier, when nested.
    public let parentId: UUID?
    /// Broker-level response from the agent.
    public let response: LLMResponse

    /// Construct a response event.
    public init(
        response: LLMResponse,
        correlationId: UUID,
        parentId: UUID? = nil
    ) {
        self.correlationId = correlationId
        self.parentId = parentId
        self.response = response
    }
}

/// Error surfaced by an agent during dispatch.
///
/// Always non-fatal — the dispatcher routes it to whichever agent has
/// subscribed.
public struct ErrorEvent: Event, Codable {
    /// Root correlation identifier.
    public let correlationId: UUID
    /// Parent event identifier, when nested.
    public let parentId: UUID?
    /// Human-readable description of the failure.
    public let description: String

    /// Construct an error event.
    public init(
        description: String,
        correlationId: UUID,
        parentId: UUID? = nil
    ) {
        self.correlationId = correlationId
        self.parentId = parentId
        self.description = description
    }
}

/// Event the dispatcher fires once a set of correlated events has been
/// aggregated by an ``AsyncAggregatorAgent``.
public struct CompositeEvent: Event {
    /// Root correlation identifier.
    public let correlationId: UUID
    /// Parent event identifier, when nested.
    public let parentId: UUID?
    /// Captured component events, in arrival order.
    public let components: [AnyEvent]

    /// Construct a composite event.
    public init(
        components: [any Event],
        correlationId: UUID,
        parentId: UUID? = nil
    ) {
        self.correlationId = correlationId
        self.parentId = parentId
        self.components = components.map(AnyEvent.init(_:))
    }
}

/// Type-erased event wrapper for places where collections of `any Event`
/// must themselves be `Hashable`.
public struct AnyEvent: Sendable, Hashable {
    /// Underlying event the wrapper preserves.
    public let event: any Event

    /// Wrap an event.
    public init(_ event: any Event) {
        self.event = event
    }

    /// Two wrappers are equal when their underlying events are the same
    /// concrete type and hash equal.
    public static func == (lhs: AnyEvent, rhs: AnyEvent) -> Bool {
        lhs.event.correlationId == rhs.event.correlationId
            && ObjectIdentifier(type(of: lhs.event)) == ObjectIdentifier(type(of: rhs.event))
            && AnyHashable(lhs.event) == AnyHashable(rhs.event)
    }

    /// Combine the concrete event type and value into the hasher.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type(of: event)))
        hasher.combine(AnyHashable(event))
    }
}
