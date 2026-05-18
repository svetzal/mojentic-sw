import Foundation
import Mojentic

/// Interactive task manager demo: the model can add, list, complete, and
/// remove tasks via the bundled tools.
@main
struct EphemeralTaskManagerExample {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let manager = EphemeralTaskManager()
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let session = ChatSession(
            broker: broker,
            model: "gpt-4o-mini",
            systemPrompt:
                "You are a task assistant. Use the task tools to manage the user's to-do list.",
            tools: manager.toolBundle()
        )
        print("Task manager ready. Blank line to quit.")
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
