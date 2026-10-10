import Foundation
import Testing

@testable import Mojentic

struct StreamingRecoveryProtocolTests {
    @Test(arguments: StreamingBoundary.all, ["text", "tools", "done", "reason"])
    func malformedFramesHaveNoTelemetry(_ boundary: StreamingBoundary, _ field: String) async throws {
        let payload: String
        if boundary.omlx {
            switch field {
            case "text": payload = #"{"choices":[{"delta":{"content":123}}]}"#
            case "tools": payload = #"{"choices":[{"delta":{"tool_calls":"bad"}}]}"#
            case "done": payload = #"{"choices":"bad","usage":{"completion_tokens":12}}"#
            default:
                payload = #"{"choices":[{"delta":{},"finish_reason":123}],"usage":{"completion_tokens":12}}"#
            }
        } else {
            switch field {
            case "text": payload = #"{"message":{"content":123},"eval_count":12}"#
            case "tools":
                payload =
                    #"{"message":{"tool_calls":[{"function":{"name":"x","arguments":"bad"}}]},"#
                    + #""eval_count":12}"#
            case "done": payload = #"{"message":{},"done":"true","eval_count":12}"#
            default: payload = #"{"message":{},"done_reason":123,"eval_count":12}"#
            }
        }
        let body = boundary.omlx ? "data: \(payload)\n\n" : payload + "\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let seen = RecoveryLocked<[String]>([])
        let recorder = RecoveryRecorder()
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)), record: seen)
        }
        #expect(failure.outcome == .malformedResponse)
        #expect(!failure.failure.eligible)
        #expect(failure.failure.progress.observed == RecoverySemanticProgress())
        #expect(seen.withLock { $0.isEmpty })
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: StreamingBoundary.all)
    func invalidMetricCountsAreTypedFailures(_ boundary: StreamingBoundary) async throws {
        let body =
            boundary.omlx
            ? "data: {\"choices\":[],\"usage\":{\"completion_tokens\":-1}}\n\n"
            : "{\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":\(Int.max),\"eval_count\":1}\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let seen = RecoveryLocked<[String]>([])
        let failure = try await recoveryFailure {
            try await boundary.consume(
                boundary.gateway(server, recoveryPolicy(RecoveryRecorder())), record: seen)
        }
        #expect(failure.outcome == .malformedResponse)
        #expect(seen.withLock { $0.isEmpty })
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: StreamingBoundary.all)
    func safeFormattingAndTelemetryExcludeEchoes(_ boundary: StreamingBoundary) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: try boundary.frame(content: "é", done: true, metrics: true))
        ])
        let recorder = RecoveryRecorder()
        let gateway = boundary.gateway(server, recoveryPolicy(recorder))
        if boundary.single {
            for await event in try gateway.completeStreamEvents(
                model: "fixture", messages: [], config: .init())
            {
                #expect(!String(describing: event).contains("sentinel"))
                #expect(!String(reflecting: event).contains("sentinel"))
                if case .metrics(let evidence) = event {
                    #expect(evidence.providerModel == nil)
                    #expect(evidence.metadata?["created_at"] == nil)
                    #expect(evidence.metadata?["eval_duration"] == .integer(6_000_000_000))
                }
            }
        } else {
            for try await event in gateway.stream(model: "fixture", messages: [], tools: nil, config: .init())
            {
                #expect(!String(describing: event).contains("sentinel"))
                #expect(!String(reflecting: event).contains("sentinel"))
            }
        }
        let lifecycle = try JSONEncoder().encode(recorder.events.withLock { $0 })
        #expect(!(String(data: lifecycle, encoding: .utf8) ?? "").contains("sentinel"))
    }

    @Test(arguments: StreamingBoundary.all)
    func missingTerminalIsNeverSuccess(_ boundary: StreamingBoundary) async throws {
        let body = boundary.omlx ? ": keepalive\n\n" : "\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)))
        }
        #expect(failure.outcome == .ineligible)
        #expect(failure.failure.category == .protocolFailure)
        #expect(failure.failure.acceptance == .unknown)
        #expect(failure.failure.progress.rawBytes == body.utf8.count)
        #expect(server.requests.withLock { $0.count } == 1)
    }
}
