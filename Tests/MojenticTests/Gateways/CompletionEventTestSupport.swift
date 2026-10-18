import Foundation
@testable import Mojentic
import Testing

/// A comparable rendering of ``CompletionStreamEvent`` for assertions.
enum SeenEvent: Equatable {
    case content(String)
    case completed(CompletionEvidence)
    case incompleteCompletion(CompletionEvidence)
    case incompleteStream(CompletionEvidence?)
    case unexpectedToolCalls
    case providerError(status: Int?, detail: JSONValue)
    case requestFailed
    case invalidStreamEvent
    case streamEventsUnsupported
    case cancelled
    case otherError(String)

    init(_ event: CompletionStreamEvent) {
        switch event {
        case .content(let text): self = .content(text)
        case .completed(let evidence): self = .completed(providerEvidence(evidence))
        case .error(let error): self = SeenEvent(error)
        }
    }

    private init(_ error: MojenticError) {
        if case .streamFailure(let failure) = error, let original = failure.cause as? MojenticError {
            self = SeenEvent(original)
            return
        }
        switch error {
        case .incompleteCompletion(let evidence): self = .incompleteCompletion(evidence)
        case .incompleteStream(let evidence): self = .incompleteStream(evidence)
        case .unexpectedToolCalls: self = .unexpectedToolCalls
        case .providerError(let status, let detail): self = .providerError(status: status, detail: detail)
        case .requestFailed: self = .requestFailed
        case .invalidStreamEvent: self = .invalidStreamEvent
        case .streamEventsUnsupported: self = .streamEventsUnsupported
        case .cancelled: self = .cancelled
        default: self = .otherError(error.description)
        }
    }
}

/// Collect every event a completion stream yields.
func collect(_ stream: AsyncStream<CompletionStreamEvent>) async -> [SeenEvent] {
    var seen: [SeenEvent] = []
    for await event in stream {
        seen.append(SeenEvent(event))
    }
    return seen
}

/// Feed lines through a parser, stopping at the first terminal event as the
/// gateway does.
func parse(_ lines: [String], with initial: some CompletionEventParser) -> [SeenEvent] {
    var parser = initial
    var seen: [SeenEvent] = []
    for line in lines {
        let events = parser.consume(line: line)
        seen += events.map(SeenEvent.init)
        if parser.isTerminal {
            break
        }
    }
    return seen
}

/// Preserve provider-only baseline assertions while timing has its own HTTP contract suite.
func providerEvidence(_ value: CompletionEvidence) -> CompletionEvidence {
    var metadata = value.metadata ?? [:]
    for key in ["request_duration_ms", "time_to_first_token_ms", "first_token_kind"] {
        metadata.removeValue(forKey: key)
    }
    var result = CompletionEvidence(
        finishReason: value.finishReason,
        usage: value.usage,
        providerModel: value.providerModel,
        metadata: metadata.isEmpty ? nil : metadata)
    result.identity = value.identity
    result.frameIndex = value.frameIndex
    return result
}
