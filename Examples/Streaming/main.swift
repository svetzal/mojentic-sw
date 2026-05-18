import Foundation
import Mojentic

@main
struct Streaming {
    static func main() async {
        let broker = LLMBroker(gateway: OllamaGateway())
        let messages: [LLMMessage] = [
            .system("You are a concise assistant."),
            .user("Write a haiku about Swift programming."),
        ]
        let stream = broker.stream(model: "llama3.2", messages: messages)
        do {
            for try await event in stream {
                switch event {
                case .textDelta(let chunk):
                    print(chunk, terminator: "")
                    fflush(stdout)
                case .done:
                    print("")
                default:
                    break
                }
            }
        } catch {
            print("\nError: \(error)")
            exit(1)
        }
    }
}
