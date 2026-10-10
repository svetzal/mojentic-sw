import Foundation
@testable import Mojentic
import Testing

@Suite("oMLX gateway chat request body")
struct OMLXChatRequestTests {
    private func sentBody(
        model: String = omlxFixtureModel,
        tools: [any LLMTool]? = nil,
        config: CompletionConfig,
    ) async throws -> [String: JSONValue] {
        let transport = try FakeRequestTransport(.fixture("chat_thinking_disabled.json"))
        _ = try await omlxGateway(transport).complete(
            model: model,
            messages: [.system("Be brief."), .user("hi")],
            tools: tools,
            config: config,
        )
        return try await jsonBody(transport.onlyRequest())
    }

    @Test("every configured field is sent, with no per-model adaptation")
    func fullBody() async throws {
        let config = CompletionConfig(
            temperature: 0.2,
            maxTokens: 512,
            topP: 0.9,
            reasoning: .high,
            numCtx: 8192,
            extraOptions: ["top_k": .integer(20)],
            responseFormat: .jsonObject,
        )
        let body = try await sentBody(tools: [ResolveDateTool()], config: config)
        #expect(body["model"] == .string(omlxFixtureModel))
        #expect(body["messages"] == .array(OpenAIMessageAdapter.adapt([.system("Be brief."), .user("hi")])))
        #expect(body["stream"] == false)
        #expect(body["temperature"] == .number(0.2))
        #expect(body["max_tokens"] == .integer(512))
        #expect(body["top_p"] == .number(0.9))
        #expect(body["top_k"] == .integer(20))
        #expect(body["reasoning_effort"] == "high")
        #expect(body["response_format"] == ["type": "json_object"])
        #expect(body["tools"] == [OpenAIMessageAdapter.tool(ResolveDateTool().descriptor)])
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["num_ctx"] == nil)
        #expect(body["num_predict"] == nil)
    }

    @Test("unset optional fields are omitted and max_tokens is always sent")
    func minimalBody() async throws {
        let body = try await sentBody(config: CompletionConfig())
        #expect(body["max_tokens"] == .integer(CompletionConfig().maxTokens))
        #expect(body["temperature"] == .number(1.0))
        #expect(body["top_p"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["response_format"] == nil)
        #expect(body["tools"] == nil)
    }

    @Test("reasoning effort is forwarded unchanged", arguments: [ReasoningEffort.low, .medium, .high])
    func reasoningEffort(effort: ReasoningEffort) async throws {
        let body = try await sentBody(config: CompletionConfig(reasoning: effort))
        #expect(body["reasoning_effort"] == .string(effort.rawValue))
    }

    @Test("a model name the OpenAI registry would treat as a reasoning model keeps every parameter")
    func noRegistryAdaptation() async throws {
        let body = try await sentBody(
            model: "o3-local-mlx",
            tools: [ResolveDateTool()],
            config: CompletionConfig(temperature: 0.3, maxTokens: 64, reasoning: .low),
        )
        #expect(body["model"] == "o3-local-mlx")
        #expect(body["temperature"] == .number(0.3))
        #expect(body["max_tokens"] == .integer(64))
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["reasoning_effort"] == "low")
        #expect(body["tools"] != nil)
    }
}

@Suite("oMLX gateway chat responses")
struct OMLXChatResponseTests {
    private func complete(
        _ fixture: String,
        messages: [LLMMessage] = [.user("hi")],
        tools: [any LLMTool]? = nil,
    ) async throws -> (LLMGatewayResponse, FakeRequestTransport) {
        let transport = try FakeRequestTransport(.fixture(fixture))
        let response = try await omlxGateway(transport).complete(
            model: omlxFixtureModel,
            messages: messages,
            tools: tools,
            config: CompletionConfig(),
        )
        return (response, transport)
    }

