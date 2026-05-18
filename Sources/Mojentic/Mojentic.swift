/// Mojentic — a Swift LLM integration framework.
///
/// Mojentic provides a unified async API for interacting with multiple LLM
/// providers through a single broker, with tool calling, structured output,
/// streaming, an event-driven agent system, and realtime voice support.
///
/// The 2.0.0 release achieves cross-port parity with the Python, TypeScript,
/// Elixir, and Rust implementations across all four layers (LLM, Tracer,
/// Agents, Realtime Voice) — Realtime is the 2.0 line. See ``Mojentic`` for
/// the topic guide and the Use Case tutorials for end-to-end walkthroughs.
public enum Mojentic {
    /// Current package version.
    ///
    /// Synchronised with the cross-port version line per
    /// `mojentic-ru/AGENTS.md` — major and minor track the other ports,
    /// patch versions move independently. Realtime Voice support moves
    /// Mojentic to the 2.0 line across all ports.
    public static let version = "2.0.0"
}
