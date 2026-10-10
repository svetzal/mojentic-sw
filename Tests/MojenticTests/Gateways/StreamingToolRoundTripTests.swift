import Foundation
@testable import Mojentic
import Testing

/// Replays each HTTP stream in order and records its request body.
private actor ToolRoundTripLog {
    private var replies: [[String]]
    private(set) var bodies: [JSONValue] = []

    init(replies: [[String]]) {
        self.replies = replies
    }

    func nextReply(body: JSONValue) -> [String] {
        bodies.append(body)
        return replies.isEmpty ? [] : replies.removeFirst()
    }
}

private struct ToolRoundTripTransport: LineStreamingTransport {
    let log: ToolRoundTripLog

    init(replies: [[String]]) {
        log = ToolRoundTripLog(replies: replies)
    }

    func streamLines(
        url _: URL,
        body: some Encodable,
        headers _: [String: String],
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(body))
        let lines = await log.nextReply(body: value)
        return AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}

@Suite("Streaming tool-call ID round trip")
struct StreamingToolRoundTripTests {
    @Test(
        "a first-chunk ID survives later argument chunks and the broker follow-up",
        arguments: [false, true],
    )
    func carriesSplitChunkID(omlx: Bool) async throws {
        let transport = ToolRoundTripTransport(replies: [
            [
                #"""
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_split","function\#
                ":{"name":"resolve_date","arguments":""}}]}}]}
                """#,
                #"""
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\#
                "relative\":"}}]}}]}
                """#,
                #"""
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"argu\#
                ments":"\"today\"}"}}]}}]}
                """#,
                #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#, "data: [DONE]",
            ],
            [
                #"""
                data: {"choices":[{"delta":{"content":"Resolved today"},"finish_reason\#
                ":"stop"}]}
                """#,
                "data: [DONE]",
            ],
        ])
        let gateway: any LLMGateway =
            if omlx {
                OMLXGateway(
                    configuration: OMLXConfiguration(),
                    transport: FakeRequestTransport(),
                    lineTransport: transport,
                )
            } else {
                OpenAIGateway(apiKey: "test", lineTransport: transport)
            }
        let broker = LLMBroker(gateway: gateway)
        var calls: [LLMToolCall] = []
        var resultIDs: [String] = []
        var text = ""
        for try await event in broker.stream(
            model: omlx ? omlxFixtureModel : "gpt-4o",
            messages: [.user("Resolve today")],
            tools: [ResolveDateTool()],
        ) {
            switch event {
            case .toolCallRequested(let call): calls.append(call)
            case .toolCallResult(let id, _): resultIDs.append(id)
            case .textDelta(let delta): text += delta
            default: break
            }
        }
        #expect(
            calls == [LLMToolCall(id: "call_split", name: "resolve_date", arguments: ["relative": "today"])]
        )
        #expect(resultIDs == ["call_split"])
        #expect(text == "Resolved today")
        let bodies = await transport.log.bodies
        #expect(bodies.count == 2)
        guard case .array(let messages)? = bodies.last?.objectValue?["messages"] else {
            Issue.record("Expected follow-up messages")
            return
        }
        let assistant = try #require(messages.first { $0.objectValue?["role"] == "assistant" }?.objectValue)
        guard case .array(let sentCalls)? = assistant["tool_calls"] else {
            Issue.record("Expected assistant tool calls")
            return
        }
        #expect(sentCalls.first?.objectValue?["id"] == "call_split")
        let tool = try #require(messages.first { $0.objectValue?["role"] == "tool" }?.objectValue)
        #expect(tool["tool_call_id"] == "call_split")
        let content = try #require(tool["content"]?.stringValue?.data(using: .utf8))
        #expect(try JSONDecoder().decode(JSONValue.self, from: content) == ["relative": "today"])
    }
}
