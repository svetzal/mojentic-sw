/// Mojentic — a Swift LLM integration framework.
///
/// Mojentic provides a unified async API for interacting with multiple LLM
/// providers through a single broker, with tool calling, structured output,
/// streaming, an event-driven agent system, and (later) realtime voice.
///
/// Phase 1 (this release) ships the core LLM layer:
///
/// - ``LLMBroker`` — orchestrates completions, structured output, streaming,
///   and recursive tool execution.
/// - ``LLMGateway`` protocol with an ``OllamaGateway`` implementation.
/// - ``LLMTool`` protocol plus reference implementations of
///   ``DateResolverTool`` and ``CurrentDateTimeTool``.
/// - Foundational value types: ``LLMMessage``, ``CompletionConfig``,
///   ``JSONValue``, ``LLMResponse``, ``MojenticError``.
///
/// Subsequent phases will add OpenAI/Anthropic gateways, the full Tracer
/// system, the agent system, and realtime voice. See `SWIFT.md` in the
/// `mojentic-unify` monorepo for the full plan.
public enum Mojentic {
    /// Current package version.
    ///
    /// Synchronised with the cross-port version line per
    /// `mojentic-ru/AGENTS.md` — major and minor track the other ports,
    /// patch versions move independently.
    public static let version = "0.1.0"
}
