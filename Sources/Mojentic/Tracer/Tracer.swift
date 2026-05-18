import Foundation

/// Observability sink for broker, tool runner, and (Phase 4) agent events.
///
/// Every method has a default no-op implementation so consumers can adopt
/// the protocol incrementally. ``NullTracer`` relies on these defaults;
/// ``EventStoreTracer`` records to an in-memory ``EventStore``.
///
/// All recording is `async` so backends are free to do I/O (write to a
/// log file, ship to an OTLP collector) without blocking callers on a
/// synchronous boundary.
public protocol Tracer: Sendable {
    /// Record that the broker is about to dispatch an LLM call.
    func recordLLMCall(_ payload: LLMCallPayload) async

    /// Record that the broker received a response from the gateway.
    func recordLLMResponse(_ payload: LLMResponsePayload) async

    /// Record a single tool dispatch.
    func recordToolCall(_ payload: ToolCallPayload) async

    /// Record the outcome of a single tool dispatch.
    func recordToolResult(_ payload: ToolResultPayload) async

    /// Record a parallel-runner batch summary.
    func recordToolBatch(_ payload: ToolBatchPayload) async

    /// Record an agent lifecycle phase.
    func recordAgentLifecycle(_ payload: AgentLifecyclePayload) async
}

extension Tracer {
    /// Default no-op implementation.
    public func recordLLMCall(_ payload: LLMCallPayload) async {
        _ = payload
    }

    /// Default no-op implementation.
    public func recordLLMResponse(_ payload: LLMResponsePayload) async {
        _ = payload
    }

    /// Default no-op implementation.
    public func recordToolCall(_ payload: ToolCallPayload) async {
        _ = payload
    }

    /// Default no-op implementation.
    public func recordToolResult(_ payload: ToolResultPayload) async {
        _ = payload
    }

    /// Default no-op implementation.
    public func recordToolBatch(_ payload: ToolBatchPayload) async {
        _ = payload
    }

    /// Default no-op implementation.
    public func recordAgentLifecycle(_ payload: AgentLifecyclePayload) async {
        _ = payload
    }
}
