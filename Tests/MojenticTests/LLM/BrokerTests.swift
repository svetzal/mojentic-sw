import Foundation
import Testing

@testable import Mojentic

/// Actor-isolated state behind `FakeGateway` so tests can inspect invocations
/// without violating Swift 6 actor-isolation rules.
private actor FakeGatewayState {
    var queue: [LLMGatewayResponse]
    var invocations: [[LLMMessage]] = []
    var jsonResponse: JSONValue = .object([:])
    var streamScript: [[GatewayStreamEvent]] = []

    init(responses: [LLMGatewayResponse]) {
        self.queue = responses
    }

    func record(_ messages: [LLMMessage]) {
        invocations.append(messages)
    }

    func nextResponse() throws -> LLMGatewayResponse {
        guard !queue.isEmpty else {
            throw MojenticError.invalidArgument(message: "FakeGateway: no scripted responses left")
        }
        return queue.removeFirst()
    }

    func setJSONResponse(_ value: JSONValue) {
        self.jsonResponse = value
    }

    func currentJSONResponse() -> JSONValue { jsonResponse }

    func setStreamScript(_ script: [[GatewayStreamEvent]]) {
        self.streamScript = script
    }

    func nextStreamScript() -> [GatewayStreamEvent] {
        guard !streamScript.isEmpty else { return [] }
        return streamScript.removeFirst()
    }

    func recordedInvocations() -> [[LLMMessage]] { invocations }
}

private struct FakeGateway: LLMGateway {
    let state: FakeGatewayState

    init(responses: [LLMGatewayResponse]) {
        self.state = FakeGatewayState(responses: responses)
    }

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
        messages: [LLMMessage],
        schema _: JSONValue,
        config _: CompletionConfig
    ) async throws -> JSONValue {
        await state.record(messages)
        return await state.currentJSONResponse()
    }

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
                let events = await state.nextStreamScript()
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct EchoNumberTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "double",
        description: "double a number",
        parameters: [
            "type": "object",
            "properties": ["value": ["type": "integer"]],
            "required": ["value"],
        ]
    )

    func execute(arguments: JSONValue) async throws -> JSONValue {
        let value = arguments.objectValue?["value"]?.intValue ?? 0
        return ["doubled": .integer(value * 2)]
    }
}

private struct ExtractedPerson: Codable, Sendable, Equatable, JSONSchemaProviding {
    let name: String
    let age: Int

    static var jsonSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "age": ["type": "integer"],
            ],
            "required": ["name", "age"],
        ]
    }
}

@Suite("LLMBroker")
struct BrokerTests {
    @Test("returns content directly when no tool calls are requested")
    func plainCompletion() async throws {
        let gateway = FakeGateway(responses: [
            LLMGatewayResponse(content: "the sky is blue", finishReason: .stop)
        ])
        let broker = LLMBroker(gateway: gateway)
        let response = try await broker.complete(
            model: "test-model",
            messages: [.user("colour of the sky?")]
        )
        #expect(response.content == "the sky is blue")
        #expect(response.finishReason == .stop)
        let invocations = await gateway.state.recordedInvocations()
        #expect(invocations.count == 1)
    }

    @Test("dispatches a single tool call, appends pair, and recurses")
    func singleToolCallRecursion() async throws {
        let toolCall = LLMToolCall(id: "1", name: "double", arguments: ["value": 21])
        let gateway = FakeGateway(responses: [
            LLMGatewayResponse(content: "", toolCalls: [toolCall], finishReason: .toolCalls),
            LLMGatewayResponse(content: "the answer is 42", finishReason: .stop),
        ])
        let broker = LLMBroker(gateway: gateway)
        let response = try await broker.complete(
            model: "test-model",
            messages: [.user("double 21")],
            tools: [EchoNumberTool()]
        )
        #expect(response.content == "the answer is 42")
        let invocations = await gateway.state.recordedInvocations()
        #expect(invocations.count == 2)
        let secondCall = invocations[1]
        #expect(secondCall.count == 3)
        #expect(secondCall[1].role == .assistant)
        #expect(secondCall[1].toolCalls?.first?.name == "double")
        #expect(secondCall[2].role == .tool)
        #expect(secondCall[2].toolCallId == "1")
    }

    @Test("throws toolDepthExceeded once the iteration budget is exhausted")
    func toolDepthCap() async throws {
        let toolCall = LLMToolCall(id: "1", name: "double", arguments: ["value": 1])
        let infinite = (0..<10).map { _ in
            LLMGatewayResponse(content: "", toolCalls: [toolCall], finishReason: .toolCalls)
        }
        let gateway = FakeGateway(responses: infinite)
        let broker = LLMBroker(gateway: gateway)
        let config = CompletionConfig(maxToolIterations: 3)
        do {
            _ = try await broker.complete(
                model: "test-model",
                messages: [.user("loop")],
                tools: [EchoNumberTool()],
                config: config
            )
            Issue.record("expected toolDepthExceeded")
        } catch let error as MojenticError {
            if case .toolDepthExceeded(let limit) = error {
                #expect(limit == 3)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("completeJSON decodes the gateway payload into the requested type")
    func structuredOutputDecode() async throws {
        let gateway = FakeGateway(responses: [])
        await gateway.state.setJSONResponse([
            "name": "Alice",
            "age": 34,
        ])
        let broker = LLMBroker(gateway: gateway)
        let person = try await broker.completeJSON(
            model: "test-model",
            messages: [.user("extract person")],
            responseType: ExtractedPerson.self
        )
        #expect(person == ExtractedPerson(name: "Alice", age: 34))
    }

    @Test("stream emits text deltas in order and finishes with .done")
    func streamingOrdering() async throws {
        let gateway = FakeGateway(responses: [])
        await gateway.state.setStreamScript([
            [
                .textDelta("hello "),
                .textDelta("world"),
                .done(finishReason: .stop, usage: nil),
            ]
        ])
        let broker = LLMBroker(gateway: gateway)
        var deltas: [String] = []
        var finalContent: String?
        for try await event in broker.stream(model: "test-model", messages: [.user("hi")]) {
            switch event {
            case .textDelta(let delta):
                deltas.append(delta)
            case .done(let response):
                finalContent = response.content
            default:
                break
            }
        }
        #expect(deltas == ["hello ", "world"])
        #expect(finalContent == "hello world")
    }

    @Test("stream dispatches tool calls and re-streams the follow-up")
    func streamingWithTool() async throws {
        let toolCall = LLMToolCall(id: "1", name: "double", arguments: ["value": 21])
        let gateway = FakeGateway(responses: [])
        await gateway.state.setStreamScript([
            [
                .toolCallRequest(toolCall),
                .done(finishReason: .toolCalls, usage: nil),
            ],
            [
                .textDelta("42"),
                .done(finishReason: .stop, usage: nil),
            ],
        ])
        let broker = LLMBroker(gateway: gateway)
        var toolResults: [JSONValue] = []
        var deltas: [String] = []
        var done = false
        for try await event in broker.stream(
            model: "test-model",
            messages: [.user("double 21")],
            tools: [EchoNumberTool()]
        ) {
            switch event {
            case .textDelta(let delta):
                deltas.append(delta)
            case .toolCallResult(_, let result):
                toolResults.append(result)
            case .done:
                done = true
            default:
                break
            }
        }
        #expect(deltas == ["42"])
        #expect(toolResults.count == 1)
        #expect(toolResults.first?.objectValue?["doubled"]?.intValue == 42)
        #expect(done)
    }
}
