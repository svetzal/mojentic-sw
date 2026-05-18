import Foundation
import Testing

@testable import Mojentic

private actor NoopAgent: BaseAgent {
    func handle(_ event: any Event) async throws -> [any Event] { [] }
}

@Suite("Router")
struct RouterTests {
    @Test("subscribe + route fans out to every subscriber for the event type")
    func fanOut() async {
        let router = Router()
        let alice = NoopAgent()
        let bob = NoopAgent()
        await router.subscribe(alice, to: TextEvent.self)
        await router.subscribe(bob, to: TextEvent.self)
        let matched = await router.route(TextEvent(content: "hi"))
        #expect(matched.count == 2)
    }

    @Test("unsubscribe removes the agent from every event type")
    func unsubscribe() async {
        let router = Router()
        let agent = NoopAgent()
        await router.subscribe(agent, to: TextEvent.self)
        await router.subscribe(agent, to: LLMRequestEvent.self)
        await router.unsubscribe(agent)
        #expect(await router.subscriberCount() == 0)
    }

    @Test("subscribing the same agent twice is idempotent")
    func idempotentSubscribe() async {
        let router = Router()
        let agent = NoopAgent()
        await router.subscribe(agent, to: TextEvent.self)
        await router.subscribe(agent, to: TextEvent.self)
        #expect(await router.subscriberCount() == 1)
    }

    @Test("route returns an empty list when no agents are subscribed")
    func noSubscribers() async {
        let router = Router()
        let matched = await router.route(TextEvent(content: "hi"))
        #expect(matched.isEmpty)
    }
}
