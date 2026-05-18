import Foundation
import Mojentic

/// Instantiate an AsyncLLMAgent, dispatch a TextEvent through it, and print
/// the resulting LLMResponseEvent's content.
@main
struct AsyncLLMExample {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let agent = AsyncLLMAgent(
            broker: broker,
            model: "gpt-4o-mini",
            systemPrompt: "Reply in one short sentence."
        )
        do {
            let events = try await agent.handle(
                TextEvent(content: "Name one fact about the moon.")
            )
            for event in events {
                if let response = event as? LLMResponseEvent {
                    print(response.response.content)
                }
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
