// AnthropicSimple — single completion against the Anthropic Messages API.
//
// Requires the `anthropic` package trait to be enabled. With this monorepo's
// `Package.swift` the trait is gated via:
//
//   .package(url: "...", traits: ["anthropic"])  // or ["full"]
//
// and built from source with:
//
//   swift build --traits full
//
// Skips gracefully when the ANTHROPIC_API_KEY env var is missing so the
// example product compiles cleanly on every CI run.

import Foundation
import Mojentic

@main
struct AnthropicSimple {
    static func main() async {
        #if anthropic
            guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
                print("Set ANTHROPIC_API_KEY (and build with --traits anthropic) to run this example.")
                return
            }
            let broker = LLMBroker(gateway: AnthropicGateway(apiKey: key))
            do {
                let response = try await broker.complete(
                    model: "claude-3-5-haiku-latest",
                    messages: [
                        .system("Reply in one short sentence."),
                        .user("Name one fact about Anthropic's headquarters."),
                    ]
                )
                print(response.content)
            } catch {
                print("Error: \(error)")
                exit(1)
            }
        #else
            print("AnthropicSimple requires the `anthropic` package trait. Build with --traits full.")
        #endif
    }
}
