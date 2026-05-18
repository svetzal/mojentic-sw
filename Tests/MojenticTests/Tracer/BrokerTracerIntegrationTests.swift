import Foundation
import Testing

@testable import Mojentic

private actor RecordingGatewayState {
    var responses: [LLMGatewayResponse]
    var invocations = 0

    init(responses: [LLMGatewayResponse]) {
        self.responses = responses
    }

    func next() throws -> LLMGatewayResponse {
        guard !responses.isEmpty else {
            throw MojenticError.invalidArgument(message: "no responses left")
        }
        invocations += 1
        return responses.removeFirst()
    }
}

private struct RecordingGateway: LLMGateway {
    let state: RecordingGatewayState

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

private struct EchoTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "echo",
        description: "echo",
        parameters: ["type": "object"]
    )

    func execute(arguments: JSONValue) async throws -> JSONValue { arguments }
}

@Suite("Broker tracer integration")
struct BrokerTracerIntegrationTests {
    @Test("emits llmCall + llmResponse with matching correlationId")
    func basicCorrelation() async throws {
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        let gateway = RecordingGateway(
            state: RecordingGatewayState(responses: [
                LLMGatewayResponse(content: "ok", finishReason: .stop)
            ])
        )
        let broker = LLMBroker(gateway: gateway, tracer: tracer)
        let context = TracerContext()
        _ = try await broker.complete(
            model: "test",
            messages: [.user("hi")],
            context: context
        )
        let events = await store.events(correlatedTo: context.correlationId)
        #expect(events.count == 2)
        let response = events.first { event in
            if case .llmResponse = event { return true }
            return false
        }
        #expect(response?.duration != nil)
    }

    @Test("tool calls nest under the dispatching llmResponse")
    func toolCallsNest() async throws {
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        let toolCall = LLMToolCall(id: "1", name: "echo", arguments: ["v": 1])
        let gateway = RecordingGateway(
            state: RecordingGatewayState(responses: [
                LLMGatewayResponse(content: "", toolCalls: [toolCall], finishReason: .toolCalls),
                LLMGatewayResponse(content: "done", finishReason: .stop),
            ])
        )
        let broker = LLMBroker(gateway: gateway, tracer: tracer)
        let context = TracerContext()
        _ = try await broker.complete(
            model: "test",
            messages: [.user("call echo")],
            tools: [EchoTool()],
            context: context
        )
        let events = await store.events(correlatedTo: context.correlationId)
        let firstResponseId = events.compactMap { event -> UUID? in
            guard case .llmResponse(let payload) = event else { return nil }
            return payload.id
        }
        .first
        #expect(firstResponseId != nil)
        let toolCallEvent = events.first { event in
            if case .toolCall = event { return true }
            return false
        }
        guard let event = toolCallEvent, case .toolCall(let payload) = event else {
            Issue.record("expected a toolCall event")
            return
        }
        #expect(payload.parentId == firstResponseId)
        #expect(payload.name == "echo")
    }
}
