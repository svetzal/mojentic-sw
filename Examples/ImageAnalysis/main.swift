import Foundation
import Mojentic

/// Send a local image to a vision-capable model and print the description.
///
/// Defaults to OpenAI's `gpt-4o-mini`. To run against Ollama instead, swap
/// the gateway for `OllamaGateway()` and use a vision model like `llava`:
///
/// ```swift
/// let broker = LLMBroker(gateway: OllamaGateway())
/// let response = try await broker.complete(
///     model: "llava",
///     messages: [.user(text: "Describe this image.", images: [image])]
/// )
/// ```
@main
struct ImageAnalysis {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("Usage: ImageAnalysis <path-to-image>")
            exit(1)
        }
        let path = URL(fileURLWithPath: arguments[1])
        do {
            let image = try ImageContent.loadingFromDisk(at: path)
            let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
            let response = try await broker.complete(
                model: "gpt-4o-mini",
                messages: [
                    .user(text: "Describe this image in one sentence.", images: [image])
                ]
            )
            print(response.content)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
