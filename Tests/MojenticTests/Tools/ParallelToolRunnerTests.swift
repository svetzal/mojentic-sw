import Foundation
@testable import Mojentic
import Testing

private actor ToolCompletionOrder {
    private(set) var completed: [String] = []
    private var waiting: CheckedContinuation<Void, Never>?
    func finish(_ id: String) async {
        if id == "slow", !completed.contains("fast") {
            await withCheckedContinuation { waiting = $0 }
        }
        completed.append(id)
        if id == "fast" {
            waiting?.resume()
            waiting = nil
        }
    }
}

private struct OrderedTool: LLMTool {
    let id: String
    let order: ToolCompletionOrder?
    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "ordered_\(id)", description: "scripted completion", parameters: ["type": "object"])
    }
    init(id: String, order: ToolCompletionOrder? = nil) {
        self.id = id
        self.order = order
    }
    func execute(arguments _: JSONValue) async throws -> JSONValue {
        await order?.finish(id)
        return ["id": .string(id)]
    }
}

/// Holds every arriving caller until `expected` callers are in flight at once.
///
/// A serial runner never gets past the first arrival, so a test that uses it
/// proves concurrency without depending on wall-clock timing.
private actor ArrivalBarrier {
    private let expected: Int
    private var arrived = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(expected: Int) {
        self.expected = expected
    }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= expected {
            waiting.forEach { $0.resume() }
            waiting.removeAll()
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}

private struct BarrierTool: LLMTool {
    let barrier: ArrivalBarrier
    let descriptor: ToolDescriptor

    init(name: String, barrier: ArrivalBarrier) {
        self.barrier = barrier
        descriptor = ToolDescriptor(
            name: name,
            description: "wait for siblings",
            parameters: ["type": "object"],
        )
    }

    func execute(arguments _: JSONValue) async throws -> JSONValue {
        await barrier.arriveAndWait()
        return ["name": .string(descriptor.name)]
    }
}

private struct ExplodingTool: LLMTool {
    let descriptor = ToolDescriptor(name: "boom", description: "boom", parameters: ["type": "object"])

    func execute(arguments _: JSONValue) async throws -> JSONValue {
        throw MojenticError.toolExecution(name: "boom", message: "bang")
    }
}

@Suite("ParallelToolRunner")
struct ParallelToolRunnerTests {
    @Test("results are returned in input order regardless of completion order")
    func preservesOrder()
        async throws
    {
        let runner = ParallelToolRunner(maxConcurrency: 4)
        let order = ToolCompletionOrder()
        let tools: [any LLMTool] = [
            OrderedTool(id: "slow", order: order),
            OrderedTool(id: "fast", order: order),
        ]
        let calls = [
            ToolCallExecution(id: "a", name: "ordered_slow", arguments: .object([:])),
            ToolCallExecution(id: "b", name: "ordered_fast", arguments: .object([:])),
        ]
        let outcomes = try await runner.runBatch(calls, tools: tools)
        #expect(outcomes.count == 2)
        #expect(outcomes[0].id == "a")
        #expect(outcomes[1].id == "b")
        #expect(await order.completed == ["fast", "slow"])
        if case .success(let value) = outcomes[0].kind {
            #expect(value.objectValue?["id"]?.stringValue == "slow")
        } else {
            Issue.record("expected slow success")
        }
    }

    @Test("parallel dispatch runs every call in a batch at the same time", .timeLimit(.minutes(1)))
    func runsCallsConcurrently() async throws {
        let names = ["one", "two", "three"]
        let barrier = ArrivalBarrier(expected: names.count)
        let tools: [any LLMTool] = names.map { BarrierTool(name: $0, barrier: barrier) }
        let calls = names.map { name in ToolCallExecution(id: name, name: name, arguments: .object([:])) }

        // Each tool returns only after all three are in flight, so this
        // completes only if the runner dispatches them concurrently.
        let outcomes = try await ParallelToolRunner(maxConcurrency: 4).runBatch(calls, tools: tools)

        #expect(outcomes.map(\.id) == names)
    }

    @Test("tool failure is captured per-call without aborting siblings")
    func failureIsolated() async throws {
        let runner = ParallelToolRunner(maxConcurrency: 4)
        let tools: [any LLMTool] = [ExplodingTool(), OrderedTool(id: "ok")]
        let calls = [
            ToolCallExecution(id: "x", name: "boom", arguments: .object([:])),
            ToolCallExecution(id: "y", name: "ordered_ok", arguments: .object([:])),
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
        let tools: [any LLMTool] = [OrderedTool(id: "a")]
        let calls = [ToolCallExecution(id: "1", name: "ordered_a", arguments: .object([:]))]
        let context = TracerContext()
        _ = try await runner.runBatch(calls, tools: tools, tracer: tracer, context: context)
        let events = await store.allEvents()
        let batch = events.first { event in
            if case .toolBatch = event {
                return true
            }
            return false
        }
        guard let event = batch, case .toolBatch(let payload) = event else {
            Issue.record("expected a toolBatch event")
            return
        }
        #expect(payload.count == 1)
        #expect(payload.correlationId == context.correlationId)
        #expect(payload.parentId == context.parentId)
    }
}
