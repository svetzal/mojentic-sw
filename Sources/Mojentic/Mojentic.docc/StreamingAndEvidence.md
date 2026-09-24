# Streaming and completion evidence

Request an output format in any call, and keep the provider's own evidence
about each response.

## Structured output in streaming requests

Set ``CompletionConfig/responseFormat`` to ask the provider for a specific
output format. The gateways forward it in ordinary and streaming requests in
the same way:

```swift
let config = CompletionConfig(responseFormat: .jsonSchema(schema))
for try await event in broker.stream(model: "gpt-4o", messages: messages, config: config) {
    // ...
}
```

| Value | OpenAI-compatible request | Ollama request |
| ----- | ------------------------- | -------------- |
| `nil` | unchanged | unchanged |
| ``ResponseFormat/text`` | `response_format: {type: "text"}` | no `format` |
| ``ResponseFormat/jsonObject`` | `response_format: {type: "json_object"}` | `format: "json"` |
| ``ResponseFormat/jsonSchema(_:)`` | `response_format: {type: "json_schema", json_schema: {name: "response", schema: …}}` | `format: <schema>` |

The field records what you requested. It is not proof that the provider
enforced it, so validate the content you receive. ``LLMBroker/completeJSON(model:messages:responseType:config:context:)``
derives its own schema from the response type and ignores this field. The
Anthropic gateway has no equivalent request field and ignores it.
