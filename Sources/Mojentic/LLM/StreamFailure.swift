import Foundation

/// A timed failure payload carried by ``MojenticError/streamFailure(_:)``.
///
/// Inspect ``cause`` for the original provider or transport error. Recovery
/// failures retain their `RecoveryError` type and expose evidence directly.
public struct StreamFailure: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Original failure, without replacing provider or cancellation details.
    public let cause: any Error

    /// Provider evidence and client timing measured before terminal failure.
    public let evidence: CompletionEvidence

    /// Safe summary excluding provider strings and payloads.
    public var description: String { "Streaming completion failed" }

    /// Safe debug summary excluding sensitive provider evidence.
    public var debugDescription: String { description }

    /// Reflection requires explicit access to inspect the original cause or evidence.
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    init(cause: any Error, evidence: CompletionEvidence) {
        self.cause = cause
        self.evidence = evidence
    }
}
