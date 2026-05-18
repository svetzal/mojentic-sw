import Foundation
import Mojentic

/// Drive an IterativeProblemSolver against a small task and print the
/// summary.
@main
struct IterativeSolverExample {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let solver = IterativeProblemSolver(
            broker: broker,
            model: "gpt-4o-mini",
            maxIterations: 3
        )
        do {
            let outcome = try await solver.solve(
                "Count the vowels in the sentence 'The quick brown fox jumps over the lazy dog.'"
            )
            print(
                "Iterations: \(outcome.iterations) (stop reason: \(outcome.stopReason.rawValue))"
            )
            print("Summary: \(outcome.summary)")
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
