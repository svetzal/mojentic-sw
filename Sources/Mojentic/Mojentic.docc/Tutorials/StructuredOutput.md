#  Structured Output

Decode LLM responses into your own `Codable` types with provider-specific
JSON-schema routing under the hood.

## Overview

### Why

Free-text responses are great for chat, useless for downstream code. When
the LLM is producing data your program will consume, you want typed
values you can switch on, not strings you have to parse.

### When

Use ``LLMBroker/completeJSON(model:messages:responseType:config:context:)``
whenever the response should be a structured value (entity extraction,
classification, planning steps, API arguments).

### How

#### 1. Define a Codable type

```swift
import Mojentic

struct Person: Codable, Sendable {
    let name: String
    let age: Int
}
```

#### 2. Help the schema generator (optional but recommended)

For types whose properties are all required (no defaults visible to the
Codable synthesizer), conform to ``JSONSchemaSampleProviding``:

```swift
extension Person: JSONSchemaSampleProviding {
    static var jsonSchemaSample: Person { Person(name: "", age: 0) }
}
```

Or provide the schema directly via ``JSONSchemaProviding``:

```swift
extension Person: JSONSchemaProviding {
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
```

#### 3. Ask the broker

```swift
let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
let person = try await broker.completeJSON(
    model: "gpt-4o-mini",
    messages: [
        .system("Extract structured data."),
        .user("Alice is 34."),
    ],
    responseType: Person.self
)
print(person.name)  // "Alice"
```

The broker derives the JSON schema and hands it to the gateway. OpenAI
uses native `response_format: json_schema` on supporting models;
Anthropic instructs the model to emit JSON and parses the result;
Ollama uses its `format` field.

## Known Limitations

- The fallback `Mirror`-based inference works for simple structs whose
  properties are all `Codable`-decodable from an empty JSON object. For
  anything more complex, conform to ``JSONSchemaSampleProviding`` (sample
  instance) or ``JSONSchemaProviding`` (explicit schema).
- Anthropic does not currently ship a native `json_schema` response
  format; the gateway falls back to schema-instructed extraction.

## See Also

- ``LLMBroker/completeJSON(model:messages:responseType:config:context:)``
- ``JSONValue``
- ``JSONSchemaProviding``
- ``JSONSchemaSampleProviding``
- ``JSONSchemaGenerator``
