import Foundation
import Testing

@testable import Mojentic

/// Records what the broker asked of a scripted events gateway.
private actor EventsGatewayLog {
    private(set) var requests: [CompletionConfig] = []
    private(set) var otherCalls = 0
    private(set) var terminated = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recordRequest(_ config: CompletionConfig) { requests.append(config) }
    func recordOtherCall() { otherCalls += 1 }

    func recordTermination() {
        terminated = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func waitForTermination() async {
        if terminated { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Gateway whose single-turn event stream replays a script.
private struct ScriptedEventsGateway: LLMGateway {
    let script: [CompletionStreamEvent]
    var holdOpen = false
    let log = EventsGatewayLog()

    func complete(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        await log.recordOtherCall()
        return LLMGatewayResponse(content: "")
    }

    func completeJSON(
        model _: String,
        messages _: [LLMMessage],
        schema _: JSONValue,
        config _: CompletionConfig
    ) async throws -> JSONValue { .null }

    func availableModels() async throws -> [String] { [] }

    func stream(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func completeStreamEvents(
        model _: String,
        messages _: [LLMMessage],
        config: CompletionConfig
    ) -> AsyncStream<CompletionStreamEvent> {
        let script = self.script
        let holdOpen = self.holdOpen
        let log = self.log
        return AsyncStream { continuation in
            continuation.onTermination = { _ in Task { await log.recordTermination() } }
            Task { await log.recordRequest(config) }
            for event in script {
                continuation.yield(event)
            }
            if !holdOpen { continuation.finish() }
        }
    }
}

/// Gateway that implements nothing beyond the required legacy surface.
private struct LegacyOnlyGateway: LLMGateway {
    let log = EventsGatewayLog()

    func complete(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        await log.recordOtherCall()
        return LLMGatewayResponse(content: "")
    }

    func completeJSON(
        model _: String,
        messages _: [LLMMessage],
        schema _: JSONValue,
        config _: CompletionConfig
    ) async throws -> JSONValue {
        await log.recordOtherCall()
        return .null
    }

    func availableModels() async throws -> [String] { [] }

    func stream(
        model _: String,
        messages _: [LLMMessage],
        tools _: [any LLMTool]?,
        config _: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        let log = self.log
        return AsyncThrowingStream { continuation in
            Task {
                await log.recordOtherCall()
                continuation.finish()
            }
        }
    }
}

private let stopEvidence = CompletionEvidence(
    finishReason: "stop",
    usage: Usage(promptTokens: 4, completionTokens: 2, totalTokens: 6),
    providerModel: "qwen3:8b",
    metadata: ["total_duration": .integer(100)]
)

private let lengthEvidence = CompletionEvidence(
    finishReason: "length",
    usage: Usage(promptTokens: 4, completionTokens: 9, totalTokens: 13),
    providerModel: "qwen3:8b",
    metadata: ["eval_duration": .integer(30)]
)

private func tracedBroker(_ gateway: any LLMGateway) -> (LLMBroker, EventStore) {
    let store = EventStore()
    return (LLMBroker(gateway: gateway, tracer: EventStoreTracer(store: store)), store)
}

@Suite("Broker single-turn event stream")
struct BrokerStreamEventsTests {
    @Test("content events then completed, from one request with tool iterations forced to zero")
    func completes() async {
        let gateway = ScriptedEventsGateway(script: [
            .content("Hel"), .content("lo"), .completed(stopEvidence),
        ])
        let (broker, _) = tracedBroker(gateway)
        let seen = await collect(broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")]))
        #expect(seen == [.content("Hel"), .content("lo"), .completed(stopEvidence)])
        let requests = await gateway.log.requests
        #expect(requests.count == 1)
        #expect(requests.first?.maxToolIterations == 0)
        #expect(await gateway.log.otherCalls == 0)
    }

    @Test("an incomplete completion is the terminal error, carrying its evidence")
    func incompleteCompletion() async {
        let gateway = ScriptedEventsGateway(script: [
            .content("Partial"), .error(.incompleteCompletion(lengthEvidence)),
        ])
        let (broker, _) = tracedBroker(gateway)
        let seen = await collect(broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")]))
        #expect(seen == [.content("Partial"), .incompleteCompletion(lengthEvidence)])
    }

    @Test("a gateway stream that ends without a terminal event is an incomplete-stream error")
    func incompleteStream() async {
        let gateway = ScriptedEventsGateway(script: [.content("Hi")])
        let (broker, _) = tracedBroker(gateway)
        let seen = await collect(broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")]))
        #expect(seen == [.content("Hi"), .incompleteStream(nil)])
    }

    @Test("nothing follows the terminal event")
    func nothingAfterTerminal() async {
        let gateway = ScriptedEventsGateway(script: [
            .content("Hi"), .error(.unexpectedToolCalls), .content("late"), .completed(stopEvidence),
        ])
        let (broker, _) = tracedBroker(gateway)
        let seen = await collect(broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")]))
        #expect(seen == [.content("Hi"), .unexpectedToolCalls])
    }

    @Test("an unsupported gateway errors without a request or trace")
    func unsupported() async {
        let gateway = LegacyOnlyGateway()
        let (broker, store) = tracedBroker(gateway)
        let seen = await collect(broker.generateStreamEvents(model: "m", messages: [.user("hi")]))
        #expect(seen == [.streamEventsUnsupported])
        #expect(await gateway.log.otherCalls == 0)
        #expect(await store.allEvents().isEmpty)
    }

    @Test("stopping consumption early cancels the gateway request", .timeLimit(.minutes(1)))
    func cancels() async {
        let gateway = ScriptedEventsGateway(script: [.content("Hi")], holdOpen: true)
        let (broker, _) = tracedBroker(gateway)
        for await event in broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")]) {
            #expect(SeenEvent(event) == .content("Hi"))
            break
        }
        await gateway.log.waitForTermination()
        #expect(await gateway.log.terminated)
    }

    @Test("an early stop leaves the call traced and records no response", .timeLimit(.minutes(1)))
    func earlyStopTracing() async {
        let gateway = ScriptedEventsGateway(script: [.content("Hi")], holdOpen: true)
        let (broker, store) = tracedBroker(gateway)
        let context = TracerContext()
        for await _ in broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")], context: context)
        {
            break
        }
        await gateway.log.waitForTermination()
        // Let the broker task observe the cancellation before inspecting the store.
        try? await Task.sleep(for: .milliseconds(50))
        let events = await store.events(correlatedTo: context.correlationId)
        #expect(events.count == 1)
        if case .llmCall? = events.first {} else { Issue.record("expected only the llmCall, got \(events)") }
    }

    @Test("cancelling the consuming task cancels the gateway request", .timeLimit(.minutes(1)))
    func taskCancellation() async {
        let gateway = ScriptedEventsGateway(script: [], holdOpen: true)
        let (broker, _) = tracedBroker(gateway)
        let consumer = Task {
            await collect(broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")]))
        }
        consumer.cancel()
        _ = await consumer.value
        await gateway.log.waitForTermination()
        #expect(await gateway.log.terminated)
    }

    @Test("the tracer records the call and the response with reported evidence")
    func tracesCompletion() async throws {
        let gateway = ScriptedEventsGateway(script: [
            .content("Hel"), .content("lo"), .completed(stopEvidence),
        ])
        let (broker, store) = tracedBroker(gateway)
        let context = TracerContext()
        _ = await collect(
            broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")], context: context))

        let events = await store.events(correlatedTo: context.correlationId)
        #expect(events.count == 2)
        guard case .llmCall(let call)? = events.first, case .llmResponse(let response)? = events.last else {
            Issue.record("expected an llmCall then an llmResponse, got \(events)")
            return
        }
        #expect(call.tools == nil)
        #expect(response.parentId == call.id)
        #expect(response.model == "qwen3")
        #expect(response.response.content == "Hello")
        #expect(response.usage == stopEvidence.usage)
        #expect(response.providerModel == "qwen3:8b")
        #expect(response.finishReason == "stop")
        #expect(response.metadata == ["total_duration": .integer(100)])
    }

    @Test("the tracer records content so far and evidence for an incomplete completion")
    func tracesIncompleteCompletion() async throws {
        let gateway = ScriptedEventsGateway(script: [
            .content("Partial"), .error(.incompleteCompletion(lengthEvidence)),
        ])
        let (broker, store) = tracedBroker(gateway)
        let context = TracerContext()
        _ = await collect(
            broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")], context: context))

        let responses = await store.events(correlatedTo: context.correlationId).compactMap { event in
            if case .llmResponse(let payload) = event { return payload }
            return nil
        }
        let response = try #require(responses.first)
        #expect(response.response.content == "Partial")
        #expect(response.finishReason == "length")
        #expect(response.usage == lengthEvidence.usage)
        #expect(response.metadata == ["eval_duration": .integer(30)])
    }

    @Test("an unknown provider finish reason survives into the stream trace unchanged")
    func tracesUnknownFinishReason() async throws {
        let evidence = CompletionEvidence(finishReason: "load", providerModel: "qwen3:8b")
        let gateway = ScriptedEventsGateway(script: [.error(.incompleteCompletion(evidence))])
        let (broker, store) = tracedBroker(gateway)
        let context = TracerContext()
        _ = await collect(
            broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")], context: context)
        )

        let responses = await store.events(correlatedTo: context.correlationId).compactMap { event in
            if case .llmResponse(let payload) = event { return payload }
            return nil
        }
        let response = try #require(responses.first)
        #expect(response.finishReason == "load")
    }

    @Test("the tracer records partial evidence for an incomplete stream")
    func tracesIncompleteStream() async throws {
        let partial = CompletionEvidence(usage: Usage(promptTokens: 4), providerModel: "qwen3:8b")
        let gateway = ScriptedEventsGateway(script: [.content("Par"), .error(.incompleteStream(partial))])
        let (broker, store) = tracedBroker(gateway)
        let context = TracerContext()
        _ = await collect(
            broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")], context: context)
        )

        let responses = await store.events(correlatedTo: context.correlationId).compactMap { event in
            if case .llmResponse(let payload) = event { return payload }
            return nil
        }
        let response = try #require(responses.first)
        #expect(response.response.content == "Par")
        #expect(response.usage == Usage(promptTokens: 4))
        #expect(response.providerModel == "qwen3:8b")
        #expect(response.finishReason == nil)
    }

    @Test("a response without reported usage is traced with nil usage")
    func tracesNoUsage() async throws {
        let gateway = ScriptedEventsGateway(script: [
            .content("Hi"), .completed(CompletionEvidence(finishReason: "stop")),
        ])
        let (broker, store) = tracedBroker(gateway)
        let context = TracerContext()
        _ = await collect(
            broker.generateStreamEvents(model: "qwen3", messages: [.user("hi")], context: context))

        let responses = await store.events(correlatedTo: context.correlationId).compactMap { event in
            if case .llmResponse(let payload) = event { return payload }
            return nil
        }
        let response = try #require(responses.first)
        #expect(response.usage == nil)
        #expect(response.providerModel == nil)
    }
}
