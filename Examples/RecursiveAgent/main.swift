import Foundation
import Mojentic

/// Refine a short paragraph in N passes via SimpleRecursiveAgent.
@main
struct RecursiveAgentExample {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let maxRounds = 3
        let agent = SimpleRecursiveAgent(maxDepth: maxRounds) { current, iteration in
            let prompt = """
                Improve the following paragraph for clarity and concision. If it is already
                excellent, reply only with the literal token DONE on a single line.

                Iteration \(iteration) of \(maxRounds).

                ---
                \(current)
                ---
                """
            let response = try await broker.complete(
                model: "gpt-4o-mini",
                messages: [
                    .system("You are an expert editor."),
                    .user(prompt),
                ]
            )
            if response.content.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) == "DONE" {
                return .complete(current)
            }
            return .refine(response.content)
        }
        do {
            let final = try await agent.solve(
                seed: "swift is a language that is fast and modern and safe and easy."
            )
            print("Final paragraph:\n\(final)")
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
