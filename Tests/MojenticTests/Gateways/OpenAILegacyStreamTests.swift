import Foundation
@testable import Mojentic
import Testing

/// A comparable rendering of ``GatewayStreamEvent`` for assertions.
enum SeenGatewayEvent: Equatable {
    case text(String)
    case progress(RecoveryProgress)
    case metrics(CompletionEvidence)
    case thinking(String)
    case toolCall(LLMToolCall)
    case done(FinishReason?, Usage?)

    init(_ event: GatewayStreamEvent) {
        switch event {
        case .progress(let progress): self = .progress(progress)
        case .metrics(let evidence): self = .metrics(evidence)
        case .textDelta(let text): self = .text(text)
        case .thinkingDelta(let text): self = .thinking(text)
        case .toolCallRequest(let call): self = .toolCall(call)
        case .done(let reason, let usage): self = .done(reason, usage)
        }
    }
}

/// Collect every event a legacy gateway stream yields.
func collect(
    _ stream: AsyncThrowingStream<GatewayStreamEvent, any Error>
) async throws -> [SeenGatewayEvent] {
    var seen: [SeenGatewayEvent] = []
    for try await event in stream {
        seen.append(SeenGatewayEvent(event))
    }
    return seen
}

@Suite("OpenAI gateway legacy streaming")
struct OpenAILegacyStreamTests {
    private func stream(_ lines: [String]) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        OpenAIGateway(apiKey: "k", lineTransport: FakeLineTransport(lines: lines)).stream(
            model: "gpt-4o",
            messages: [.user("hi")],
            tools: nil,
            config: CompletionConfig(),
        )
    }

    @Test("text deltas, tool-call fragments and usage arrive as legacy events")
    func translatesChunks()
        async throws
    {
        let seen = try await collect(
            stream([
                ": keep-alive", #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"lo"}}]}"#,
                #"""
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"\#
                name":"lookup","arguments":"{\"q\":"}}]}}]}
                """#,
                #"""
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"argu\#
                ments":"\"x\"}"}}]}}]}
                """#,
                #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
                #"""
                data: {"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"\#
                total_tokens":6}}
                """#,
                "data: [DONE]", #"data: {"choices":[{"delta":{"content":"after done"}}]}"#,
            ])
        )
        #expect(
            seen == [
                .text("Hel"), .text("lo"),
                .toolCall(LLMToolCall(id: "call_1", name: "lookup", arguments: ["q": "x"])),
                .done(.toolCalls, Usage(promptTokens: 4, completionTokens: 2, totalTokens: 6)),
            ]
        )
    }

    @Test("reasoning deltas are not surfaced by the OpenAI gateway")
    func ignoresReasoning() async throws {
        let seen = try await collect(
            stream([
                #"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#, "data: [DONE]",
            ])
        )
        #expect(seen == [.text("ok"), .done(.stop, nil)])
    }

    @Test("malformed frames are skipped and a stream without DONE still ends with done")
    func toleratesMalformedFrames() async throws {
        let seen = try await collect(
            stream([
                "data: {not json", #"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
            ])
        )
        #expect(seen == [.text("ok"), .done(.stop, nil)])
    }
}
