import Foundation

/// Token-usage report carried on `responseDone` events.
public struct RealtimeTokenUsage: Sendable, Hashable, Codable {
    /// Input tokens consumed by the turn.
    public let promptTokens: Int?
    /// Output tokens produced by the turn.
    public let completionTokens: Int?
    /// Combined prompt + completion tokens.
    public let totalTokens: Int?

    /// Construct a usage record.
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

/// Vendor-neutral event union surfaced by a realtime session.
///
/// Consumers pattern-match on the case rather than on raw provider events
/// so the same observer code ports cleanly across providers. The escape
/// hatch is ``RealtimeSession/rawEvents()``, which surfaces the underlying
/// JSON for cases that don't fit the neutral union.
public enum RealtimeEvent: Sendable, Hashable {
    // Session lifecycle
    /// The provider acknowledged the session.
    case sessionCreated(sessionId: String)
    /// The provider applied an updated session configuration.
    case sessionUpdated
    /// The session is being torn down.
    case sessionClosed(reason: SessionCloseReason)

    // User audio
    /// Server VAD detected the user starting to speak.
    case speechStarted
    /// Server VAD detected the user stopping speaking.
    case speechStopped
    /// Incremental transcript of the user's audio.
    case userTranscriptDelta(itemId: String, delta: String)
    /// Final transcript of the user's audio for this item.
    case userTranscript(itemId: String, text: String)

    // Assistant output
    /// A new response turn has begun.
    case responseStarted(turnId: String)
    /// Incremental text content for the in-flight turn.
    case textDelta(turnId: String, delta: String)
    /// Final text content for the turn.
    case textDone(turnId: String, text: String)
    /// Incremental transcript of the assistant's audio.
    case transcriptDelta(turnId: String, delta: String)
    /// Final transcript of the assistant's audio.
    case transcript(turnId: String, text: String)
    /// One chunk of assistant audio.
    case audioDelta(turnId: String, frame: AudioFrame)
    /// Audio stream finished for this turn.
    case audioDone(turnId: String)
    /// The response turn finished cleanly.
    case responseDone(turnId: String, usage: RealtimeTokenUsage?)

    // Tools (mirror the parity row in PARITY.md)
    /// The model announced a function call.
    case toolCallStarted(turnId: String, callId: String, name: String)
    /// Streaming JSON arguments for an in-flight function call.
    case toolCallArgsDelta(callId: String, delta: String)
    /// The runner dispatched a tool with parsed arguments.
    case toolCallDispatched(callId: String, name: String, arguments: JSONValue)
    /// The tool returned a result.
    case toolCallResult(callId: String, name: String, result: JSONValue)
    /// The tool failed.
    case toolCallFailed(callId: String, name: String, message: String)
    /// A parallel batch of tool outputs was submitted upstream.
    case toolBatchSubmitted(turnId: String, callIds: [String])

    // Interruption / error
    /// A turn was interrupted (barge-in or manual).
    case interrupted(turnId: String, reason: InterruptReason)
    /// The provider raised an error.
    case errorOccurred(String)
}

/// Why a realtime session closed.
public enum SessionCloseReason: String, Sendable, Hashable, Codable {
    /// Closed by the local client.
    case client
    /// Closed by the remote server.
    case server
    /// Closed due to a transport-level error.
    case error
}

/// Why a turn was interrupted.
public enum InterruptReason: String, Sendable, Hashable, Codable {
    /// User started speaking while the assistant was producing output.
    case bargeIn = "barge_in"
    /// The application called ``RealtimeSession/interrupt()``.
    case manual
    /// Interrupted because of a transport error.
    case error
}
