import Foundation
import Mojentic

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

@main
struct SimpleStructured {
    static func main() async {
        let broker = LLMBroker(gateway: OllamaGateway())
        let messages: [LLMMessage] = [
            .system("Extract structured data."),
            .user("Alice is 34 years old."),
        ]
        do {
            let person = try await broker.completeJSON(
                model: "llama3.2",
                messages: messages,
                responseType: Person.self
            )
            print("Name: \(person.name), Age: \(person.age)")
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
