import Foundation
@testable import Mojentic
import Testing

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenRouteTests {
    @Test(arguments: StreamingBoundary.all, [false, true])
    func contentThinkingEmptyAndProviderMetrics(_ boundary: StreamingBoundary, _ recovery: Bool) async throws
    {
        for kind in ["thinking", "content", "empty"] {
            let body = try boundary.frame(
                content: kind == "content" ? "answer" : "",
                reasoning: kind == "thinking" ? "thought" : "",
                done: true,
                metrics: true)
            let server = try InProcessHTTPFixture(replies: [RecoveryReply(body: body)])
            let result = try await firstTokenOutcome(
                boundary,
                gateway: boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil),
                recovering: recovery)
            try assertFirstToken(
                result, kind: kind == "empty" ? nil : kind, terminal: boundary.single ? "completed" : "done")
            #expect(result.content == (kind == "content" ? "answer" : ""), "\(boundary)/\(kind)")
            #expect(result.evidence?.finishReason == "stop")
            #expect(result.evidence?.usage?.completionTokens == 12, "\(boundary)/\(kind)")
            if !boundary.omlx {
                #expect(result.evidence?.metadata?["eval_duration"] == .integer(6_000_000_000))
            }
        }
    }

    @Test(arguments: try FirstTokenCase.all())
    func executableContractThroughHTTP(_ row: FirstTokenCase) async throws {
        let boundary = StreamingBoundary(omlx: true, single: true, openAI: true)
        let json = try JSONEncoder().encode(JSONValue.object(["choices": [["delta": row.delta]]]))
        let frame = "data: " + (try #require(String(bytes: json, encoding: .utf8))) + "\n\n"
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(body: frame + boundary.frame(done: true))
        ])
        let outcome = try await firstTokenOutcome(
            boundary,
            gateway: boundary.gateway(server, nil),
            recovering: false)
        let hasTool: Bool
        if case .object(let delta) = row.delta {
            hasTool = delta["tool_calls"] != nil || delta["function_call"] != nil
        } else {
            hasTool = false
        }
        try assertFirstToken(outcome, kind: row.kind, terminal: hasTool ? "error" : "completed")
    }

    @Test(arguments: StreamingBoundary.all, [false, true])
    func failuresBeforeAndAfterContent(_ boundary: StreamingBoundary, _ recovery: Bool) async throws {
        for content in [false, true] {
            let body = content ? try boundary.frame(content: "partial") : "\n"
            // Legacy streams have no delivery report, so the fixture releases the close only after
            // the caller sees the content; Apple URLSession can otherwise discard a partial body
            // that arrives with EOF.
            let server = try InProcessHTTPFixture(replies: [
                RecoveryReply(body: body, truncated: true, hold: content)
            ])
            defer { server.release() }
            var policy = recoveryPolicy(RecoveryRecorder())
            policy.maximumAttempts = 1
            let outcome = try await firstTokenOutcome(
                boundary,
                gateway: boundary.gateway(server, recovery ? policy : nil),
                recovering: recovery,
                onContent: server.release)
            let terminal =
                recovery ? (content ? "interrupted" : "exhausted") : boundary.single ? "error" : "throw"
            try assertFirstToken(outcome, kind: content ? "content" : nil, terminal: terminal)
            #expect(outcome.content == (content ? "partial" : ""))
        }
    }

    @Test(arguments: [false, true])
    func omlxKeepaliveNeverCounts(_ recovery: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: true)
        let keepalive =
            "data: {\"model\":\"keepalive\",\"choices\":[{\"delta\":{\"content\":\"ignored\"}}]}\n\n"
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(body: keepalive + boundary.frame(done: true))
        ])
        let outcome = try await firstTokenOutcome(
            boundary,
            gateway: boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil),
            recovering: recovery)
        try assertFirstToken(outcome, kind: nil, terminal: "completed")
        #expect(outcome.content.isEmpty)
        #expect(outcome.evidence?.providerModel != "keepalive")
    }
}
