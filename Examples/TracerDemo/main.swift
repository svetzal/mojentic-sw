import Foundation
import Mojentic

/// Run a broker call against Ollama, capturing every event in an
/// EventStore-backed tracer, then print the event tree for the call's
/// correlation id.
@main
struct TracerDemo {
    static func main() async {
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        let broker = LLMBroker(
            gateway: OllamaGateway(),
            tracer: tracer
        )
        let context = TracerContext()
        do {
            _ = try await broker.complete(
                model: "llama3.2",
                messages: [
                    .system("Be brief."),
                    .user("Say hello in one word."),
                ],
                context: context
            )
        } catch {
            print("LLM call failed (this is fine if Ollama isn't running): \(error)")
        }
        let events = await store.events(correlatedTo: context.correlationId)
        print("Correlation: \(context.correlationId.uuidString)")
        print("Event tree (\(events.count) events):")
        for event in events {
            print(" - \(describe(event))")
        }
    }

    static func describe(_ event: TracerEvent) -> String {
        switch event {
        case .llmCall(let payload):
            return "llmCall model=\(payload.model) parent=\(payload.parentId?.uuidString ?? "-")"
        case .llmResponse(let payload):
            return "llmResponse duration=\(payload.duration)"
        case .toolCall(let payload):
            return "toolCall name=\(payload.name)"
        case .toolResult(let payload):
            return "toolResult ok=\(payload.outcome.ok)"
        case .toolBatch(let payload):
            return "toolBatch count=\(payload.count) duration=\(payload.duration)"
        case .agentLifecycle(let payload):
            return "agent=\(payload.agentName) phase=\(payload.phase.rawValue)"
        }
    }
}
