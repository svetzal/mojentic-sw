import Foundation
import Mojentic

/// Showcase several broker capabilities against OpenAI: plain completion,
/// tool dispatch, and structured output.
@main
struct BrokerExamples {
    struct Person: Codable, Sendable, JSONSchemaProviding {
        let name: String
        let age: Int

        static var jsonSchema: JSONValue {
            [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "age": ["type": "integer"],
                ],
                "required": ["name", "age"],
                "additionalProperties": false,
            ]
        }
    }

    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        let model = "gpt-4o-mini"

        do {
            let plain = try await broker.complete(
                model: model,
                messages: [
                    .system("You are a concise assistant."),
                    .user("Name one type of bird that cannot fly."),
                ]
            )
            print("Plain: \(plain.content)")

            let tooled = try await broker.complete(
                model: model,
                messages: [
                    .system("Use tools when the user asks for the current time."),
                    .user("What time is it right now?"),
                ],
                tools: [CurrentDateTimeTool()]
            )
            print("Tooled: \(tooled.content)")

            let person = try await broker.completeJSON(
                model: model,
                messages: [
                    .system("Extract structured data from the user message."),
                    .user("Bob is 27 years old."),
                ],
                responseType: Person.self
            )
            print("Structured: \(person.name), \(person.age)")
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
