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

## Provider evidence in response traces

Every `.llmResponse` tracer event keeps what the provider reported about the
response. ``LLMResponsePayload`` exposes four optional fields:

| Field | Source | When absent |
| ----- | ------ | ----------- |
| ``LLMResponsePayload/usage`` | usage exactly as the gateway reported it | `nil` |
| ``LLMResponsePayload/providerModel`` | model name the provider reported | `nil` |
| ``LLMResponsePayload/finishReason`` | provider finish reason | `nil` |
| ``LLMResponsePayload/metadata`` | provider response fields such as ids, timestamps and durations | `nil` |

``LLMResponsePayload/model`` stays the model you requested. The fields come
from ``LLMGatewayResponse``, which gains ``LLMGatewayResponse/providerModel``
and ``LLMGatewayResponse/metadata``. The broker fills them for ordinary,
structured (through ``LLMGateway/completeStructured(model:messages:schema:config:)``),
calls. The legacy ``LLMBroker/stream(model:messages:tools:config:context:)``
keeps its existing tracing: finish reason and usage only.

The library never estimates usage from text length or a tokenizer. Unknown
stays unknown.

```swift
let store = EventStore()
let broker = LLMBroker(gateway: gateway, tracer: EventStoreTracer(store: store))
_ = try await broker.complete(model: "gpt-4o", messages: messages)
for case .llmResponse(let payload) in await store.allEvents() {
    print(payload.providerModel ?? "unreported", payload.usage?.totalTokens ?? -1)
}
```
