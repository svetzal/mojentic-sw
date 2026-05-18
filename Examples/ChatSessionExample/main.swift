import Foundation
import Mojentic

/// Multi-turn interactive chat backed by OpenAI. Reads lines from stdin and
/// prints assistant turns until the user enters a blank line.
@main
struct ChatSessionExample {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let session = ChatSession(
            broker: broker,
            model: "gpt-4o-mini",
            systemPrompt: "You are a concise and helpful assistant."
        )

        print("Chat session ready. Enter blank line to quit.")
        while true {
            print("you> ", terminator: "")
            guard let line = readLine(), !line.isEmpty else { break }
            do {
                let response = try await session.send(line)
                print("ai> \(response.content)")
            } catch {
                print("error: \(error)")
                break
            }
        }
    }
}
