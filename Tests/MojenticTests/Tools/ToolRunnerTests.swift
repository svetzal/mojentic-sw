import Foundation
import Testing

@testable import Mojentic

private struct EchoTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "echo",
        description: "echo back the supplied text",
        parameters: ["type": "object"]
    )

    func execute(arguments: JSONValue) async throws -> JSONValue {
        ["echoed": arguments]
    }
}

private struct FailingTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "boom",
        description: "always fails",
        parameters: ["type": "object"]
    )

    func execute(arguments _: JSONValue) async throws -> JSONValue {
        throw MojenticError.toolExecution(name: "boom", message: "kaboom")
    }
}

@Suite("SerialToolRunner")
struct ToolRunnerTests {
    @Test("dispatches calls in input order")
    func dispatchOrder() async throws {
        let runner = SerialToolRunner()
        let calls = [
            ToolCallExecution(id: "a", name: "echo", arguments: ["v": 1]),
            ToolCallExecution(id: "b", name: "echo", arguments: ["v": 2]),
        ]
        let outcomes = try await runner.runBatch(calls, tools: [EchoTool()])
        #expect(outcomes.count == 2)
        #expect(outcomes[0].id == "a")
        #expect(outcomes[1].id == "b")
        if case .success(let first) = outcomes[0].kind {
            #expect(first.objectValue?["echoed"]?.objectValue?["v"]?.intValue == 1)
        } else {
            Issue.record("Expected success outcome")
        }
    }

    @Test("captures tool errors without throwing the batch")
    func captureError() async throws {
        let runner = SerialToolRunner()
        let outcomes = try await runner.runBatch(
            [ToolCallExecution(id: "x", name: "boom", arguments: [:])],
            tools: [FailingTool()]
        )
        #expect(outcomes.count == 1)
        #expect(!outcomes[0].ok)
        if case .failure(let message) = outcomes[0].kind {
            #expect(message.contains("kaboom"))
        } else {
            Issue.record("Expected failure outcome")
        }
    }

    @Test("missing tools produce a not-found failure")
    func notFound() async throws {
        let runner = SerialToolRunner()
        let outcomes = try await runner.runBatch(
            [ToolCallExecution(id: "x", name: "nope", arguments: [:])],
            tools: [EchoTool()]
        )
        #expect(outcomes.count == 1)
        #expect(!outcomes[0].ok)
    }
}
