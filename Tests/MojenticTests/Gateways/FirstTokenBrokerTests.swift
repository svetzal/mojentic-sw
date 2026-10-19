import Foundation
@testable import Mojentic
import Testing

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenBrokerTests {
    @Test(arguments: StreamingBoundary.all.filter(\.single), [false, true])
    func brokerSingleTurnPreservesTimingAndProviderMetrics(
        _ boundary: StreamingBoundary, _ recovery: Bool
    ) async throws {
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(
                body: boundary.frame(
                    content: "answer", reasoning: "thought", done: true, metrics: true))
        ])
        let broker = LLMBroker(
            gateway: boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil))
        var result = FirstTokenOutcome()
        if recovery {
            for await event in broker.generateRecoveryStreamEvents(model: "fixture", messages: []) {
                if case .completed(let evidence) = event {
                    result.evidence = evidence
                    result.terminal = "completed"
                }
                if case .content(let text) = event { result.content += text }
            }
        } else {
            for await event in broker.generateStreamEvents(model: "fixture", messages: []) {
                if case .completed(let evidence) = event {
                    result.evidence = evidence
                    result.terminal = "completed"
                }
                if case .content(let text) = event { result.content += text }
            }
        }
        try assertFirstToken(result, kind: "thinking", terminal: "completed")
        #expect(result.content == "answer")
        #expect(result.evidence?.usage?.completionTokens == 12)
    }

    @Test(arguments: StreamingBoundary.all, [false, true])
    func httpRejectionRetainsStatusAndNoFirstToken(
        _ boundary: StreamingBoundary, _ recovery: Bool
    ) async throws {
        let server = try InProcessHTTPFixture(replies: [RecoveryReply(status: 503, body: "busy")])
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.maximumAttempts = 1
        let result = try await firstTokenOutcome(
            boundary, gateway: boundary.gateway(server, recovery ? policy : nil), recovering: recovery)
        try assertFirstToken(
            result, kind: nil, terminal: recovery ? "exhausted" : boundary.single ? "error" : "throw")
        #expect(server.requests.withLock { $0.count } == 1)
        if recovery {
            let failure = try #require(result.failure as? RecoveryError)
            #expect(failure.failure.status == 503)
            #expect(failure.history.count == 1)
            #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        } else if boundary.single {
            guard case .providerError(let status, let detail) = result.failure as? MojenticError else {
                Issue.record("Expected original typed provider rejection")
                return
            }
            #expect(status == 503)
            #expect(detail == .string("busy"))
        } else {
            guard case .http(let status, let body) = result.failure as? MojenticError else {
                Issue.record("Expected original typed HTTP rejection")
                return
            }
            #expect(status == 503)
            #expect(body == "busy")
        }
    }

    @Test(arguments: [false, true])
    func providerDurationsKeepOriginalUnits(_ recovery: Bool) async throws {
        let body =
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{"
            + "\"time_to_first_token\":0.25,\"prompt_eval_duration\":1.5,"
            + "\"generation_duration\":2.0,\"total_time\":3.5}}\n\n"
            + "data: [DONE]\n\n"
        let server = try InProcessHTTPFixture(replies: [RecoveryReply(body: body)])
        let boundary = StreamingBoundary(omlx: true, single: true)
        let gateway = boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil)
        let result = try await firstTokenOutcome(boundary, gateway: gateway, recovering: recovery)
        try assertFirstToken(result, kind: nil, terminal: "completed")
        let metadata = try #require(result.evidence?.metadata)
        #expect(metadata["time_to_first_token"] == .number(0.25))
        #expect(metadata["prompt_eval_duration"] == .number(1.5))
        #expect(metadata["generation_duration"]?.intValue == 2)
        #expect(metadata["total_time"] == .number(3.5))
    }

    @Test
    func olderResponseRecordsDecodeWithoutTiming() throws {
        let data = Data(#"{"content":"old answer","retainedMessages":[]}"#.utf8)
        let response = try JSONDecoder().decode(LLMResponse.self, from: data)
        #expect(response.content == "old answer")
        #expect(response.metadata == nil)
    }
}
