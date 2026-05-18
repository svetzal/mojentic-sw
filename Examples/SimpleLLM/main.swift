import Foundation
import Mojentic

@main
struct SimpleLLM {
    static func main() async {
        let broker = LLMBroker(gateway: OllamaGateway())
        let messages: [LLMMessage] = [
            .system("You are a concise assistant."),
            .user("In one sentence, what is the colour of the sky on a clear day?"),
        ]
        do {
            let response = try await broker.complete(model: "llama3.2", messages: messages)
            print(response.content)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
