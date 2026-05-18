import Foundation
import Mojentic

/// Wrap a summariser broker as a tool, then ask a parent broker a question
/// that invokes the summariser tool.
@main
struct BrokerAsTool {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let gateway = OpenAIGateway(apiKey: key)
        let innerBroker = LLMBroker(gateway: gateway)
        let summariser = ToolWrapper(
            broker: innerBroker,
            model: "gpt-4o-mini",
            name: "summarise_text",
            description: "Summarise the supplied text in one sentence.",
            systemPrompt: "You are a concise summariser. Reply in one short sentence."
        )
        let parentBroker = LLMBroker(gateway: gateway)
        let longText = """
            The history of Swift dates back to 2014 when Apple introduced it as a modern alternative
            to Objective-C. Over subsequent releases the language gained generics improvements,
            value-type collections, async/await, and a strict concurrency model.
            """
        do {
            let response = try await parentBroker.complete(
                model: "gpt-4o-mini",
                messages: [
                    .system("Use summarise_text to condense any long passage the user provides."),
                    .user("Please summarise: \(longText)"),
                ],
                tools: [summariser]
            )
            print(response.content)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
