import Foundation
import Mojentic

/// Wire IterativeProblemSolver behind a ChatSession-style REPL: each user
/// turn is solved iteratively and the summary is appended to a session
/// transcript.
@main
struct SolverChatSession {
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
        print("Solver-backed session. Blank line to quit.")
        while true {
            print("you> ", terminator: "")
            guard let line = readLine(), !line.isEmpty else { break }
            do {
                let outcome = try await solver.solve(line)
                print("ai> [\(outcome.iterations)x] \(outcome.summary)")
            } catch {
                print("error: \(error)")
                break
            }
        }
    }
}
