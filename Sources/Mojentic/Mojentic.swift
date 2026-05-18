/// Mojentic — a Swift LLM integration framework.
///
/// Mojentic provides a unified async API for interacting with multiple LLM
/// providers through a single broker, with tool calling, structured output,
/// streaming, an event-driven agent system, and realtime voice support.
///
/// The 1.4.0 release achieves cross-port parity with the Python, TypeScript,
/// Elixir, and Rust implementations across all four layers (LLM, Tracer,
/// Agents, Realtime Voice). See ``Mojentic`` for the topic guide and the
/// Use Case tutorials for end-to-end walkthroughs.
public enum Mojentic {
    /// Current package version.
    ///
    /// Synchronised with the cross-port version line per
    /// `mojentic-ru/AGENTS.md` — major and minor track the other ports,
    /// patch versions move independently.
    public static let version = "1.4.0"
}
