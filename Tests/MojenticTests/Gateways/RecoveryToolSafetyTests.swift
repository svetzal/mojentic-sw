import Foundation
import Testing

@testable import Mojentic

final class RecoveryToolCounter: Sendable {
    let value = RecoveryLocked<Int>(0)
}

struct RecoveryCountingTool: LLMTool {
    let calls: RecoveryToolCounter
    var descriptor: ToolDescriptor { ResolveDateTool().descriptor }
    func execute(arguments: JSONValue) async throws -> JSONValue {
        #expect(arguments == ["relative": "tomorrow"])
        calls.value.withLock { $0 += 1 }
        return ["original-result": "tool-sentinel"]
    }
}

@Suite("Recovery through broker and session")
struct RecoveryToolSafetyTests {
    @Test(arguments: [false, true], [false, true])
    func completedToolSurvivesRecoveredFollowUp(_ omlx: Bool, _ session: Bool) async throws {
        let boundary = RecoveryBoundary(omlx: omlx, structured: false)
        let server = try RecoveryLoopback(replies: [
            try boundary.success(tools: true), RecoveryReply(status: 503, body: "busy"),
            try boundary.success(),
        ])
        let recorder = RecoveryRecorder()
        let count = RecoveryToolCounter()
        let broker = LLMBroker(gateway: boundary.gateway(server, policy: recoveryPolicy(recorder)))
        let tool = RecoveryCountingTool(calls: count)
        let config = CompletionConfig(maxToolIterations: 2)
        let result: LLMResponse
        if session {
            let chat = ChatSession(broker: broker, model: "fixture", tools: [tool], config: config)
            result = try await chat.send("original-user")
            #expect(await chat.messages().map(\.role) == [.user, .assistant])
        } else {
            result = try await broker.complete(
                model: "fixture",
                messages: [.user("original-user")],
                tools: [tool],
                config: config
            )
        }
        #expect(result.content == "recovered")
        #expect(count.value.withLock { $0 } == 1)
        let bodies = server.requests.withLock { $0 }
        #expect(bodies.count == 3)
        #expect(bodies[1] == bodies[2])
        let root = try JSONDecoder().decode(JSONValue.self, from: bodies[2])
        guard case .array(let messages) = root.objectValue?["messages"] else {
            Issue.record("Missing follow-up history")
            return
        }
        #expect(messages.count == 3)
        #expect(messages[0].objectValue?["content"] == "original-user")
        #expect(messages[1].objectValue?["role"] == "assistant")
        #expect(messages[1].objectValue?["tool_calls"] != nil)
        #expect(messages[2].objectValue?["role"] == "tool")
        let toolText = try #require(messages[2].objectValue?["content"]?.stringValue)
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: Data(toolText.utf8)) == [
                "original-result": "tool-sentinel"
            ]
        )
        if omlx { #expect(messages[2].objectValue?["tool_call_id"] == "original-tool") }
        let identities = recorder.requests.withLock { $0.map { $0.0 } }
        #expect(identities.map(\.wireNumber) == [1, 1, 2])
        #expect(identities[0].logicalID != identities[1].logicalID)
        #expect(identities[1].logicalID == identities[2].logicalID)
        #expect(identities[1].attemptID != identities[2].attemptID)
    }

    @Test(arguments: [false, true], [false, true])
    func failurePreservesTypedCauseAfterCompletedTool(_ omlx: Bool, _ session: Bool) async throws {
        let boundary = RecoveryBoundary(omlx: omlx, structured: false)
        let server = try RecoveryLoopback(replies: [
            try boundary.success(tools: true), RecoveryReply(body: " ", truncated: true),
        ])
        let count = RecoveryToolCounter()
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.admission = { _, _ in
            AsyncStream {
                $0.yield(.reject)
                $0.finish()
            }
        }
        let broker = LLMBroker(gateway: boundary.gateway(server, policy: policy))
        let tool = RecoveryCountingTool(calls: count)
        let failure = try await recoveryFailure {
            if session {
                let chat = ChatSession(broker: broker, model: "fixture", tools: [tool])
                _ = try await chat.send("original-user")
            } else {
                _ = try await broker.complete(
                    model: "fixture",
                    messages: [.user("original-user")],
                    tools: [tool]
                )
            }
        }
        #expect(failure.outcome == .admissionRejected)
        #expect(failure.failure.inspectEvidence().cause is URLError)
        #expect(count.value.withLock { $0 } == 1)
        #expect(server.requests.withLock { $0.count } == 2)
    }

    @Test(arguments: [false, true])
    func recoveryDoesNotResetToolDepth(_ omlx: Bool) async throws {
        let boundary = RecoveryBoundary(omlx: omlx, structured: false)
        let server = try RecoveryLoopback(replies: [
            try boundary.success(tools: true), RecoveryReply(status: 503, body: "busy"),
            try boundary.success(tools: true),
        ])
        let count = RecoveryToolCounter()
        let broker = LLMBroker(gateway: boundary.gateway(server, policy: recoveryPolicy(RecoveryRecorder())))
        do {
            _ = try await broker.complete(
                model: "fixture",
                messages: [.user("original-user")],
                tools: [RecoveryCountingTool(calls: count)],
                config: CompletionConfig(maxToolIterations: 2)
            )
            Issue.record("Expected tool depth failure")
        } catch MojenticError.toolDepthExceeded(let limit) {
            #expect(limit == 2)
        }
        #expect(count.value.withLock { $0 } == 2)
        #expect(server.requests.withLock { $0.count } == 3)
    }
}
