/// Errors raised by the Mojentic library across gateways, tools, and the broker.
///
/// Every public API in `Mojentic` that can fail throws this single error type.
/// Phase 1 covers gateway transport errors, schema/decoding failures, tool
/// dispatch problems, and the broker's recursion-depth guard. Additional cases
/// will be added in later phases (tracer, agents, realtime).
public enum MojenticError: Error, Sendable, CustomStringConvertible {
    /// The gateway returned a non-success HTTP response.
    case http(status: Int, body: String)

    /// The gateway transport failed before a response was received.
    case transport(message: String)

    /// The gateway response could not be decoded into the expected shape.
    case decoding(message: String)

    /// JSON schema generation failed for the supplied type.
    case schema(message: String)

    /// A tool was requested by the model but no matching tool was registered.
    case toolNotFound(name: String)

    /// A tool raised while executing.
    case toolExecution(name: String, message: String)

    /// The broker's recursive tool-call loop exceeded `maxToolIterations`.
    case toolDepthExceeded(limit: Int)

    /// An agent's self-recursion exceeded its configured depth cap.
    case recursionDepthExceeded(limit: Int)

    /// The structured-output response could not be decoded into the requested type.
    case structuredDecoding(typeName: String, message: String)

    /// The current `Task` was cancelled before the operation completed.
    case cancelled

    /// An invariant required by the caller was violated (e.g. empty model name).
    case invalidArgument(message: String)

    /// A single-turn event stream ended with a terminal marker but a finish
    /// reason other than `stop`. Carries the provider's evidence.
    case incompleteCompletion(CompletionEvidence)

    /// A single-turn event stream ended without the provider's terminal
    /// marker. Carries whatever evidence arrived first; `nil` when none did.
    case incompleteStream(CompletionEvidence?)

    /// A single-turn event stream contained a native tool call. That API
    /// supplies no tools and executes none.
    case unexpectedToolCalls

    /// The provider reported an error in a single-turn event stream: an
    /// error frame (`status` is `nil`) or a non-2xx HTTP response (`status`
    /// is the HTTP status). `detail` is the reported payload.
    case providerError(status: Int?, detail: JSONValue)

    /// A single-turn event stream request failed: the connection or the body
    /// read failed.
    case requestFailed(message: String)

    /// A stream frame could not be parsed as the provider's event shape.
    case invalidStreamEvent(message: String)

    /// The gateway does not support single-turn event streams.
    case streamEventsUnsupported

    /// Human-readable representation of the error suitable for logging.
    public var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .transport(let message):
            return "Transport error: \(message)"
        case .decoding(let message):
            return "Decoding error: \(message)"
        case .schema(let message):
            return "Schema error: \(message)"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .toolExecution(let name, let message):
            return "Tool '\(name)' failed: \(message)"
        case .toolDepthExceeded(let limit):
            return "Tool-call recursion exceeded limit (\(limit))"
        case .recursionDepthExceeded(let limit):
            return "Agent recursion exceeded depth limit (\(limit))"
        case .structuredDecoding(let typeName, let message):
            return "Failed to decode structured output as \(typeName): \(message)"
        case .cancelled:
            return "Operation cancelled"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        case .incompleteCompletion(let evidence):
            return "Incomplete completion (finish reason: \(evidence.finishReason ?? "none"))"
        case .incompleteStream:
            return "Stream ended without a terminal marker"
        case .unexpectedToolCalls:
            return "Stream contained unexpected tool calls"
        case .providerError(let status, let detail):
            return "Provider error\(status.map { " (HTTP \($0))" } ?? ""): \(detail)"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .invalidStreamEvent(let message):
            return "Invalid stream event: \(message)"
        case .streamEventsUnsupported:
            return "Gateway does not support single-turn event streams"
        }
    }
}
