import Foundation
import Testing

@testable import Mojentic

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Suite("OpenAI provider evidence")
struct OpenAIProviderEvidenceTests {
    @Test("non-streaming response carries reported provider model and metadata")
    func completeEvidence() throws {
        let wire = try decode(
            OpenAIChatResponse.self,
            #"{"id":"chatcmpl-1","created":1700000001,"model":"gpt-4o-2024-08-06","#
                + #""choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"#
                + #""usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}"#
        )
        let response = wire.toGatewayResponse()
        #expect(response.providerModel == "gpt-4o-2024-08-06")
        #expect(response.usage == Usage(promptTokens: 3, completionTokens: 1, totalTokens: 4))
        #expect(response.metadata == ["id": "chatcmpl-1", "created": .integer(1_700_000_001)])
    }

    @Test("a response without usage leaves usage and metadata nil")
    func completeNoUsage() throws {
        let wire = try decode(
            OpenAIChatResponse.self,
            #"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#
        )
        let response = wire.toGatewayResponse()
        #expect(response.usage == nil)
        #expect(response.providerModel == nil)
        #expect(response.metadata == nil)
    }
}

@Suite("Ollama provider evidence")
struct OllamaProviderEvidenceTests {
    private static let finalFrame =
        #"{"model":"qwen3:8b","created_at":"2026-09-24T00:00:00Z","#
        + #""message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","#
        + #""total_duration":100,"load_duration":10,"prompt_eval_count":5,"#
        + #""prompt_eval_duration":20,"eval_count":3,"eval_duration":30}"#

    private static let expectedMetadata: [String: JSONValue] = [
        "created_at": "2026-09-24T00:00:00Z",
        "total_duration": .integer(100),
        "load_duration": .integer(10),
        "prompt_eval_duration": .integer(20),
        "eval_duration": .integer(30),
    ]

    @Test("non-streaming response carries reported provider model and metadata")
    func completeEvidence() throws {
        let wire = try decode(OllamaChatResponse.self, Self.finalFrame)
        let response = wire.toGatewayResponse()
        #expect(response.providerModel == "qwen3:8b")
        #expect(response.usage == Usage(promptTokens: 5, completionTokens: 3, totalTokens: 8))
        #expect(response.metadata == Self.expectedMetadata)
    }

    @Test("a response without counts leaves usage nil")
    func completeNoUsage() throws {
        let wire = try decode(
            OllamaChatResponse.self,
            #"{"message":{"role":"assistant","content":"ok"},"done":true,"done_reason":"stop"}"#
        )
        let response = wire.toGatewayResponse()
        #expect(response.usage == nil)
        #expect(response.providerModel == nil)
        #expect(response.metadata == nil)
    }
}
