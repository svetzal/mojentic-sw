import Foundation

/// Streaming event surfaced by ``RecoveryStreamingGateway/streamRecovering(model:messages:tools:config:)``.
///
/// Gateways emit a normalised stream of these so the broker can run its
/// tool-call recursion uniformly across providers.
public enum RecoveryGatewayStreamEvent: Sendable {
    /// A delta of assistant text content.
    case textDelta(String)

    /// A delta of model reasoning trace (provider-supplied).
    case thinkingDelta(String)

    /// Validated observed progress for an opt-in recovery stream.
    case progress(RecoveryProgress)

    /// Provider evidence from a validated recovery streaming frame.
    case metrics(CompletionEvidence)

    /// One fully-assembled tool-call request the model wants to invoke.
    case toolCallRequest(LLMToolCall)

    /// The provider declared the stream complete. May carry finish reason
    /// and usage when reported.
    case done(finishReason: FinishReason?, usage: Usage?)
}

/// One event from ``LLMBroker/generateRecoveryStreamEvents(model:messages:config:context:)``.
///
/// A stream yields zero or more ``content(_:)`` events, then exactly one
/// terminal event: ``completed(_:)``, ``error(_:)``, or ``recoveryFailure(_:)``. Nothing follows the
/// terminal event.
///
/// Content yielded before an ``error(_:)`` is evidence of what the provider
/// sent, not a result. Do not act on it as a finished answer.
public enum RecoveryCompletionStreamEvent: Sendable {
    /// Visible assistant content, in the order the provider sent it.
    case content(String)

    /// Validated observed progress for an opt-in recovery stream.
    case progress(RecoveryProgress)

    /// Provider evidence from a validated recovery streaming frame.
    case metrics(CompletionEvidence)

    /// Terminal success: the provider proved the turn finished normally.
    case completed(CompletionEvidence)

    /// Terminal failure. ``MojenticError/incompleteCompletion(_:)`` carries
    /// the provider's evidence; other cases describe what went wrong.
    case error(MojenticError)

    /// Terminal recovery failure retaining typed causes and attempt history.
    case recoveryFailure(RecoveryError)

    /// Whether this event ends the stream.
    public var isTerminal: Bool {
        switch self {
        case .content, .progress, .metrics: return false
        default: break
        }
        return true
    }
}
