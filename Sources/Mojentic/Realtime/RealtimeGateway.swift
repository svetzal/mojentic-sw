import Foundation

/// Turn-detection policy negotiated with the realtime provider.
public enum VADMode: Sendable, Hashable {
    /// Server VAD: provider detects user start/stop and auto-responds.
    case server
    /// Manual VAD (push-to-talk): client controls turn boundaries via
    /// ``RealtimeSession/commit()``.
    case manual
}

/// Connection parameters for opening a realtime session.
public struct RealtimeSessionConfig: Sendable {
    /// Model identifier the provider should use.
    public let model: String
    /// API key (never read from env by the library).
    public let apiKey: String
    /// Tools exposed to the model during the session.
    public let tools: [any LLMTool]
    /// Turn-detection policy.
    public let vad: VADMode
    /// Optional system instructions sent on session.update.
    public let instructions: String?

    /// Construct a config.
    public init(
        model: String,
        apiKey: String,
        tools: [any LLMTool] = [],
        vad: VADMode = .server,
        instructions: String? = nil
    ) {
        precondition(!apiKey.isEmpty, "Realtime API key must not be empty")
        self.model = model
        self.apiKey = apiKey
        self.tools = tools
        self.vad = vad
        self.instructions = instructions
    }
}

/// Provider-agnostic factory for opening a realtime session.
///
/// > Note: only the OpenAI Realtime API ships in Phase 5. Anthropic has no
/// > realtime endpoint at the time of writing; Phase 6 will add Anthropic
/// > for text only.
public protocol RealtimeGateway: Sendable {
    /// Open a new session against the provider and return a
    /// ``RealtimeSession`` ready for audio/text traffic.
    func openSession(
        _ config: RealtimeSessionConfig,
        tracer: any Tracer,
        toolRunner: any ToolRunner
    ) async throws -> RealtimeSession
}
