import Foundation
import Testing

@testable import Mojentic

private actor CountingAgent: BaseAgent {
    var seen = 0

    func handle(_ event: any Event) async throws -> [any Event] {
        seen += 1
        return []
    }

    func count() -> Int { seen }
}

private actor FailingAgent: BaseAgent {
    func handle(_ event: any Event) async throws -> [any Event] {
        throw MojenticError.invalidArgument(message: "boom")
    }
}

@Suite("AsyncDispatcher")
struct AsyncDispatcherTests {
    @Test("dispatch + wait drains the queue and reaches every subscriber")
    func dispatchAndWait() async throws {
        let router = Router()
        let dispatcher = AsyncDispatcher(router: router)
        let agent = CountingAgent()
        await router.subscribe(agent, to: TextEvent.self)
        await dispatcher.start()
        await dispatcher.dispatch(TextEvent(content: "a"))
        await dispatcher.dispatch(TextEvent(content: "b"))
        await dispatcher.wait()
        #expect(await agent.count() == 2)
        await dispatcher.stop()
    }

    @Test("agent failure surfaces as an ErrorEvent fanned to subscribers")
    func agentFailure() async throws {
        let router = Router()
        let dispatcher = AsyncDispatcher(router: router)
        let failer = FailingAgent()
        let errorListener = CountingAgent()
        await router.subscribe(failer, to: TextEvent.self)
        await router.subscribe(errorListener, to: ErrorEvent.self)
        await dispatcher.start()
        await dispatcher.dispatch(TextEvent(content: "boom"))
        await dispatcher.wait()
        #expect(await errorListener.count() == 1)
        await dispatcher.stop()
    }

    @Test("tracer captures agent lifecycle phases for each handler invocation")
    func tracerCapturesLifecycle() async throws {
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        let router = Router()
        let dispatcher = AsyncDispatcher(router: router, tracer: tracer)
        let agent = CountingAgent()
        await router.subscribe(agent, to: TextEvent.self)
        await dispatcher.start()
        let correlation = UUID()
        await dispatcher.dispatch(
            TextEvent(content: "x", correlationId: correlation)
        )
        await dispatcher.wait()
        await dispatcher.stop()
        let lifecycle = await store.events(correlatedTo: correlation).filter { event in
            if case .agentLifecycle = event { return true }
            return false
        }
        let phases = lifecycle.compactMap { event -> AgentLifecyclePayload.Phase? in
            guard case .agentLifecycle(let payload) = event else { return nil }
            return payload.phase
        }
        #expect(phases.contains(.started))
        #expect(phases.contains(.finished))
    }
}
