// OMLXChat — one chat turn against a local oMLX server.
//
// The gateway reads its configuration from the environment:
//
//   OMLX_HOST     server address without /v1 (default http://localhost:8000)
//   OMLX_API_KEY  bearer token, when the server requires one
//   OMLX_TIMEOUT  request timeout in milliseconds (default 600000)
//
// Set OMLX_MODEL to pick a model; otherwise the example uses the first model
// the server lists. Run with:
//
//   swift run OMLXChat

import Foundation
import Mojentic

@main
struct OMLXChat {
    static func main() async {
        let gateway = OMLXGateway()
        do {
            let model = try await chooseModel(gateway)
            print("Model: \(model)")
            let broker = LLMBroker(gateway: gateway)
            let response = try await broker.complete(
                model: model,
                messages: [
                    .system("You are a concise assistant."),
                    .user("In one sentence, why is the sky blue?"),
                ]
            )
            if let thinking = response.thinking {
                print("Thinking:\n\(thinking)\n")
            }
            print("Answer:\n\(response.content)\n")
            print("Finish reason: \(response.finishReason?.rawValue ?? "unreported")")
            if response.finishReason != .stop {
                print("The model did not finish; the content is not an answer.")
            }
            if let usage = response.usage {
                print("Tokens: \(usage.promptTokens ?? 0) in, \(usage.completionTokens ?? 0) out")
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    static func chooseModel(_ gateway: OMLXGateway) async throws -> String {
        if let model = ProcessInfo.processInfo.environment["OMLX_MODEL"], !model.isEmpty {
            return model
        }
        guard let first = try await gateway.availableModels().first else {
            throw MojenticError.invalidArgument(message: "The oMLX server lists no models; set OMLX_MODEL")
        }
        return first
    }
}
