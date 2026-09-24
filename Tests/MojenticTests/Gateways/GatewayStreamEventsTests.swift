import Foundation
import Testing

@testable import Mojentic

private let openAILines = [
    #"data: {"model":"gpt-4o-2024-08-06","#
        + #""choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#,
    #"data: {"model":"gpt-4o-2024-08-06","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
    #"data: {"model":"gpt-4o-2024-08-06","choices":[],"#
        + #""usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}"#,
    "data: [DONE]",
]

private let ollamaLines = [
    #"{"model":"qwen3:8b","message":{"role":"assistant","content":"Hi"},"done":false}"#,
    #"{"model":"qwen3:8b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","#
        + #""prompt_eval_count":5,"eval_count":1}"#,
]

@Suite("OpenAI gateway single-turn event stream")
struct OpenAIGatewayStreamEventsTests {
    private func gateway(_ transport: FakeLineTransport) -> OpenAIGateway {
        OpenAIGateway(apiKey: "k", lineTransport: transport)
    }

    @Test("one streaming request with usage requested, no tools, and the configured format")
    func requestBody() async throws {
        let transport = FakeLineTransport(lines: openAILines)
        _ = await collect(
            gateway(transport).completeStreamEvents(
                model: "gpt-4o",
                messages: [.user("hi")],
                config: CompletionConfig(responseFormat: .jsonObject)
            )
        )
        let bodies = await transport.recorder.bodies
        #expect(bodies.count == 1)
        let body = try #require(bodies.first?.objectValue)
        #expect(body["stream"] == .bool(true))
        #expect(body["stream_options"] == ["include_usage": true])
        #expect(body["tools"] == nil)
        #expect(body["response_format"] == ["type": "json_object"])
    }

    @Test("content then stop then DONE yields content then completed with usage")
    func completes() async {
        let seen = await collect(
            gateway(FakeLineTransport(lines: openAILines)).completeStreamEvents(
                model: "gpt-4o",
                messages: [.user("hi")],
                config: CompletionConfig()
            )
        )
        let evidence = CompletionEvidence(
            finishReason: "stop",
            usage: Usage(promptTokens: 5, completionTokens: 1, totalTokens: 6),
            providerModel: "gpt-4o-2024-08-06"
        )
        #expect(seen == [.content("Hi"), .completed(evidence)])
    }

    @Test("end of stream without DONE is an incomplete-stream error")
    func incompleteStream() async {
        let seen = await collect(
            gateway(FakeLineTransport(lines: Array(openAILines.dropLast()))).completeStreamEvents(
                model: "gpt-4o",
                messages: [.user("hi")],
                config: CompletionConfig()
            )
        )
        let partial = CompletionEvidence(
            finishReason: "stop",
            usage: Usage(promptTokens: 5, completionTokens: 1, totalTokens: 6),
            providerModel: "gpt-4o-2024-08-06"
        )
        #expect(seen == [.content("Hi"), .incompleteStream(partial)])
    }

    @Test("a non-2xx HTTP status is a provider error carrying the status")
    func httpFailure() async {
        let transport = FakeLineTransport(failure: .http(status: 429, body: #"{"error":"slow down"}"#))
        let seen = await collect(
            gateway(transport).completeStreamEvents(
                model: "gpt-4o", messages: [.user("hi")], config: CompletionConfig())
        )
        #expect(seen == [.providerError(status: 429, detail: ["error": "slow down"])])
    }

    @Test("a failed connection is a request-failed error")
    func connectionFailure() async {
        let transport = FakeLineTransport(failure: .transport(message: "connection refused"))
        let seen = await collect(
            gateway(transport).completeStreamEvents(
                model: "gpt-4o", messages: [.user("hi")], config: CompletionConfig())
        )
        #expect(seen == [.requestFailed])
    }

    @Test("stopping consumption early cancels the request", .timeLimit(.minutes(1)))
    func cancelsRequest() async {
        let transport = FakeLineTransport(lines: [openAILines[0]], holdOpen: true)
        // Iterate the temporary directly: an AsyncStream is terminated when
        // neither the stream value nor its iterator is referenced any more.
        for await event in gateway(transport).completeStreamEvents(
            model: "gpt-4o",
            messages: [.user("hi")],
            config: CompletionConfig()
        ) {
            #expect(SeenEvent(event) == .content("Hi"))
            break
        }
        await transport.recorder.waitForTermination()
        #expect(await transport.recorder.terminations == 1)
    }
}

@Suite("Ollama gateway single-turn event stream")
struct OllamaGatewayStreamEventsTests {
    private func gateway(_ transport: FakeLineTransport) -> OllamaGateway {
        OllamaGateway(lineTransport: transport)
    }

    @Test("one streaming request with no tools and the configured format")
    func requestBody() async throws {
        let transport = FakeLineTransport(lines: ollamaLines)
        _ = await collect(
            gateway(transport).completeStreamEvents(
                model: "qwen3",
                messages: [.user("hi")],
                config: CompletionConfig(responseFormat: .jsonObject)
            )
        )
        let bodies = await transport.recorder.bodies
        #expect(bodies.count == 1)
        let body = try #require(bodies.first?.objectValue)
        #expect(body["stream"] == .bool(true))
        #expect(body["tools"] == nil)
        #expect(body["format"] == "json")
    }

    @Test("content then a stop frame yields content then completed with usage")
    func completes() async {
        let seen = await collect(
            gateway(FakeLineTransport(lines: ollamaLines)).completeStreamEvents(
                model: "qwen3",
                messages: [.user("hi")],
                config: CompletionConfig()
            )
        )
        let evidence = CompletionEvidence(
            finishReason: "stop",
            usage: Usage(promptTokens: 5, completionTokens: 1, totalTokens: 6),
            providerModel: "qwen3:8b"
        )
        #expect(seen == [.content("Hi"), .completed(evidence)])
    }

    @Test("end of stream without a done frame is an incomplete-stream error")
    func incompleteStream() async {
        let seen = await collect(
            gateway(FakeLineTransport(lines: [ollamaLines[0]])).completeStreamEvents(
                model: "qwen3",
                messages: [.user("hi")],
                config: CompletionConfig()
            )
        )
        #expect(seen == [.content("Hi"), .incompleteStream(CompletionEvidence(providerModel: "qwen3:8b"))])
    }

    @Test("stopping consumption early cancels the request", .timeLimit(.minutes(1)))
    func cancelsRequest() async {
        let transport = FakeLineTransport(lines: [ollamaLines[0]], holdOpen: true)
        // Iterate the temporary directly: an AsyncStream is terminated when
        // neither the stream value nor its iterator is referenced any more.
        for await event in gateway(transport).completeStreamEvents(
            model: "qwen3",
            messages: [.user("hi")],
            config: CompletionConfig()
        ) {
            #expect(SeenEvent(event) == .content("Hi"))
            break
        }
        await transport.recorder.waitForTermination()
        #expect(await transport.recorder.terminations == 1)
    }
}

#if anthropic
    @Suite("Anthropic gateway single-turn event stream")
    struct AnthropicGatewayStreamEventsTests {
        @Test("reports unsupported before sending a request")
        func unsupported() {
            #expect(throws: MojenticError.self) {
                _ = try AnthropicGateway(apiKey: "k").completeStreamEvents(
                    model: "claude-sonnet-4-5",
                    messages: [.user("hi")],
                    config: CompletionConfig()
                )
            }
        }
    }
#endif
