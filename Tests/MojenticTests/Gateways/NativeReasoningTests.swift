import Foundation
import Mojentic
import Testing

@Suite(.serialized)
struct NativeReasoningTests {
    @Test func booleanControlAndRetentionPreserveOtherTemplateOptions() async throws {
        let contract = try NativeReasoningContract()
        let server = try InProcessHTTPFixture(replies: [contract.reply(omlx: true, stream: false)])
        let gateway = OMLXGateway(host: server.url, session: server.session)
        _ = try await gateway.complete(
            model: "fixture",
            messages: [.user("go")],
            tools: nil,
            config: .init(
                reasoning: .disabled,
                retainThinking: true,
                extraOptions: ["chat_template_kwargs": ["custom_template_option": true]]))
        let bytes = try #require(server.requests.withLock { $0.first })
        let body = try JSONDecoder().decode(JSONValue.self, from: bytes)
        #expect(
            body.objectValue?["chat_template_kwargs"] == [
                "enable_thinking": false, "preserve_thinking": true, "custom_template_option": true,
            ])
    }

    @Test func completedToolHistoryCrossesHTTPBoundary() async throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "native_reasoning_v1", withExtension: "json", subdirectory: "Fixtures/Contracts"
            ))
        let contract = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtureURL))
        let fields = try #require(contract.objectValue)
        let message: JSONValue = [
            "role": "assistant", "content": fields["visible"] ?? .null,
            "reasoning_content": fields["reasoning"] ?? .null,
            "tool_calls": [fields["tool_call"] ?? .null],
        ]
        let reply: JSONValue = ["choices": [["message": message, "finish_reason": "tool_calls"]]]
        let final: JSONValue = [
            "choices": [
                [
                    "message": ["role": "assistant", "content": fields["answer"] ?? .null],
                    "finish_reason": "stop",
                ]
            ]
        ]
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(
                status: 200, body: try #require(String(data: JSONEncoder().encode(reply), encoding: .utf8))),
            RecoveryReply(
                status: 200, body: try #require(String(data: JSONEncoder().encode(final), encoding: .utf8))),
        ])
        let broker = LLMBroker(gateway: OMLXGateway(host: server.url, session: server.session))
        let response = try await broker.complete(
            model: "fixture",
            messages: [.user("go")],
            tools: [ContractCountTool(result: try #require(fields["tool_result"]))],
            config: .init(retainThinking: true))
        #expect(response.content == fields["answer"]?.stringValue)
        let requests = server.requests.withLock { $0 }
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last))
        let value = try #require(body.objectValue?["messages"])
        guard case .array(let messages) = value else {
            Issue.record("missing messages")
            return
        }
        #expect(messages[1].objectValue?["reasoning_content"] == fields["reasoning"])
        #expect(messages[1].objectValue?["content"] == fields["visible"])
        #expect(messages[2].objectValue?["tool_call_id"] == fields["tool_call"]?.objectValue?["id"])
    }
}
