import Foundation

/// Sibling to ``LLMBroker``: opens realtime voice sessions and pre-installs
/// the parallel tool runner so concurrent function calls within a single
/// response turn are dispatched in parallel.
///
/// > Note: Only the OpenAI Realtime API is supported in Phase 5; Anthropic
/// > has no realtime endpoint. The protocol is provider-agnostic so adding
/// > another realtime provider later is a gateway implementation, not a
/// > broker change.
public actor RealtimeVoiceBroker {
    private let gateway: any RealtimeGateway
    private let tracer: any Tracer
    private let toolRunner: any ToolRunner

    /// Create the broker.
    ///
    /// - Parameters:
    ///   - gateway: Realtime gateway used to open the session.
    ///   - tracer: Observability sink (defaults to ``NullTracer``).
    ///   - toolRunner: Tool runner used inside the session (defaults to
    ///     ``ParallelToolRunner`` because realtime turns commonly emit
    ///     concurrent function calls).
    public init(
        gateway: any RealtimeGateway,
        tracer: any Tracer = NullTracer(),
        toolRunner: any ToolRunner = ParallelToolRunner()
    ) {
        self.gateway = gateway
        self.tracer = tracer
        self.toolRunner = toolRunner
    }

    /// Start a new session.
    public func startSession(_ config: RealtimeSessionConfig) async throws -> RealtimeSession {
        try await gateway.openSession(config, tracer: tracer, toolRunner: toolRunner)
    }
}
