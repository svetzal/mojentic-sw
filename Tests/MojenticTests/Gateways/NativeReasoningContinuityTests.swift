import Foundation
import Mojentic
import Testing

struct NativeReasoningContinuityTests {
    @Test(arguments: [false, true], [false, true])
    func completedMultipleToolCallsAndSessionHistory(
        omlx: Bool,
        stream: Bool
    ) async throws {
        let contract = try NativeReasoningContract()
        let server = try RecoveryLoopback(replies: [
            contract.reply(
                omlx: omlx,
                stream: stream,
                tools: true),
            contract.reply(
                omlx: omlx,
                stream: stream),
            contract.reply(
                omlx: omlx,
                stream: stream),
        ])
        let gateway = RecoveryBoundary(
            omlx: omlx,
            structured: false
        ).gateway(
            server,
            policy: .init())
        let session = ChatSession(
            broker: LLMBroker(gateway: gateway),
            model: "fixture",
            tools: [ContractCountTool(result: try #require(contract.fields["tool_result"]))],
            config: .init(
                reasoning: .xhigh,
                reasoningProfile: .qwen38,
                retainThinking: true))
        if stream {
            var visible = ""
            for try await event in session.stream("go") {
                if case .textDelta(let delta) = event { visible += delta }
            }
            #expect(visible == "checkinganswer")
        } else {
            let response = try await session.send("go")
            #expect(response.content == contract.fields["answer"]?.stringValue)
        }
        let history = await session.messages()
        #expect(history.map(\.role) == [.user, .assistant, .tool, .tool, .assistant])
        #expect(history[1].thinking == contract.fields["reasoning"]?.stringValue)
        #expect(history[1].content == contract.fields["visible"]?.stringValue)
        #expect(history[1].toolCalls?.map(\.name) == ["count", "count"])
        #expect(history[2].thinking == nil)
        #expect(history[3].thinking == nil)
        #expect(history[4].thinking == contract.fields["reasoning"]?.stringValue)
        if omlx { #expect(history[1].toolCalls?.map(\.id) == ["call-native", "call-native-2"]) }
        if stream {
            for try await _ in session.stream("next") {}
        } else {
            _ = try await session.send("next")
        }
        let requests = server.requests.withLock { $0 }
        let second = try messages(requests[1])
        let third = try messages(requests[2])
        #expect(second.count == 4)
        #expect(third.count == 6)
        let key = omlx ? "reasoning_content" : "thinking"
        #expect(second[1].objectValue?[key] == contract.fields["reasoning"])
        #expect(second[1].objectValue?["content"] == contract.fields["visible"])
        #expect(third[4].objectValue?[key] == contract.fields["reasoning"])
        #expect(second[2].objectValue?[key] == nil)
        #expect(second[3].objectValue?[key] == nil)
        #expect(second[2].objectValue?["content"]?.stringValue?.contains("tool-result-secret") == true)
        if omlx {
            #expect(second[2].objectValue?["tool_call_id"] == "call-native")
            #expect(second[3].objectValue?["tool_call_id"] == "call-native-2")
        }
        let row = try #require(contract.controls.last)
        try contract.assertControls(
            server,
            omlx: omlx,
            row: row,
            retain: true)
    }

    @Test(arguments: [false, true])
    func retentionIsOptIn(omlx: Bool) async throws {
        let contract = try NativeReasoningContract()
        let server = try RecoveryLoopback(replies: [
            contract.reply(
                omlx: omlx,
                stream: false)
        ])
        let session = ChatSession(
            broker: LLMBroker(
                gateway: RecoveryBoundary(
                    omlx: omlx,
                    structured: false
                )
                .gateway(
                    server,
                    policy: nil)),
            model: "fixture")
        let response = try await session.send("go")
        #expect(response.thinking == contract.fields["reasoning"]?.stringValue)
        #expect(await session.messages().last?.thinking == nil)
        #expect(response.retainedMessages.isEmpty)
    }

    @Test(arguments: [false, true])
    func failedContinuationNeverCommitsNativeHistory(omlx: Bool) async throws {
        let contract = try NativeReasoningContract()
        let server = try RecoveryLoopback(replies: [
            contract.reply(
                omlx: omlx,
                stream: true,
                tools: true),
            RecoveryReply(status: 400, body: "failed continuation"),
        ])
        let gateway = RecoveryBoundary(
            omlx: omlx,
            structured: false
        ).gateway(
            server,
            policy: .init())
        let session = ChatSession(
            broker: LLMBroker(gateway: gateway),
            model: "fixture",
            tools: [ContractCountTool(result: try #require(contract.fields["tool_result"]))],
            config: .init(retainThinking: true))
        await #expect(throws: (any Error).self) {
            for try await _ in session.stream("go") {}
        }
        #expect(await session.messages().isEmpty)
    }

    private func messages(_ bytes: Data) throws -> [JSONValue] {
        let body = try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard case .array(let messages) = body.objectValue?["messages"] else {
            Issue.record("Missing native history")
            return []
        }
        return messages
    }
}
