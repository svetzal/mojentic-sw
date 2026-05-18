import Foundation
import Mojentic

@main
struct SimpleTool {
    static func main() async {
        let broker = LLMBroker(gateway: OllamaGateway())
        let tools: [any LLMTool] = [DateResolverTool()]
        let messages: [LLMMessage] = [
            .system("Use the resolve_date tool whenever the user asks about dates."),
            .user("What is the date next Friday?"),
        ]
        do {
            let response = try await broker.complete(
                model: "llama3.2",
                messages: messages,
                tools: tools
            )
            print(response.content)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
