import Foundation
import Mojentic

/// ReAct loop answering a date-relative question using DateResolverTool +
/// CurrentDateTimeTool.
@main
struct ReActExample {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let agent = ReActAgent(
            broker: broker,
            model: "gpt-4o-mini",
            tools: [CurrentDateTimeTool(), DateResolverTool()],
            maxSteps: 6
        )
        do {
            let outcome = try await agent.run("What day was last Tuesday?")
            if outcome.converged {
                print("Answer: \(outcome.answer)")
            } else {
                print("ReAct did not converge within the step cap.")
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
