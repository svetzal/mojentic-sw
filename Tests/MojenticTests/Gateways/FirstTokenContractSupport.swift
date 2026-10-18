import Foundation
import Mojentic
import Testing

struct FirstTokenCase: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let delta: JSONValue
    let kind: String?
    var testDescription: String { name }

    static func all() throws -> [Self] {
        struct Contract: Decodable {
            let version: String
            let cases: [FirstTokenCase]
        }
        let url = try #require(
            Bundle.module.url(
                forResource: "stream_first_token_v1",
                withExtension: "json",
                subdirectory: "Fixtures/Contracts"))
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        #expect(contract.version == "ex-stream-first-token-v1")
        return contract.cases
    }
}

struct FirstTokenOutcome: Sendable {
    var evidence: CompletionEvidence?
    var failure: (any Error)?
    var terminal = "missing"
    var content = ""
    var tools: [LLMToolCall] = []

    mutating func record(_ event: GatewayStreamEvent) {
        switch event {
        case .textDelta(let text): content += text
        case .toolCallRequest(let call): tools.append(call)
        case .done(_, _, let evidence):
            self.evidence = evidence
            terminal = "done"
        default: break
        }
    }

    mutating func record(_ event: RecoveryGatewayStreamEvent) {
        switch event {
        case .textDelta(let text): content += text
        case .toolCallRequest(let call): tools.append(call)
        case .done(_, _, let evidence):
            self.evidence = evidence
            terminal = "done"
        default: break
        }
    }

}

func timingNumber(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
}

func assertFirstToken(
    _ outcome: FirstTokenOutcome,
    kind: String?,
    terminal: String,
    minimum: Double = 0,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(outcome.terminal == terminal, sourceLocation: sourceLocation)
    let evidence = try #require(outcome.evidence, sourceLocation: sourceLocation)
    let metadata = try #require(evidence.metadata, sourceLocation: sourceLocation)
    let duration = try #require(timingNumber(metadata["request_duration_ms"]), sourceLocation: sourceLocation)
    #expect(duration >= minimum, sourceLocation: sourceLocation)
    if let kind {
        #expect(metadata["first_token_kind"] == .string(kind), sourceLocation: sourceLocation)
        let first = try #require(
            timingNumber(metadata["time_to_first_token_ms"]), sourceLocation: sourceLocation)
        #expect(first >= minimum, sourceLocation: sourceLocation)
        #expect(duration >= first, sourceLocation: sourceLocation)
    } else {
        #expect(metadata["first_token_kind"] == nil, sourceLocation: sourceLocation)
        #expect(metadata["time_to_first_token_ms"] == nil, sourceLocation: sourceLocation)
    }
}

/// Drives one stream to its terminal state and calls `onContent` each time content reaches the caller.
func firstTokenOutcome(
    _ boundary: StreamingBoundary,
    gateway: any LLMGateway,
    recovering: Bool,
    onContent: (@Sendable () -> Void)? = nil
) async throws -> FirstTokenOutcome {
    var result = FirstTokenOutcome()
    if boundary.single {
        if recovering {
            for await event in try gateway.completeStreamEventsRecovering(
                model: "fixture", messages: [], config: .init())
            {
                switch event {
                case .content(let text):
                    result.content += text
                    onContent?()
                case .completed(let evidence):
                    result.evidence = evidence
                    result.terminal = "completed"
                case .recoveryFailure(let error):
                    result.evidence = error.evidence
                    result.failure = error
                    result.terminal = error.outcome.rawValue
                case .error(.streamFailure(let error)):
                    result.evidence = error.evidence
                    result.failure = error.cause
                    result.terminal = "error"
                case .error: result.terminal = "untimed-error"
                default: break
                }
            }
        } else {
            result = try await legacyFirstTokenOutcome(gateway, onContent: onContent)
        }
    } else {
        do {
            if recovering {
                for try await event in gateway.streamRecovering(
                    model: "fixture", messages: [], tools: nil, config: .init())
                {
                    result.record(event)
                    if case .textDelta = event { onContent?() }
                }
            } else {
                for try await event in gateway.stream(
                    model: "fixture", messages: [], tools: nil, config: .init())
                {
                    result.record(event)
                    if case .textDelta = event { onContent?() }
                }
            }
        } catch let error as RecoveryError {
            result.evidence = error.evidence
            result.failure = error
            result.terminal = error.outcome.rawValue
        } catch let error as MojenticError {
            guard case .streamFailure(let failure) = error else { throw error }
            result.evidence = failure.evidence
            result.failure = failure.cause
            result.terminal = "throw"
        }
    }
    return result
}

private func legacyFirstTokenOutcome(
    _ gateway: any LLMGateway,
    onContent: (@Sendable () -> Void)?
) async throws -> FirstTokenOutcome {
    var result = FirstTokenOutcome()
    for await event in try gateway.completeStreamEvents(
        model: "fixture", messages: [], config: .init())
    {
        switch event {
        case .content(let text):
            result.content += text
            onContent?()
        case .completed(let evidence):
            result.evidence = evidence
            result.terminal = "completed"
        case .error(.streamFailure(let error)):
            result.evidence = error.evidence
            result.failure = error.cause
            result.terminal = "error"
        case .error: result.terminal = "untimed-error"
        }
    }
    return result
}
