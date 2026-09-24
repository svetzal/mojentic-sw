import Foundation

/// The provider's own evidence about how a single-turn stream ended.
///
/// Every field is exactly what the provider reported, or `nil` when it
/// reported nothing. The library never estimates any of them.
public struct CompletionEvidence: Sendable, Hashable {
    /// Finish reason exactly as reported (OpenAI `finish_reason`, Ollama
    /// `done_reason`), for example `stop` or `length`.
    public let finishReason: String?

    /// Token usage as reported by the provider.
    public let usage: Usage?

    /// Model name the provider reported serving the request.
    public let providerModel: String?

    /// Provider response metadata as reported (ids, timestamps, durations).
    public let metadata: [String: JSONValue]?

    /// Create completion evidence.
    public init(
        finishReason: String? = nil,
        usage: Usage? = nil,
        providerModel: String? = nil,
        metadata: [String: JSONValue]? = nil
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

    /// Terminal failure. ``MojenticError/incompleteCompletion(_:)`` carries
    /// the provider's evidence; other cases describe what went wrong.
    case error(MojenticError)

    /// Whether this event ends the stream.
    public var isTerminal: Bool {
        if case .content = self { return false }
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
        parser: some CompletionEventParser
    ) -> AsyncStream<CompletionStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(
                    await relay(
                        transport: transport,
                        url: url,
                        body: body,
                        headers: headers,
                        parser: parser,
                        continuation: continuation
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
        continuation: AsyncStream<CompletionStreamEvent>.Continuation
    ) async -> CompletionStreamEvent {
        var parser = initial
        do {
            let lines = try await transport.streamLines(url: url, body: body, headers: headers)
            for try await line in lines {
                try Task.checkCancellation()
                for event in parser.consume(line: line) {
                    if event.isTerminal { return event }
                    continuation.yield(event)
                }
            }
            try Task.checkCancellation()
            return .error(.incompleteStream(parser.partialEvidence))
        } catch {
            return .error(Task.isCancelled ? .cancelled : requestError(error))
        }
    }

    /// Map a transport failure onto the single-turn event error vocabulary.
    private static func requestError(_ error: any Error) -> MojenticError {
        switch error {
        case MojenticError.http(let status, let body):
            let detail = (try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))) ?? .string(body)
            return .providerError(status: status, detail: detail)
        case MojenticError.transport(let message):
            return .requestFailed(message: message)
        case is CancellationError, MojenticError.cancelled:
            return .cancelled
        default:
            return .requestFailed(message: String(describing: error))
        }
    }
}
