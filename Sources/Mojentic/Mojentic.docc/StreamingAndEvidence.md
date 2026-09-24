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
| ``LLMResponsePayload/finishReason`` | provider finish reason, the raw string as reported | `nil` |
| ``LLMResponsePayload/metadata`` | provider response fields such as ids, timestamps and durations | `nil` |

``LLMResponsePayload/model`` stays the model you requested. The fields come
from ``LLMGatewayResponse``, which gains ``LLMGatewayResponse/providerModel``
and ``LLMGatewayResponse/metadata``; the raw finish reason comes from
``LLMGatewayResponse/providerFinishReason``, and the typed mapping stays at
``LLMGatewayResponse/finishReason``. The broker fills them for ordinary
calls, structured calls (through
``LLMGateway/completeStructured(model:messages:schema:config:)``), and the
single-turn event stream described below, where `metadata` is the provider
metadata from the terminal event. The legacy
``LLMBroker/stream(model:messages:tools:config:context:)`` keeps its existing
tracing: finish reason and usage only.

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

## Single-turn streaming with terminal completion evidence

Use ``LLMBroker/generateStreamEvents(model:messages:config:context:)`` when
unfinished output must never be treated as an answer. It streams one turn,
with no tools, and ends with proof of completion or an error:

```swift
var text = ""
for await event in broker.generateStreamEvents(model: "qwen3", messages: messages) {
    switch event {
    case .content(let delta):
        text += delta
    case .completed(let evidence):
        print("done:", evidence.finishReason ?? "?", evidence.usage?.totalTokens ?? -1)
        use(text)
    case .error(let error):
        print("not complete:", error)  // `text` is evidence, not a result
    }
}
```

The stream is an `AsyncStream` of ``CompletionStreamEvent``, not an
`AsyncThrowingStream`. Failures arrive as the terminal
``CompletionStreamEvent/error(_:)`` event, so the end of every stream is
explicit:

- ``CompletionStreamEvent/content(_:)``: visible assistant content, in order.
- ``CompletionStreamEvent/completed(_:)``: terminal success, with
  ``CompletionEvidence`` (finish reason as reported, usage, provider model and
  provider metadata; each `nil` when unreported).
- ``CompletionStreamEvent/error(_:)``: terminal failure.

Exactly one terminal event ends every stream. Nothing follows it. Content
yielded before an error is evidence of what the provider sent, not a result.

### Completion rules

| Situation | Terminal event |
| --------- | -------------- |
| OpenAI: `finish_reason: "stop"` and `data: [DONE]` | `completed` |
| OpenAI: `[DONE]` with any other finish reason | ``MojenticError/incompleteCompletion(_:)`` with the evidence |
| Ollama: final frame with `done: true` and `done_reason: "stop"` | `completed` |
| Ollama: final frame with any other `done_reason`, or none | ``MojenticError/incompleteCompletion(_:)`` with the evidence |
| End of stream without a terminal marker | ``MojenticError/incompleteStream(_:)`` with any evidence that arrived first |
| Provider error frame, or a non-2xx HTTP status | ``MojenticError/providerError(status:detail:)`` |
| Connection or body read failed | ``MojenticError/requestFailed(message:)`` |
| Native tool call in the stream | ``MojenticError/unexpectedToolCalls`` |
| Malformed frame | ``MojenticError/invalidStreamEvent(message:)`` |
| Gateway without support (Anthropic, custom gateways) | ``MojenticError/streamEventsUnsupported`` |

Ollama servers too old to send `done_reason` cannot use this API: every
stream from them ends as an incomplete completion.

### Behaviour

- One HTTP request. The broker forces `maxToolIterations` to zero and never
  retries or recurses.
- Stopping consumption cancels the request: break out of the loop over the
  stream, drop every reference to the stream, or cancel the consuming task.
  An `AsyncStream` ends when neither the stream value nor its iterator is
  referenced, so a stream held in a variable stays open until that variable
  goes out of scope.
- An unsupported gateway yields a single
  ``MojenticError/streamEventsUnsupported`` event. It sends no request and
  records no trace. Gateways opt in by implementing
  ``LLMGateway/completeStreamEvents(model:messages:config:)``, whose default
  throws that error before any request.
- The tracer records the call when the gateway accepts the request, and the
  response (content so far plus the evidence from the terminal event) when the
  terminal event is reached. When the consumer stops early the call stays
  traced and no response is recorded. That is not an error.
- The configured ``CompletionConfig/responseFormat`` is forwarded as in any
  other request. OpenAI requests also set
  `stream_options: {include_usage: true}` so usage arrives before `[DONE]`.
