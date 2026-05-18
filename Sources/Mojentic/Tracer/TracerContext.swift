import Foundation

/// Correlation context threaded through nested broker / tool / agent calls.
///
/// `correlationId` identifies the root of a logical operation (e.g. one
/// top-level `LLMBroker.complete` invocation). `parentId` identifies the
/// immediate parent event when nesting (broker recursion into a tool, a
/// `ToolWrapper` invoking a nested broker, an agent dispatching to another
/// agent). `EventStore.events(correlatedTo:)` follows this chain.
public struct TracerContext: Sendable, Hashable {
    /// Root identifier for the logical operation.
    public let correlationId: UUID

    /// Identifier of the immediate parent event, when nested.
    public let parentId: UUID?

    /// Construct a context.
    ///
    /// Defaults to a fresh root with no parent.
    public init(correlationId: UUID = UUID(), parentId: UUID? = nil) {
        self.correlationId = correlationId
        self.parentId = parentId
    }

    /// Derive a child context for a nested call.
    ///
    /// Keeps the root `correlationId` and sets `parentId` to the supplied
    /// event id so downstream events nest under that event.
    public func child(parent eventId: UUID) -> TracerContext {
        TracerContext(correlationId: correlationId, parentId: eventId)
    }
}
