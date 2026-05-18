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
            throw MojenticError.invalidArgument(message: "no scripted responses left")
        }
        return responses.removeFirst()
    }
}

private struct SingleResponseGateway: LLMGateway {
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

@Suite("ToolWrapper")
struct ToolWrapperTests {
    @Test("nested broker call's tracer events nest under the parent context")
    func nestedTracerLinkage() async throws {
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        // Outer broker calls the wrapper tool; inner broker simulates the wrapped call.
        let summariserGateway = SingleResponseGateway(
            state: SingleResponseGatewayState(responses: [
                LLMGatewayResponse(content: "summary", finishReason: .stop)
            ])
        )
        let summariserBroker = LLMBroker(gateway: summariserGateway, tracer: tracer)
        let wrapper = ToolWrapper(
            broker: summariserBroker,
            model: "summariser",
            name: "summarise",
            description: "summarise input"
        )
        let parentToolCall = LLMToolCall(id: "1", name: "summarise", arguments: ["input": "long text"])
        let parentGateway = SingleResponseGateway(
            state: SingleResponseGatewayState(responses: [
                LLMGatewayResponse(
                    content: "",
                    toolCalls: [parentToolCall],
                    finishReason: .toolCalls
                ),
                LLMGatewayResponse(content: "done", finishReason: .stop),
            ])
        )
        let parentBroker = LLMBroker(gateway: parentGateway, tracer: tracer)
        let outerContext = TracerContext()
        _ = try await parentBroker.complete(
            model: "parent",
            messages: [.user("please summarise this")],
            tools: [wrapper],
            context: outerContext
        )

        let events = await store.events(correlatedTo: outerContext.correlationId)
        // The wrapped broker's llmCall must share the same correlationId.
        let nestedCall = events.first { event in
            if case .llmCall(let payload) = event, payload.model == "summariser" {
                return true
            }
            return false
        }
        guard let nested = nestedCall else {
            Issue.record("nested broker call did not show up under the correlation tree")
            return
        }
        if case .llmCall(let payload) = nested {
            #expect(payload.correlationId == outerContext.correlationId)
            #expect(payload.parentId != nil)
        }
    }
}
