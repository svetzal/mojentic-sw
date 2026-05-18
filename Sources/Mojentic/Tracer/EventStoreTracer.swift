import Foundation

/// `Tracer` implementation that records every event into an ``EventStore``.
///
/// Wrap an `EventStore` you own so you can inspect or persist the recorded
/// events outside the tracer (the store is `Sendable` and safe to share
/// across actors).
public struct EventStoreTracer: Tracer {
    /// Underlying store.
    ///
    /// Exposed publicly so callers can query it after recording finishes.
    public let store: EventStore

    /// Create a tracer that writes into `store`.
    public init(store: EventStore = EventStore()) {
        self.store = store
    }

    /// Record an LLM call payload into the backing store.
    public func recordLLMCall(_ payload: LLMCallPayload) async {
        await store.record(.llmCall(payload))
    }

    /// Record an LLM response payload into the backing store.
    public func recordLLMResponse(_ payload: LLMResponsePayload) async {
        await store.record(.llmResponse(payload))
    }

    /// Record a tool-call payload into the backing store.
    public func recordToolCall(_ payload: ToolCallPayload) async {
        await store.record(.toolCall(payload))
    }

    /// Record a tool-result payload into the backing store.
    public func recordToolResult(_ payload: ToolResultPayload) async {
        await store.record(.toolResult(payload))
    }

    /// Record a tool-batch payload into the backing store.
    public func recordToolBatch(_ payload: ToolBatchPayload) async {
        await store.record(.toolBatch(payload))
    }

    /// Record an agent-lifecycle payload into the backing store.
    public func recordAgentLifecycle(_ payload: AgentLifecyclePayload) async {
        await store.record(.agentLifecycle(payload))
    }
}
