import Foundation
import Testing

@testable import Mojentic

private let reportedUsage = Usage(promptTokens: 12, completionTokens: 34, totalTokens: 46)
private let reportedMetadata: [String: JSONValue] = [
    "id": "chatcmpl-1",
    "system_fingerprint": "fp_abc",
]

/// Gateway that returns the same scripted evidence from every entry point.
private struct EvidenceGateway: LLMGateway {
    let response: LLMGatewayResponse

    func complete(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) async throws -> LLMGatewayResponse { response }

    func completeJSON(
        model _: String,
        messages _: [LLMMessage],
        schema _: JSONValue,
        config _: CompletionConfig
    ) async throws -> JSONValue { ["answer": "42"] }

    func completeStructured(
        model _: String,
        messages _: [LLMMessage],
        schema _: JSONValue,
        config _: CompletionConfig
    ) async throws -> StructuredGatewayResponse {
        StructuredGatewayResponse(value: ["answer": "42"], response: response)
    }

    func availableModels() async throws -> [String] { [] }

    func stream(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct Answer: Codable, Sendable, JSONSchemaProviding {
    let answer: String

    static let jsonSchema: JSONValue = [
        "type": "object",
        "properties": ["answer": ["type": "string"]],
    ]
}

private func responsePayloads(in store: EventStore, _ context: TracerContext) async -> [LLMResponsePayload] {
    await store.events(correlatedTo: context.correlationId).compactMap { event in
        guard case .llmResponse(let payload) = event else { return nil }
        return payload
    }
}

private func evidenceBroker(_ response: LLMGatewayResponse) -> (LLMBroker, EventStore) {
    let store = EventStore()
    let broker = LLMBroker(
        gateway: EvidenceGateway(response: response),
        tracer: EventStoreTracer(store: store)
    )
    return (broker, store)
}

private let evidence = LLMGatewayResponse(
    content: "{\"answer\":\"42\"}",
    finishReason: .stop,
    usage: reportedUsage,
    providerFinishReason: "stop",
    providerModel: "gpt-4o-2024-08-06",
    metadata: reportedMetadata
)

@Suite("Provider evidence in response traces")
struct ResponseEvidenceTracerTests {
    @Test("ordinary completion records reported evidence unchanged")
    func ordinary() async throws {
        let (broker, store) = evidenceBroker(evidence)
        let context = TracerContext()
        _ = try await broker.complete(model: "gpt-4o", messages: [.user("hi")], context: context)

        let payload = try #require(await responsePayloads(in: store, context).first)
        #expect(payload.model == "gpt-4o")
        #expect(payload.usage == reportedUsage)
        #expect(payload.providerModel == "gpt-4o-2024-08-06")
        #expect(payload.finishReason == "stop")
        #expect(payload.metadata == reportedMetadata)
    }

    @Test("structured completion records reported evidence and raw content")
    func structured() async throws {
        let (broker, store) = evidenceBroker(evidence)
        let context = TracerContext()
        let answer = try await broker.completeJSON(
            model: "gpt-4o",
            messages: [.user("hi")],
            responseType: Answer.self,
            context: context
        )
        #expect(answer.answer == "42")

        let payload = try #require(await responsePayloads(in: store, context).first)
        #expect(payload.model == "gpt-4o")
        #expect(payload.response.content == "{\"answer\":\"42\"}")
        #expect(payload.usage == reportedUsage)
        #expect(payload.providerModel == "gpt-4o-2024-08-06")
        #expect(payload.finishReason == "stop")
        #expect(payload.metadata == reportedMetadata)
    }

    @Test("an unknown provider finish reason survives into the trace unchanged")
    func unknownFinishReason() async throws {
        let (broker, store) = evidenceBroker(
            LLMGatewayResponse(content: "", finishReason: .other, providerFinishReason: "load")
        )
        let context = TracerContext()
        _ = try await broker.complete(model: "m", messages: [.user("hi")], context: context)

        let payload = try #require(await responsePayloads(in: store, context).first)
        #expect(payload.finishReason == "load")
        #expect(payload.response.finishReason == .other)
    }

    @Test("a gateway that reports no usage produces a response event with nil usage")
    func noUsage() async throws {
        let (broker, store) = evidenceBroker(LLMGatewayResponse(content: "ok"))
        let context = TracerContext()
        _ = try await broker.complete(model: "m", messages: [.user("hi")], context: context)

        let payload = try #require(await responsePayloads(in: store, context).first)
        #expect(payload.usage == nil)
        #expect(payload.providerModel == nil)
        #expect(payload.finishReason == nil)
        #expect(payload.metadata == nil)
    }

    @Test("a gateway without completeStructured still traces the structured call")
    func structuredDefault() async throws {
        struct PlainGateway: LLMGateway {
            func complete(
                model _: String,
                messages _: [LLMMessage],
                tools _: [any LLMTool]?,
                config _: CompletionConfig
            ) async throws -> LLMGatewayResponse { LLMGatewayResponse(content: "") }

            func completeJSON(
                model _: String,
                messages _: [LLMMessage],
                schema _: JSONValue,
                config _: CompletionConfig
            ) async throws -> JSONValue { ["answer": "7"] }

            func availableModels() async throws -> [String] { [] }

            func stream(
                model _: String,
                messages _: [LLMMessage],
                tools _: [any LLMTool]?,
                config _: CompletionConfig
            ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let store = EventStore()
        let broker = LLMBroker(gateway: PlainGateway(), tracer: EventStoreTracer(store: store))
        let context = TracerContext()
        let answer = try await broker.completeJSON(
            model: "m",
            messages: [.user("hi")],
            responseType: Answer.self,
            context: context
        )
        #expect(answer.answer == "7")
        let payload = try #require(await responsePayloads(in: store, context).first)
        #expect(payload.usage == nil)
        #expect(payload.response.content == "{\"answer\":\"7\"}")
    }
}
