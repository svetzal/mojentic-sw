/// Mojentic — a Swift LLM integration framework.
///
/// Mojentic provides a unified async API for interacting with multiple LLM
/// providers (Ollama, OpenAI, Anthropic) through a single broker, with tool
/// calling, structured output, streaming, an event-driven agent system, and
/// realtime voice support.
///
/// This is the Swift port. The Python implementation
/// (`github.com/svetzal/mojentic`) is the reference; see `SWIFT.md` in the
/// `mojentic-unify` monorepo for the full plan.
///
/// > Note: This package is in Phase 0 (skeleton). No public API has shipped yet.
public enum Mojentic {
    /// Current package version.
    ///
    /// Synchronised with the cross-port version line per `mojentic-ru/AGENTS.md`
    /// — major and minor track the other ports, patch versions move independently.
    public static let version = "0.0.0"
}
