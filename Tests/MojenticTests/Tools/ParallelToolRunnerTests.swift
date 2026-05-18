import Foundation
import Testing

@testable import Mojentic

private struct SleepyTool: LLMTool {
    let id: String
    let descriptor: ToolDescriptor

    init(id: String, duration: Duration) {
        self.id = id
        self.descriptor = ToolDescriptor(
            name: "sleep_\(id)",
            description: "sleep",
            parameters: ["type": "object"]
        )
        self.sleepDuration = duration
    }

    let sleepDuration: Duration

    func execute(arguments _: JSONValue) async throws -> JSONValue {
        try await Task.sleep(for: sleepDuration)
        return ["id": .string(id)]
    }
}

private struct ExplodingTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "boom",
        description: "boom",
        parameters: ["type": "object"]
    )

    func execute(arguments _: JSONValue) async throws -> JSONValue {
        throw MojenticError.toolExecution(name: "boom", message: "bang")
    }
}

@Suite("ParallelToolRunner")
struct ParallelToolRunnerTests {
    @Test("results are returned in input order regardless of completion order")
    func preservesOrder() async throws {
        let runner = ParallelToolRunner(maxConcurrency: 4)
        let tools: [any LLMTool] = [
            SleepyTool(id: "slow", duration: .milliseconds(60)),
            SleepyTool(id: "fast", duration: .milliseconds(5)),
        ]
        let calls = [
            ToolCallExecution(id: "a", name: "sleep_slow", arguments: .object([:])),
            ToolCallExecution(id: "b", name: "sleep_fast", arguments: .object([:])),
        ]
        let outcomes = try await runner.runBatch(calls, tools: tools)
        #expect(outcomes.count == 2)
        #expect(outcomes[0].id == "a")
        #expect(outcomes[1].id == "b")
        if case .success(let value) = outcomes[0].kind {
            #expect(value.objectValue?["id"]?.stringValue == "slow")
        } else {
            Issue.record("expected slow success")
        }
    }

    @Test("parallel dispatch is faster than serial for I/O-bound tools")
    func parallelSpeedup() async throws {
        let tools: [any LLMTool] = [
            SleepyTool(id: "one", duration: .milliseconds(80)),
            SleepyTool(id: "two", duration: .milliseconds(80)),
            SleepyTool(id: "three", duration: .milliseconds(80)),
        ]
        let calls = (0..<3).map { i in
            ToolCallExecution(
                id: "\(i)",
                name: "sleep_\(["one", "two", "three"][i])",
                arguments: .object([:])
            )
        }
        let clock = ContinuousClock()
        let parallelTime = try await clock.measure {
            _ = try await ParallelToolRunner(maxConcurrency: 4)
                .runBatch(calls, tools: tools)
        }
        let serialTime = try await clock.measure {
            _ = try await SerialToolRunner().runBatch(calls, tools: tools)
        }
        // Serial should be at least ~2x slower (3 * 80ms vs ~80ms ceiling).
        #expect(parallelTime < serialTime / 2)
    }

    @Test("tool failure is captured per-call without aborting siblings")
    func failureIsolated() async throws {
        let runner = ParallelToolRunner(maxConcurrency: 4)
        let tools: [any LLMTool] = [
            ExplodingTool(),
            SleepyTool(id: "ok", duration: .milliseconds(5)),
        ]
        let calls = [
            ToolCallExecution(id: "x", name: "boom", arguments: .object([:])),
            ToolCallExecution(id: "y", name: "sleep_ok", arguments: .object([:])),
        ]
        let outcomes = try await runner.runBatch(calls, tools: tools)
        #expect(outcomes.count == 2)
        #expect(!outcomes[0].ok)
        #expect(outcomes[1].ok)
    }

    @Test("emits a toolBatch event summarising the batch")
    func emitsToolBatch() async throws {
        let runner = ParallelToolRunner(maxConcurrency: 4)
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        let tools: [any LLMTool] = [SleepyTool(id: "a", duration: .milliseconds(5))]
        let calls = [
            ToolCallExecution(id: "1", name: "sleep_a", arguments: .object([:]))
        ]
        let context = TracerContext()
        _ = try await runner.runBatch(
            calls,
            tools: tools,
            tracer: tracer,
            context: context
        )
        let events = await store.allEvents()
        let batch = events.first { event in
            if case .toolBatch = event { return true }
            return false
        }
        guard let event = batch, case .toolBatch(let payload) = event else {
            Issue.record("expected a toolBatch event")
            return
        }
        #expect(payload.count == 1)
        #expect(payload.duration > .zero)
    }
}
