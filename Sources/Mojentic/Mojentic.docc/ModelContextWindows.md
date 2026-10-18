# Discovering model context windows

Read advertised model capacity without changing completion requests.

## Discover capacity and provenance

Call ``LLMGateway/modelContextWindow(model:)`` on the configured gateway:

```swift
let gateway = OllamaGateway()
let advertised = try await gateway.modelContextWindow(model: "qwen3.5:9b")
let config = CompletionConfig(numCtx: nil)
let upperBound = effectiveContextWindow(advertised, config: config)
```

A ``ModelContextWindow`` carries a positive `maxContextTokens` and the provider
`field` that reported it. `nil` means the provider did not advertise a window;
transport failures, HTTP failures and malformed metadata throw `MojenticError`.
Existing gateway conformers inherit `nil` without adding a method.

Ollama uses the configured host and headers for `POST /api/show` with the exact
model identity. Architecture keys ending in `.context_length` supply capacity
and `model_info.<architecture>.context_length` provenance. Optional `parameters`
text supplies `modelNumCtx`, separately from capacity. Invalid limits and malformed
parameter lines throw decoding errors; an unknown model's HTTP 404 remains an error.

oMLX uses the configured host, timeout and API key for `GET /v1/models`. It selects
the entry whose `id` exactly matches the requested model, returning `max_model_len`
provenance. Missing models or absent limits return `nil`; invalid types and
nonpositive limits throw. OpenAI returns an exact registry entry with `registry`
provenance without HTTP. Unknown model IDs return `nil`, even when request shaping
can infer their capabilities. Other gateways inherit the unadvertised result.

## Calculate an Ollama upper bound

``effectiveContextWindow(_:config:)`` returns the smaller of advertised capacity
and the caller's `numCtx`. Without that override it uses the model's `modelNumCtx`,
then advertised capacity. Unknown metadata returns `nil`, even with a configured
limit. The helper is pure: it does not change config or send a request.

`CompletionConfig()` leaves `numCtx` unset by default. Pass `numCtx: nil`
to use the model fallback in this calculation. With neither override nor model
parameter, the advertised result is only an upper bound: the server's
`OLLAMA_CONTEXT_LENGTH` and built-in defaults are invisible to discovery.
Applications can inspect Ollama `/api/ps` after a completion for the loaded size.

Discovery does not cache a limit into later requests or alter list ordering.
Context budgets and application reactions remain caller policy. Client first-token
timing is described in <doc:FirstTokenTiming>. Caller-only parameters are described in <doc:RequestFidelity>.
