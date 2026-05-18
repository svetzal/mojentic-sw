import Foundation
import Mojentic

/// Wire a Router + dispatcher + two trivial agents and dispatch one
/// TextEvent to show the fan-out.
private actor EchoAgent: BaseAgent {
    let label: String

    init(label: String) { self.label = label }

    func handle(_ event: any Event) async throws -> [any Event] {
        if let textEvent = event as? TextEvent {
            print("[\(label)] saw '\(textEvent.content)'")
        }
        return []
    }
}

@main
struct AsyncDispatcherExample {
    static func main() async {
        let router = Router()
        let dispatcher = AsyncDispatcher(router: router)
        let alice = EchoAgent(label: "alice")
        let bob = EchoAgent(label: "bob")
        await router.subscribe(alice, to: TextEvent.self)
        await router.subscribe(bob, to: TextEvent.self)
        await dispatcher.start()
        await dispatcher.dispatch(TextEvent(content: "hi everyone"))
        await dispatcher.wait()
        await dispatcher.stop()
    }
}
