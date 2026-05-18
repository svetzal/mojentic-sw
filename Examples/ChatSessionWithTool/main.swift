import Foundation
import Mojentic

/// Multi-turn interactive chat with tool calling. Wires
/// `CurrentDateTimeTool` and `DateResolverTool` into a `ChatSession`.
@main
struct ChatSessionWithTool {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let session = ChatSession(
            broker: broker,
            model: "gpt-4o-mini",
            systemPrompt: "Use the time and date tools whenever the user asks about now or relative dates.",
            tools: [CurrentDateTimeTool(), DateResolverTool()]
        )

        print("Chat session with tools ready. Try 'what is next Friday'. Blank line to quit.")
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
