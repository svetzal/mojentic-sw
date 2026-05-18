import Foundation
import Testing

@testable import Mojentic

private actor SingleResponseGatewayState {
    var responses: [LLMGatewayResponse]
    init(responses: [LLMGatewayResponse]) {
        self.responses = responses
    }
    func next() throws -> LLMGatewayResponse {
        guard !responses.isEmpty else {
            throw MojenticError.invalidArgument(message: "out of responses")
        }
        return responses.removeFirst()
    }
}

private struct ScriptedGateway: LLMGateway {
    let state: SingleResponseGatewayState
    func complete(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        try await state.next()
    }
    func completeJSON(
        model _: String,
        messages _: [LLMMessage],
        schema _: JSONValue,
        config _: CompletionConfig
    ) async throws -> JSONValue { .object([:]) }
    func availableModels() async throws -> [String] { [] }
    func stream(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

@Suite("AsyncLLMAgent")
struct AsyncLLMAgentTests {
    @Test("text events become broker completions and produce LLMResponseEvents")
    func handleTextEvent() async throws {
        let state = SingleResponseGatewayState(responses: [
            LLMGatewayResponse(content: "the moon", finishReason: .stop)
        ])
        let broker = LLMBroker(gateway: ScriptedGateway(state: state))
        let agent = AsyncLLMAgent(
            broker: broker,
            model: "test",
            systemPrompt: "be brief"
        )
        let correlation = UUID()
        let events = try await agent.handle(
            TextEvent(content: "tell me about the moon", correlationId: correlation)
        )
        #expect(events.count == 1)
        let response = events.first as? LLMResponseEvent
        #expect(response?.response.content == "the moon")
        #expect(response?.correlationId == correlation)
    }

    @Test("incoming correlation propagates into the broker's tracer events")
    func correlationPropagation() async throws {
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        let state = SingleResponseGatewayState(responses: [
            LLMGatewayResponse(content: "ok", finishReason: .stop)
        ])
        let broker = LLMBroker(gateway: ScriptedGateway(state: state), tracer: tracer)
        let agent = AsyncLLMAgent(broker: broker, model: "test")
        let correlation = UUID()
        _ = try await agent.handle(
            TextEvent(content: "hello", correlationId: correlation)
        )
        let events = await store.events(correlatedTo: correlation)
        // Expect an llmCall + llmResponse, both sharing the agent's correlation id.
        #expect(events.count == 2)
    }
}
