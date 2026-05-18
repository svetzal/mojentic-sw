/// No-op `Tracer` used as the default when no observability sink is wired in.
///
/// Relies entirely on the protocol's default implementations — keeping it
/// allocation-free and free of side effects.
public struct NullTracer: Tracer {
    /// Create a no-op tracer.
    public init() {}
}
