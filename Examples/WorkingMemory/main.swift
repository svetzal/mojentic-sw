import Foundation
import Mojentic

/// Two agents sharing state via SharedWorkingMemory: a "writer" stores a
/// value, then a "reader" pulls it back out under the same scope.
private actor WriterAgent: BaseAgent {
    let memory: SharedWorkingMemory

    init(memory: SharedWorkingMemory) { self.memory = memory }

    func handle(_ event: any Event) async throws -> [any Event] {
        if let textEvent = event as? TextEvent {
            await memory.set("greeting", to: .string(textEvent.content), scope: event.correlationId)
        }
        return []
    }
}

private actor ReaderAgent: BaseAgent {
    let memory: SharedWorkingMemory

    init(memory: SharedWorkingMemory) { self.memory = memory }

    func handle(_ event: any Event) async throws -> [any Event] {
        let value = await memory.get("greeting", scope: event.correlationId)
        if let value = value?.stringValue {
            print("Reader saw: \(value)")
        } else {
            print("Reader saw nothing.")
        }
        return []
    }
}

@main
struct WorkingMemoryExample {
    static func main() async {
        let memory = SharedWorkingMemory()
        let router = Router()
        let dispatcher = AsyncDispatcher(router: router)
        let writer = WriterAgent(memory: memory)
        let reader = ReaderAgent(memory: memory)
        await router.subscribe(writer, to: TextEvent.self)
        await router.subscribe(reader, to: ReadEvent.self)
        await dispatcher.start()
        let correlation = UUID()
        await dispatcher.dispatch(
            TextEvent(content: "hello from writer", correlationId: correlation)
        )
        await dispatcher.wait()
        await dispatcher.dispatch(ReadEvent(correlationId: correlation))
        await dispatcher.wait()
        await dispatcher.stop()
    }
}

struct ReadEvent: Event, Codable {
    let correlationId: UUID
    let parentId: UUID?

    init(correlationId: UUID, parentId: UUID? = nil) {
        self.correlationId = correlationId
        self.parentId = parentId
    }
}
