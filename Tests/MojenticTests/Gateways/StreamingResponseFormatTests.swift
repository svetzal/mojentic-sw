import Foundation
import Testing

@testable import Mojentic

private let schema: JSONValue = [
    "type": "object",
    "properties": ["answer": ["type": "string"]],
]

private func openAIGateway(_ transport: FakeLineTransport) -> OpenAIGateway {
    OpenAIGateway(apiKey: "test-key", lineTransport: transport)
}

private func ollamaGateway(_ transport: FakeLineTransport) -> OllamaGateway {
    OllamaGateway(lineTransport: transport)
}

private func sentBody(
    through transport: FakeLineTransport,
    _ stream: AsyncThrowingStream<GatewayStreamEvent, any Error>
) async throws -> [String: JSONValue] {
    try await drain(stream)
    let bodies = await transport.recorder.bodies
    return try #require(bodies.first?.objectValue)
}

@Suite("Response format in OpenAI streaming requests")
struct OpenAIStreamingResponseFormatTests {
    private func streamedBody(format: ResponseFormat?) async throws -> [String: JSONValue] {
        let transport = FakeLineTransport()
        let stream = openAIGateway(transport).stream(
            model: "gpt-4o",
            messages: [.user("hi")],
            tools: nil,
            config: CompletionConfig(responseFormat: format)
        )
        return try await sentBody(through: transport, stream)
    }

    @Test("absent format leaves response_format out of the request")
    func absent() async throws {
        let body = try await streamedBody(format: nil)
        #expect(body["response_format"] == nil)
        #expect(body["stream"] == .bool(true))
    }

    @Test("text format sends type text")
    func text() async throws {
        let body = try await streamedBody(format: .text)
        #expect(body["response_format"] == ["type": "text"])
    }

    @Test("JSON object format sends type json_object")
    func jsonObject() async throws {
        let body = try await streamedBody(format: .jsonObject)
        #expect(body["response_format"] == ["type": "json_object"])
    }

    @Test("JSON schema format sends the schema under json_schema")
    func jsonSchema() async throws {
        let body = try await streamedBody(format: .jsonSchema(schema))
        let expected: JSONValue = [
            "type": "json_schema",
            "json_schema": ["name": "response", "schema": schema],
        ]
        #expect(body["response_format"] == expected)
    }
}

@Suite("Response format in Ollama streaming requests")
struct OllamaStreamingResponseFormatTests {
    private func streamedBody(format: ResponseFormat?) async throws -> [String: JSONValue] {
        let transport = FakeLineTransport()
        let stream = ollamaGateway(transport).stream(
            model: "qwen3",
            messages: [.user("hi")],
            tools: nil,
            config: CompletionConfig(responseFormat: format)
        )
        return try await sentBody(through: transport, stream)
    }

    @Test("absent format leaves format out of the request")
    func absent() async throws {
        let body = try await streamedBody(format: nil)
        #expect(body["format"] == nil)
        #expect(body["stream"] == .bool(true))
    }

    @Test("text format leaves format out of the request")
    func text() async throws {
        let body = try await streamedBody(format: .text)
        #expect(body["format"] == nil)
    }

    @Test("JSON object format sends format json")
    func jsonObject() async throws {
        let body = try await streamedBody(format: .jsonObject)
        #expect(body["format"] == "json")
    }

    @Test("JSON schema format sends the schema as format")
    func jsonSchema() async throws {
        let body = try await streamedBody(format: .jsonSchema(schema))
        #expect(body["format"] == schema)
    }
}

@Suite("ResponseFormat configuration")
struct ResponseFormatConfigTests {
    @Test("CompletionConfig defaults to no response format")
    func defaultIsAbsent() {
        #expect(CompletionConfig().responseFormat == nil)
    }

    @Test("CompletionConfig round-trips a schema response format via Codable")
    func codableRoundTrip() throws {
        let original = CompletionConfig(responseFormat: .jsonSchema(schema))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompletionConfig.self, from: data)
        #expect(decoded == original)
    }
}
