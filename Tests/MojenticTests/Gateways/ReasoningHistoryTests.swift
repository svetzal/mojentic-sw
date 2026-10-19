import Foundation
import Mojentic
import Testing

@Suite(.serialized)
struct ReasoningHistoryTests {
    @Test
    func populatedHistorySurvivesStreamingRetry() async throws {
        let boundary = StreamingBoundary(omlx: true, single: false)
        let success = try RecoveryReply(body: boundary.frame(content: "recovered", done: true))
        let failed = RecoveryReply(status: 503, body: "original failure")
        let server = try InProcessHTTPFixture(replies: [failed, success])
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        let assistant = try JSONDecoder().decode(
            LLMMessage.self,
            from: Data(
                #"""
                {"role":"assistant","content":"original content","thinking":"reasoning é猫\nexact",
                "toolCalls":[{"id":"history-call","name":"resolve_date","arguments":{"relative":"tomorrow"}}]}
                """#.utf8
            ),
        )
        let messages: [LLMMessage] = [
            .user("original user"), assistant,
            .tool(callId: "history-call", content: "original result"), .user("continue"),
        ]
        var content = ""
        for try await event in boundary.gateway(server, policy).streamRecovering(
            model: "fixture", messages: messages, tools: [ResolveDateTool()], config: .init(),
        ) {
            if case .textDelta(let text) = event {
                content += text
            }
        }
        #expect(content == "recovered")
        let identities = try assertStatusWires(recorder, server: server, replies: [failed, success])
        for bytes in server.requests.withLock({ $0 }) {
            let root = try JSONDecoder().decode(JSONValue.self, from: bytes)
            guard case .array(let history) = root.objectValue?["messages"] else {
                Issue.record("Missing HTTP boundary history")
                return
            }
            try #require(history.count == 4)
            #expect(history[1].objectValue?["content"] == "original content")
            #expect(history[1].objectValue?["reasoning_content"] == "reasoning é猫\nexact")
            #expect(history[1].objectValue?["thinking"] == nil)
            #expect(history[1].objectValue?["tool_calls"] != nil)
            #expect(history[2].objectValue?["tool_call_id"] == "history-call")
            #expect(history[2].objectValue?["content"] == "original result")
            #expect(history[0].objectValue?["reasoning_content"] == nil)
            #expect(history[2].objectValue?["reasoning_content"] == nil)
            #expect(history[3].objectValue?["reasoning_content"] == nil)
        }
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition.rawValue) == [
                "attemptStarted", "attemptFailed", "admissionPending", "admissionAllowed", "delayScheduled",
                "retryStarted", "attemptStarted", "attemptSucceeded",
            ]
        )
        #expect(events.prefix(5).allSatisfy { $0.identity == identities[0] })
        #expect(events.suffix(3).allSatisfy { $0.identity == identities[1] })
        #expect(events.allSatisfy { $0.logicalID == identities[0].logicalID })
        let report = try #require(reports.withLock { $0.last })
        #expect(report.identity == identities[1])
        try #require(report.history.count == 1)
        try assertStatusFailure(report.history[0], identity: identities[0], reply: failed)
    }
}
