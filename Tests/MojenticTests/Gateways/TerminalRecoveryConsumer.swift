import Foundation
@testable import Mojentic
import Testing

/// Only the paused task uses the iterator until it returns ownership to the test.
///
/// Both stream and the same iterator survive cancellation; reads never overlap.
final class TerminalRecoveryConsumer: @unchecked Sendable {
    private let read: () async throws -> String?
    private let retained: Any
    let metrics = RecoveryLocked<[CompletionEvidence]>([])

    init(_ stream: AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error>) {
        retained = stream
        var iterator = stream.makeAsyncIterator()
        let metrics = metrics
        read = {
            guard let event = try await iterator.next() else { return nil }
            switch event {
            case .textDelta(let value): return "content:\(value)"
            case .thinkingDelta(let value): return "reasoning:\(value)"
            case .progress: return "progress"
            case .metrics(let value):
                metrics.withLock { $0.append(value) }
                return "metrics"
            case .done: return "terminal"
            case .toolCallRequest: return "tool"
            }
        }
    }

    init(_ stream: AsyncStream<RecoveryCompletionStreamEvent>) {
        retained = stream
        var iterator = stream.makeAsyncIterator()
        let metrics = metrics
        read = {
            guard let event = await iterator.next() else { return nil }
            switch event {
            case .content(let value): return "content:\(value)"
            case .progress: return "progress"
            case .metrics(let value):
                metrics.withLock { $0.append(value) }
                return "metrics"
            case .completed: return "terminal"
            case .recoveryFailure(let failure): throw failure
            case .error(let failure): throw failure
            }
        }
    }

    init(_ stream: AsyncThrowingStream<StreamEvent, any Error>) {
        retained = stream
        var iterator = stream.makeAsyncIterator()
        read = {
            guard let event = try await iterator.next() else { return nil }
            switch event {
            case .textDelta(let value): return "content:\(value)"
            case .thinkingDelta(let value): return "reasoning:\(value)"
            case .done: return "terminal"
            case .toolCallRequested: return "tool"
            case .toolCallResult: return "tool-result"
            }
        }
    }

    func next() async throws -> String? {
        try await read()
    }
}

extension StreamingBoundary {
    func terminalElementType(path: String) -> String {
        if single {
            return "Mojentic.RecoveryCompletionStreamEvent"
        }
        if path == "gateway" {
            return "Mojentic.RecoveryGatewayStreamEvent"
        }
        return "Mojentic.StreamEvent"
    }

    func terminalOrder(path: String) -> [String] {
        var semantic = ["content:é"]
        if !single, !openAI {
            semantic = omlx ? ["reasoning:ré", "content:é"] : ["content:é", "reasoning:ré"]
        }
        if path != "gateway", !single {
            return semantic
        }
        if anthropic {
            return ["metrics"] + semantic + ["metrics"]
        }
        if openAI {
            return semantic + ["metrics"]
        }
        return omlx ? semantic : semantic + ["progress", "metrics"]
    }
}