    @Test("reasoning_content maps to thinking, with usage and model as reported")
    func thinking() async throws {
        let (response, _) = try await complete("chat_thinking.json")
        #expect(response.content == "hello")
        let expectedThinking = #"""
            We need to reply exactly: hello. User said "Reply with exactly: hello". Need fin\#
            al "hello". Ensure no extra.
            """#
        #expect(response.thinking == expectedThinking)
        #expect(response.finishReason == .stop)
        #expect(response.providerFinishReason == "stop")
        #expect(response.providerModel == omlxFixtureModel)
        #expect(response.usage == Usage(promptTokens: 57, completionTokens: 30, totalTokens: 87))
    }

    @Test("oMLX's extra usage fields are kept, exactly as reported, in metadata")
    func rawUsage() async throws {
        let (response, _) = try await complete("chat_thinking.json")
        let metadata = try #require(response.metadata)
        #expect(metadata["id"] == "chatcmpl-8c2b3fa6")
        #expect(metadata["created"] == .integer(1_790_679_550))
        let usage = try #require(metadata["usage"]?.objectValue)
        #expect(usage["model_load_duration"] == .number(8.78))
        #expect(usage["prompt_tokens_details"] == ["cached_tokens": .integer(0)])
        #expect(usage["total_tokens"] == .integer(87))
    }

    @Test("a response without reasoning_content has nil thinking")
    func thinkingDisabled() async throws {
        let (response, _) = try await complete("chat_thinking_disabled.json")
        #expect(response.content == "hello")
        #expect(response.thinking == nil)
    }

    @Test("a tool call is parsed as the OpenAI gateway parses it")
    func toolCall() async throws {
        let (response, transport) = try await complete(
            "chat_tool_call.json",
            messages: [.user("What is today's date? Use the tool.")],
            tools: [ResolveDateTool()],
        )
        #expect(
            response.toolCalls == [
                LLMToolCall(id: "call_bd4d55c2", name: "resolve_date", arguments: ["relative": "today"])
            ]
        )
        #expect(response.finishReason == .toolCalls)
        #expect(response.content.isEmpty)
        #expect(response.thinking?.hasPrefix("The user is asking to use a tool") == true)
        let body = try await jsonBody(transport.onlyRequest())
        #expect(body["tools"] == [OpenAIMessageAdapter.tool(ResolveDateTool().descriptor)])
    }

    @Test("a tool result goes back as a tool message and the answer comes through")
    func toolResultRoundTrip()
        async throws
    {
        let call = LLMToolCall(id: "call_bd4d55c2", name: "resolve_date", arguments: ["relative": "today"])
        let messages: [LLMMessage] = [
            .user("What is today's date? Use the tool."), .assistant(toolCalls: [call]),
            .tool(callId: "call_bd4d55c2", content: #"{"date": "2026-09-29"}"#),
        ]
        let (response, transport) = try await complete(
            "chat_after_tool_result.json",
            messages: messages,
            tools: [ResolveDateTool()],
        )
        #expect(response.content == "Today's date is **September 29, 2026** (2026-09-29).")
        #expect(response.toolCalls.isEmpty)
        let sent = try await jsonBody(transport.onlyRequest())["messages"]
        #expect(sent == .array(OpenAIMessageAdapter.adapt(messages)))
        guard case .array(let sentMessages)? = sent else {
            Issue.record("expected a messages array")
            return
        }
        #expect(
            sentMessages.last == [
                "role": "tool", "content": #"{"date": "2026-09-29"}"#, "tool_call_id": "call_bd4d55c2",
            ]
        )
    }

    @Test("truncation during thinking maps to finish reason length with content unchanged")
    func truncated()
        async throws
    {
        let (response, _) = try await complete("chat_length.json")
        #expect(response.finishReason == .length)
        #expect(response.providerFinishReason == "length")
        #expect(response.content == "We need to respond to")
        #expect(response.thinking == nil)
    }

    @Test("an unknown model is a provider error carrying the status and the error body")
    func modelNotFound()
        async throws
    {
        let transport = try FakeRequestTransport(.fixture("error_model_not_found.json", status: 404))
        let failure = await httpFailure {
            _ = try await omlxGateway(transport).complete(
                model: "nope",
                messages: [.user("hi")],
                tools: nil,
                config: CompletionConfig(),
            )
        }
        #expect(failure?.status == 404)
        #expect(failure?.body.contains(#""type":"not_found_error""#) == true)
    }
}

@Suite("oMLX gateway structured output")
struct OMLXStructuredOutputTests {
    private let schema: JSONValue = [
        "type": "object", "properties": ["name": ["type": "string"], "age": ["type": "integer"]],
        "required": ["name", "age"],
    ]

    private func structured(
        headers: [HTTPHeader] = []
    ) async throws -> (StructuredGatewayResponse, FakeRequestTransport) {
        let transport = try FakeRequestTransport(.fixture("chat_json_schema.json", headers: headers))
        let response = try await omlxGateway(transport).completeStructured(
            model: omlxFixtureModel,
            messages: [.user("Ada, 36")],
            schema: schema,
            config: CompletionConfig(responseFormat: .text),
        )
        return (response, transport)
    }

    @Test("the schema is sent as a json_schema response format named response, without strict mode")
    func requestShape() async throws {
        let (response, transport) = try await structured()
        let body = try await jsonBody(transport.onlyRequest())
        #expect(
            body["response_format"] == [
                "type": "json_schema", "json_schema": ["name": "response", "schema": schema],
            ]
        )
        #expect(body["tools"] == nil)
        #expect(response.value == ["name": "Ada", "age": .integer(36)])
        #expect(response.response.providerModel == omlxFixtureModel)
        #expect(response.response.metadata?["response_format_warning"] == nil)
    }

    @Test("a Warning header is recorded in metadata, several joined with a comma")
    func warningHeader()
        async throws
    {
        let (response, _) = try await structured(headers: [
            HTTPHeader(name: "Warning", value: #"199 omlx "grammar not enforced""#),
            HTTPHeader(name: "warning", value: #"199 omlx "second""#),
        ])
        #expect(
            response.response.metadata?["response_format_warning"]
                == #"199 omlx "grammar not enforced", 199 omlx "second""#
        )
        #expect(response.value == ["name": "Ada", "age": .integer(36)])
    }

    @Test(
        "a requested JSON response format records the Warning header",
        arguments: [ResponseFormat.jsonObject, .jsonSchema(["type": "object"])],
    )
    func warningForJSONFormats(format: ResponseFormat) async throws {
        let metadata = try await completeMetadata(format: format)
        #expect(metadata?["response_format_warning"] == "199 omlx degraded")
    }

    @Test(
        "text or absent response formats ignore the Warning header",
        arguments: [ResponseFormat.text, nil],
    )
    func noWarningForText(format: ResponseFormat?) async throws {
        let metadata = try await completeMetadata(format: format)
        #expect(metadata?["response_format_warning"] == nil)
    }

    @Test("non-JSON content for structured output is a decoding error")
    func nonJSONContent() async throws {
        let transport = try FakeRequestTransport(.fixture("chat_thinking.json"))
        await #expect(throws: MojenticError.self) {
            _ = try await omlxGateway(transport).completeJSON(
                model: omlxFixtureModel,
                messages: [.user("hi")],
                schema: schema,
                config: CompletionConfig(),
            )
        }
    }

    private func completeMetadata(format: ResponseFormat?) async throws -> [String: JSONValue]? {
        let transport = try FakeRequestTransport(
            .fixture(
                "chat_json_schema.json",
                headers: [HTTPHeader(name: "Warning", value: "199 omlx degraded")],
            )
        )
        return try await omlxGateway(transport).complete(
            model: omlxFixtureModel,
            messages: [.user("hi")],
            tools: nil,
            config: CompletionConfig(responseFormat: format),
        ).metadata
    }
}
