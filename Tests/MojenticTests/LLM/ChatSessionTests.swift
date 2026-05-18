import Foundation
import Testing

@testable import Mojentic

/// Actor-isolated state for the broker-backing fake gateway.
private actor ScriptedGatewayState {
    var responses: [LLMGatewayResponse]
    var streamScripts: [[GatewayStreamEvent]]
    var invocations: [[LLMMessage]] = []
    var errorOnNext: (any Error)?

    init(
        responses: [LLMGatewayResponse],
        streamScripts: [[GatewayStreamEvent]] = []
    ) {
        self.responses = responses
        self.streamScripts = streamScripts
    }

    func record(_ messages: [LLMMessage]) {
        invocations.append(messages)
    }

    func nextResponse() throws -> LLMGatewayResponse {
        if let error = errorOnNext {
            errorOnNext = nil
            throw error
        }
        guard !responses.isEmpty else {
            throw MojenticError.invalidArgument(message: "no scripted responses left")
        }
        return responses.removeFirst()
    }

    func nextStream() -> [GatewayStreamEvent] {
        guard !streamScripts.isEmpty else { return [] }
        return streamScripts.removeFirst()
    }

    func recordedInvocations() -> [[LLMMessage]] { invocations }

    func failNext(_ error: any Error) { self.errorOnNext = error }
}

private struct ScriptedGateway: LLMGateway {
    let state: ScriptedGatewayState

    func complete(
        model _: String,
        messages: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        await state.record(messages)
        return try await state.nextResponse()
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
        messages: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        let state = self.state
        return AsyncThrowingStream { continuation in
            let task = Task {
                await state.record(messages)
                let events = await state.nextStream()
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("ChatSession")
struct ChatSessionTests {
    @Test("appends user and assistant turns to history on send")
    func sendAppendsHistory() async throws {
        let state = ScriptedGatewayState(responses: [
            LLMGatewayResponse(content: "hi back", finishReason: .stop)
        ])
        let broker = LLMBroker(gateway: ScriptedGateway(state: state))
        let session = ChatSession(broker: broker, model: "test", systemPrompt: "be brief")
        _ = try await session.send("hi")
        let history = await session.messages()
        #expect(history.count == 3)
        #expect(history[0].role == .system)
        #expect(history[1].role == .user)
        #expect(history[1].content == "hi")
        #expect(history[2].role == .assistant)
        #expect(history[2].content == "hi back")
    }

    @Test("clear() resets history but keeps the system prompt")
    func clearKeepsSystem() async throws {
        let state = ScriptedGatewayState(responses: [
            LLMGatewayResponse(content: "ok", finishReason: .stop)
        ])
        let broker = LLMBroker(gateway: ScriptedGateway(state: state))
        let session = ChatSession(broker: broker, model: "test", systemPrompt: "rules")
        _ = try await session.send("hi")
        await session.clear()
        let history = await session.messages()
        #expect(history.count == 1)
        #expect(history.first?.role == .system)
        #expect(history.first?.content == "rules")
    }

    @Test("rolls back user turn when send fails")
    func failedSendRollsBack() async throws {
        let state = ScriptedGatewayState(responses: [])
        await state.failNext(MojenticError.transport(message: "boom"))
        let broker = LLMBroker(gateway: ScriptedGateway(state: state))
        let session = ChatSession(broker: broker, model: "test", systemPrompt: nil)
        do {
            _ = try await session.send("hello")
            Issue.record("expected throw")
        } catch {
            // expected
        }
        let history = await session.messages()
        #expect(history.isEmpty)
    }

    @Test("stream commits assistant turn once stream completes")
    func streamCommitsHistory() async throws {
        let state = ScriptedGatewayState(
            responses: [],
            streamScripts: [
                [
                    .textDelta("hello "),
                    .textDelta("world"),
                    .done(finishReason: .stop, usage: nil),
                ]
            ]
        )
        let broker = LLMBroker(gateway: ScriptedGateway(state: state))
        let session = ChatSession(broker: broker, model: "test", systemPrompt: nil)
        var deltas: [String] = []
        for try await event in session.stream("hi") {
            if case .textDelta(let delta) = event {
                deltas.append(delta)
            }
        }
        #expect(deltas == ["hello ", "world"])
        let history = await session.messages()
        #expect(history.count == 2)
        #expect(history[1].role == .assistant)
        #expect(history[1].content == "hello world")
    }
}
