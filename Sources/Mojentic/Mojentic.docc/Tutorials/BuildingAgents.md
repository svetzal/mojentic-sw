#  Building Agents

Compose stateful coordinators that exchange events via a dispatcher,
share working memory, and link their tracer events into one correlation
tree.

## Overview

### Why

Some workflows are too gnarly for a single broker call. They need
multiple specialised agents (a planner, a critic, a tool dispatcher)
talking to each other, with the observability story preserved end to
end. The Mojentic agent system gives you small, composable actors that
publish and consume typed events through a ``Router`` + ``AsyncDispatcher``.

### When

Reach for the agent system when:
- You need fan-out: one event handled by several listeners in parallel.
- You need fan-in: aggregate N upstream events before triggering the next
  step (``AsyncAggregatorAgent``).
- You need iterative refinement (``IterativeProblemSolver``,
  ``SimpleRecursiveAgent``).
- You need explicit Thought / Action / Observation lifecycle
  (``ReActAgent``).

For one-shot completions, stay with ``LLMBroker``.

### How

#### 1. Define an event type

```swift
import Mojentic

struct AnalyseRequest: Event, Codable {
    let correlationId: UUID
    let parentId: UUID?
    let text: String
}
```

#### 2. Define an agent

```swift
actor AnalysisAgent: BaseAgent {
    let broker: LLMBroker
    init(broker: LLMBroker) { self.broker = broker }

    func handle(_ event: any Event) async throws -> [any Event] {
        guard let request = event as? AnalyseRequest else { return [] }
        let response = try await broker.complete(
            model: "gpt-4o-mini",
            messages: [.user(request.text)],
            context: TracerContext(
                correlationId: event.correlationId,
                parentId: event.parentId
            )
        )
        return [
            LLMResponseEvent(
                response: response,
                correlationId: event.correlationId,
                parentId: event.parentId
            )
        ]
    }
}
```

The broker call accepts a ``TracerContext`` so its tracer events nest
under the agent's correlation id.

#### 3. Wire the dispatcher

```swift
let router = Router()
let dispatcher = AsyncDispatcher(router: router, tracer: EventStoreTracer())
let agent = AnalysisAgent(broker: LLMBroker(gateway: OpenAIGateway(apiKey: key)))
await router.subscribe(agent, to: AnalyseRequest.self)
await dispatcher.start()
await dispatcher.dispatch(
    AnalyseRequest(correlationId: UUID(), parentId: nil, text: "hello")
)
await dispatcher.wait()
await dispatcher.stop()
```

`dispatcher.wait()` returns once the queue is drained and every in-flight
handler has returned — handy for test harnesses and CLI tools.

#### 4. Share state

```swift
let memory = SharedWorkingMemory()
await memory.set("greeting", to: .string("hello"), scope: correlationId)
let value = await memory.get("greeting", scope: correlationId)
```

Scopes are optional; pass `nil` for global state.

#### 5. Inspect the correlation tree

```swift
let tracer = EventStoreTracer()
// …run flow…
let tree = await tracer.store.events(correlatedTo: correlationId)
for event in tree { print(event) }
```

Every broker, tool, and agent event nested under that correlation id
appears in arrival order.

## Higher-Order Agents

- ``IterativeProblemSolver`` — DONE / FAIL / max-iterations loop.
- ``SimpleRecursiveAgent`` — closure-driven refinement bounded by a
  depth cap.
- ``ReActAgent`` — Thought → Action → Observation loop driven by the
  broker's native tool-call recursion.

## See Also

- ``AsyncDispatcher``
- ``Router``
- ``BaseAgent``
- ``AsyncLLMAgent``
- ``AsyncAggregatorAgent``
- ``SharedWorkingMemory``
- ``TracerContext``
- ``EventStore``
