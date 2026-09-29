import Foundation
import Testing

@testable import Mojentic

private let keepAliveFrame =
    #"data: {"id":"chatcmpl-1","object":"chat.completion.chunk","created":0,"model":"keepalive","#
    + #""choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#

@Suite("oMLX keep-alive frames")
struct OMLXKeepAliveTests {
    @Test("a data line whose JSON model is exactly keepalive is a keep-alive frame")
    func keepAlive() {
        #expect(OMLXKeepAliveFilter.isKeepAlive(keepAliveFrame))
        #expect(OMLXKeepAliveFilter.isKeepAlive(#"data:{"model":"keepalive","choices":[]}"#))
    }

    @Test(
        "other lines pass through",
        arguments: [
            ": keep-alive",
            "",
            "data: [DONE]",
            #"data: {"model":"keepalive-2","choices":[]}"#,
            #"data: {"model":"Qwen","choices":[{"delta":{"content":"keepalive"}}]}"#,
            #"{"model":"keepalive"}"#,
            "data: {not json keepalive",
        ]
    )
    func passesThrough(line: String) {
        #expect(!OMLXKeepAliveFilter.isKeepAlive(line))
    }
}

@Suite("oMLX gateway single-turn event stream")
struct OMLXStreamEventsTests {
    private func events(_ lines: [String]) async -> [SeenEvent] {
        await collect(
            omlxGateway(lines: FakeLineTransport(lines: lines)).completeStreamEvents(
                model: omlxFixtureModel,
                messages: [.user("hi")],
                config: CompletionConfig()
            )
        )
    }

    @Test("one streaming request with usage requested and no tools")
    func requestBody() async throws {
        let transport = FakeLineTransport(lines: try OMLXFixture.lines("stream_thinking.sse"))
        _ = await collect(
            omlxGateway(lines: transport).completeStreamEvents(
                model: omlxFixtureModel,
                messages: [.user("hi")],
                config: CompletionConfig(maxTokens: 5)
            )
        )
        let bodies = await transport.recorder.bodies
        #expect(bodies.count == 1)
        let body = try #require(bodies.first?.objectValue)
        #expect(body["stream"] == true)
        #expect(body["stream_options"] == ["include_usage": true])
        #expect(body["max_tokens"] == .integer(5))
        #expect(body["tools"] == nil)
    }

    @Test("stream_thinking.sse yields its content then completes with the real model")
    func completes() async throws {
        let seen = await events(try OMLXFixture.lines("stream_thinking.sse"))
        let evidence = CompletionEvidence(
            finishReason: "stop",
            usage: Usage(promptTokens: 57, completionTokens: 30, totalTokens: 87),
            providerModel: omlxFixtureModel,
            metadata: ["id": "chatcmpl-05014002", "created": .integer(1_790_679_817)]
        )
        #expect(seen == [.content("\n\nhello"), .completed(evidence)])
    }

    @Test("stream_length.sse is an incomplete completion with the real model")
    func truncated() async throws {
        let seen = await events(try OMLXFixture.lines("stream_length.sse"))
        let evidence = CompletionEvidence(
            finishReason: "length",
            usage: Usage(promptTokens: 56, completionTokens: 5, totalTokens: 61),
            providerModel: omlxFixtureModel,
            metadata: ["id": "chatcmpl-6a79f6b7", "created": .integer(1_790_679_817)]
        )
        #expect(seen == [.incompleteCompletion(evidence)])
    }

    @Test("stream_tool_call.sse yields its content then an unexpected-tool-calls error")
    func toolCall() async throws {
        let seen = await events(try OMLXFixture.lines("stream_tool_call.sse"))
        #expect(seen == [.content("\n\n"), .unexpectedToolCalls])
    }

    @Test("a stream of only a keep-alive frame is an incomplete stream with no provider model")
    func onlyKeepAlive() async {
        let seen = await events([keepAliveFrame, ""])
        #expect(seen == [.incompleteStream(nil)])
    }

    @Test("a non-2xx status is a provider error carrying the status")
    func providerError() async throws {
        let body = try #require(
            String(bytes: try OMLXFixture.data("error_model_not_found.json"), encoding: .utf8))
        let seen = await collect(
            omlxGateway(lines: FakeLineTransport(failure: .http(status: 404, body: body)))
                .completeStreamEvents(
                    model: "nope",
                    messages: [.user("hi")],
                    config: CompletionConfig()
                )
        )
        guard case .providerError(let status, _)? = seen.first else {
            Issue.record("expected a provider error, got \(seen)")
            return
        }
        #expect(status == 404)
        #expect(seen.count == 1)
    }

    @Test("stopping consumption early cancels the request")
    func earlyStop() async {
        let transport = FakeLineTransport(lines: [keepAliveFrame], holdOpen: true)
        let stream = omlxGateway(lines: transport).completeStreamEvents(
            model: omlxFixtureModel,
            messages: [.user("hi")],
            config: CompletionConfig()
        )
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await transport.recorder.waitForTermination()
        #expect(await transport.recorder.terminations >= 1)
    }
}

@Suite("oMLX gateway legacy streaming")
struct OMLXLegacyStreamTests {
    private func stream(
        _ fixture: String,
        tools: [any LLMTool]? = nil
    ) async throws -> [SeenGatewayEvent] {
        let transport = FakeLineTransport(lines: try OMLXFixture.lines(fixture))
        return try await collect(
            omlxGateway(lines: transport).stream(
                model: omlxFixtureModel,
                messages: [.user("hi")],
                tools: tools,
                config: CompletionConfig()
            )
        )
    }

    private func thinking(_ seen: [SeenGatewayEvent]) -> String {
        let deltas = seen.compactMap { event -> String? in
            if case .thinking(let text) = event { return text }
            return nil
        }
        return deltas.joined()
    }

    @Test("stream_tool_call.sse yields its content then exactly one complete tool call")
    func toolCall() async throws {
        let seen = try await stream("stream_tool_call.sse", tools: [ResolveDateTool()])
        let visible = seen.filter { event in
            if case .thinking = event { return false }
            return true
        }
        #expect(
            visible == [
                .text("\n\n"),
                .toolCall(
                    LLMToolCall(id: "call_659d0e77", name: "resolve_date", arguments: ["relative": "today"])),
                .done(.toolCalls, Usage(promptTokens: 318, completionTokens: 60, totalTokens: 378)),
            ]
        )
    }

    @Test("reasoning_content deltas become thinking deltas, ahead of the content")
    func thinkingDeltas() async throws {
        let seen = try await stream("stream_thinking.sse")
        #expect(
            thinking(seen)
                == "\nWe need to reply exactly: hello. User said \"Reply with exactly: hello\". "
                + "Need final \"hello\". Ensure no extra.\n"
        )
        #expect(
            seen.suffix(2) == [
                .text("\n\nhello"),
                .done(.stop, Usage(promptTokens: 57, completionTokens: 30, totalTokens: 87)),
            ]
        )
        #expect(seen.first == .thinking("\nWe"))
    }

    @Test("a truncated stream keeps the partial reasoning as thinking and reports length")
    func truncated() async throws {
        let seen = try await stream("stream_length.sse")
        #expect(thinking(seen) == "\nWe need to respond to")
        #expect(seen.last == .done(.length, Usage(promptTokens: 56, completionTokens: 5, totalTokens: 61)))
    }
}
