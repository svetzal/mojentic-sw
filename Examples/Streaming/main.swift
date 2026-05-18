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
                    // Write deltas via FileHandle to avoid the C-global `stdout`
                    // (not Sendable on Linux). Trades on-the-fly flushing for
                    // portability — fine for an example.
                    try? FileHandle.standardOutput.write(contentsOf: Data(chunk.utf8))
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
