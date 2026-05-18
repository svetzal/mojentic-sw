import Foundation
import Testing

@testable import Mojentic

private actor ResponseQueueState {
    var responses: [LLMGatewayResponse]
    init(_ responses: [LLMGatewayResponse]) {
        self.responses = responses
    }
    func next() throws -> LLMGatewayResponse {
        guard !responses.isEmpty else {
            throw MojenticError.invalidArgument(message: "out of responses")
        }
        return responses.removeFirst()
    }
}

private struct QueueGateway: LLMGateway {
    let state: ResponseQueueState
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

@Suite("Higher-order agents")
struct HigherOrderAgentTests {
    @Test("IterativeProblemSolver stops at the first DONE reply")
    func solverStopsOnDone() async throws {
        // Scripted broker: iteration 1 says DONE, then the final summary call.
        let state = ResponseQueueState([
            LLMGatewayResponse(content: "DONE", finishReason: .stop),
            LLMGatewayResponse(content: "the final answer is 42", finishReason: .stop),
        ])
        let broker = LLMBroker(gateway: QueueGateway(state: state))
        let solver = IterativeProblemSolver(
            broker: broker,
            model: "test",
            maxIterations: 5
        )
        let outcome = try await solver.solve("what is the answer")
        #expect(outcome.iterations == 1)
        #expect(outcome.stopReason == .done)
        #expect(outcome.summary == "the final answer is 42")
    }

    @Test("IterativeProblemSolver respects the maxIterations cap")
    func solverHitsCap() async throws {
        // Three "still working" replies + one summary call after the loop.
        let state = ResponseQueueState([
            LLMGatewayResponse(content: "making progress 1", finishReason: .stop),
            LLMGatewayResponse(content: "making progress 2", finishReason: .stop),
            LLMGatewayResponse(content: "still going", finishReason: .stop),
            LLMGatewayResponse(content: "summary", finishReason: .stop),
        ])
        let broker = LLMBroker(gateway: QueueGateway(state: state))
        let solver = IterativeProblemSolver(
            broker: broker,
            model: "test",
            maxIterations: 3
        )
        let outcome = try await solver.solve("problem")
        #expect(outcome.iterations == 3)
        #expect(outcome.stopReason == .maxIterations)
    }

    @Test("SimpleRecursiveAgent throws recursionDepthExceeded when no completion reached")
    func recursiveCap() async {
        let agent = SimpleRecursiveAgent(maxDepth: 3) { _, _ in
            .refine("keep going")
        }
        do {
            _ = try await agent.solve(seed: "start")
            Issue.record("expected throw")
        } catch let error as MojenticError {
            if case .recursionDepthExceeded(let limit) = error {
                #expect(limit == 3)
            } else {
                Issue.record("wrong error: \(error)")
            }
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("SimpleRecursiveAgent returns the completion value when reached")
    func recursiveComplete() async throws {
        let agent = SimpleRecursiveAgent(maxDepth: 5) { current, iteration in
            iteration >= 2 ? .complete(current + "!") : .refine(current + " more")
        }
        let result = try await agent.solve(seed: "hello")
        #expect(result == "hello more!")
    }

    @Test("ReActAgent extracts the final answer from the broker reply")
    func reActExtractsFinalAnswer() async throws {
        let state = ResponseQueueState([
            LLMGatewayResponse(
                content: "Thought: easy.\nFinal Answer: 42",
                finishReason: .stop
            )
        ])
        let broker = LLMBroker(gateway: QueueGateway(state: state))
        let agent = ReActAgent(
            broker: broker,
            model: "test",
            tools: [],
            maxSteps: 4
        )
        let outcome = try await agent.run("what?")
        #expect(outcome.converged)
        #expect(outcome.answer == "42")
    }

    @Test("ReActAgent surfaces non-convergence when the step cap is hit")
    func reActStepsCap() async throws {
        // A broker that always requests a non-existent tool will keep
        // looping until the cap throws toolDepthExceeded, which the agent
        // catches and returns as non-converged.
        let toolCall = LLMToolCall(
            id: "1",
            name: "ghost",
            arguments: .object([:])
        )
        let state = ResponseQueueState(
            (0..<6).map { _ in
                LLMGatewayResponse(
                    content: "",
                    toolCalls: [toolCall],
                    finishReason: .toolCalls
                )
            }
        )
        let broker = LLMBroker(gateway: QueueGateway(state: state))
        // We have to register a tool so the broker dispatches; the dispatch
        // will simply succeed with whatever the tool returns and recurse.
        let echo = EchoToolForReAct()
        let agent = ReActAgent(
            broker: broker,
            model: "test",
            tools: [echo],
            maxSteps: 2
        )
        let outcome = try await agent.run("loop forever")
        #expect(!outcome.converged)
    }
}

private struct EchoToolForReAct: LLMTool {
    let descriptor = ToolDescriptor(
        name: "ghost",
        description: "echo",
        parameters: ["type": "object"]
    )
    func execute(arguments _: JSONValue) async throws -> JSONValue { .object([:]) }
}
