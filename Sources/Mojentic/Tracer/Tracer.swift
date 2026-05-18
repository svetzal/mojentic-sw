import Foundation

/// Minimal tracer surface the broker calls into during Phase 1.
///
/// > Note: Phase 3 will expand this into a full `TracerEvent` union backed
/// > by an `EventStore` actor with correlation tracking and `Duration`
/// > metrics, per `SWIFT.md` §4 Layer 2. The signatures below give us just
/// > enough so the broker's public API doesn't churn when Phase 3 ships:
/// > we already accept a `tracer:` parameter today.
public protocol Tracer: Sendable {
    /// Called immediately before the broker dispatches a gateway request.
    func recordLLMCall(
        model: String,
        messages: [LLMMessage],
        tools: [String]?
    ) async

    /// Called once the gateway returns.
    ///
    /// `duration` is wall-clock from call to response.
    func recordLLMResponse(
        model: String,
        response: LLMGatewayResponse,
        duration: Duration
    ) async

    /// Called once per dispatched tool call.
    func recordToolCall(
        name: String,
        arguments: JSONValue,
        duration: Duration
    ) async

    /// Called once per resolved tool outcome.
    func recordToolResult(
        outcome: ToolCallOutcome,
        duration: Duration
    ) async
}

extension Tracer {
    /// Default no-op implementation.
    public func recordLLMCall(
        model _: String,
        messages _: [LLMMessage],
        tools _: [String]?
    ) async {}

    /// Default no-op implementation.
    public func recordLLMResponse(
        model _: String,
        response _: LLMGatewayResponse,
        duration _: Duration
    ) async {}

    /// Default no-op implementation.
    public func recordToolCall(
        name _: String,
        arguments _: JSONValue,
        duration _: Duration
    ) async {}

    /// Default no-op implementation.
    public func recordToolResult(
        outcome _: ToolCallOutcome,
        duration _: Duration
    ) async {}
}
