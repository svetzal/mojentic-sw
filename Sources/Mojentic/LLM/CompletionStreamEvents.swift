import Foundation

/// Provider evidence and client measurements for a single streaming completion.
///
/// Provider fields are exactly what the provider reported, or `nil` when absent.
/// Metadata also carries monotonic client timing in milliseconds, with names
/// distinct from the provider's own metrics.
public struct CompletionEvidence: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Full local wire identity for recovery metrics, absent for legacy evidence.
    public var identity: RecoveryIdentity?

    /// One-based validated provider frame index for recovery metrics.
    public var frameIndex: Int?

    /// Safe summary; inspect properties explicitly for provider metadata.
    public var description: String {
        "Provider completion evidence"
    }

    /// Safe debug summary excluding echoed provider strings.
    public var debugDescription: String {
        description
    }

    /// Finish reason exactly as reported (OpenAI `finish_reason`, Ollama
    /// `done_reason`), for example `stop` or `length`.
    public let finishReason: String?

    /// Token usage as reported by the provider.
    public let usage: Usage?

    /// Model name the provider reported serving the request.
    public let providerModel: String?

    /// Provider metadata plus client streaming timing.
    ///
    /// `request_duration_ms` measures first dispatch to terminal success or failure.
    /// `time_to_first_token_ms` and `first_token_kind` are absent without tokens;
    /// kinds are `thinking`, `content`, and `tool_call` in frame precedence order.
    public let metadata: [String: JSONValue]?

    /// Create completion evidence.
    public init(
        finishReason: String? = nil,
        usage: Usage? = nil,
        providerModel: String? = nil,
        metadata: [String: JSONValue]? = nil,
    ) {
        self.finishReason = finishReason
        self.usage = usage
        self.providerModel = providerModel
        self.metadata = metadata
    }
}

/// One event from ``LLMBroker/generateStreamEvents(model:messages:config:context:)``.
///
/// A stream yields zero or more ``content(_:)`` events, then exactly one
/// terminal event: ``completed(_:)`` or ``error(_:)``. Nothing follows the
/// terminal event.
///
/// Content yielded before an ``error(_:)`` is evidence of what the provider
/// sent, not a result. Do not act on it as a finished answer.
public enum CompletionStreamEvent: Sendable {
    /// Visible assistant content, in the order the provider sent it.
    case content(String)

    /// Terminal success: the provider proved the turn finished normally.
    case completed(CompletionEvidence)

    /// Terminal failure with timing and the original cause in ``MojenticError/streamFailure(_:)``.
    ///
    /// Validation errors before dispatch retain their original case.
    case error(MojenticError)

    /// Whether this event ends the stream.
    public var isTerminal: Bool {
        switch self {
        case .content: return false
        default: break
        }
        return true
    }
}

/// Parses one provider's streaming lines into single-turn completion events.
///
/// Implementations are pure state machines: they hold the evidence seen so
/// far and decide when the stream has reached a terminal event.
protocol CompletionEventParser: Sendable {
    /// Whether a terminal event has already been produced.
    var isTerminal: Bool { get }

    /// Evidence that arrived before the stream ended, for an
    /// incomplete-stream error; `nil` when none arrived.
    var partialEvidence: CompletionEvidence? { get }

    /// Consume one line of the response and return the events it produces.
    mutating func consume(line: String) -> [CompletionStreamEvent]
}

/// Runs a single streaming request through a ``CompletionEventParser``.
enum CompletionEventStreaming {
    /// Issue one streaming request and translate its lines into completion events.
    ///
    /// Ends with exactly one terminal event. Terminating the returned stream
    /// cancels the request.
    static func events(
        transport: any LineStreamingTransport,
        url: URL,
        body: some Encodable & Sendable,
        headers: [String: String],
        parser: some CompletionEventParser,
    ) -> AsyncStream<CompletionStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                await continuation.yield(
                    relay(
                        transport: transport,
                        url: url,
                        body: body,
                        headers: headers,
                        parser: parser,
                        continuation: continuation,
                    )
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yield non-terminal events and return the terminal one.
    private static func relay(
        transport: any LineStreamingTransport,
        url: URL,
        body: some Encodable & Sendable,
        headers: [String: String],
        parser initial: some CompletionEventParser,
        continuation: AsyncStream<CompletionStreamEvent>.Continuation,
    ) async -> CompletionStreamEvent {
        var parser = initial
        let timing = StreamMeasurement()
        do {
            let lines = try await transport.streamLines(
                url: url, body: body, headers: headers, timing: timing)
            for try await line in lines {
                try Task.checkCancellation()
                for event in parser.consume(line: line) {
                    if case .completed(let evidence) = event { return .completed(timing.evidence(evidence)) }
                    if case .error(let error) = event { return .error(timing.error(error)) }
                    continuation.yield(event)
                }
            }
            try Task.checkCancellation()
            return .error(timing.error(.incompleteStream(parser.partialEvidence)))
        } catch { return .error(timing.error(Task.isCancelled ? .cancelled : requestError(error))) }
    }

    /// Map a transport failure onto the single-turn event error vocabulary.
    private static func requestError(_ error: any Error) -> MojenticError {
        switch error {
        case MojenticError.http(let status, let body):
            let detail = (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))) ?? .string(body)
            return .providerError(status: status, detail: detail)
        case MojenticError.transport(let message): return .requestFailed(message: message)
        case is CancellationError, MojenticError.cancelled: return .cancelled
        default: return .requestFailed(message: String(describing: error))
        }
    }
}
