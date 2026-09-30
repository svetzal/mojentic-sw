# Local models with oMLX

Run models on Apple Silicon through an oMLX server with ``OMLXGateway``.

## Overview

[oMLX](https://github.com/jundot/omlx) is an LLM server for Apple Silicon. It
speaks the OpenAI chat completions protocol, but ``OpenAIGateway`` is not the
right way to reach it. The OpenAI gateway shapes each request for the OpenAI
model it thinks it is talking to, and it reads no reasoning traces.
``OMLXGateway`` sends every configured parameter unchanged, whatever the model
is called. It also reads the reasoning trace and manages which models are in
memory.

```swift
import Mojentic

let broker = LLMBroker(gateway: OMLXGateway())
let response = try await broker.complete(
    model: "Qwen3.8-27B-MLX-8bit",
    messages: [.user("Name one fact about the moon.")]
)
print(response.content)
```

The `OMLXChat` example (`swift run OMLXChat`) runs one turn against a local
server and prints the thinking, the answer and the finish reason.

## Configuration

Each setting takes the explicit initializer value, then the environment
variable, then the default:

| Parameter | Environment | Default |
| --------- | ----------- | ------- |
| `host` | `OMLX_HOST` | `http://localhost:8000` |
| `apiKey` | `OMLX_API_KEY` | none |
| `timeout` (seconds) | `OMLX_TIMEOUT` (milliseconds) | 600 seconds |

- Give the host without `/v1`. The gateway adds `/v1` to every path.
- With an API key, requests carry `Authorization: Bearer <key>`. Without one,
  they carry no `Authorization` header.
- One timeout covers every request, including a model load. Local models are
  slow: a long reply at 16 tokens a second can take many minutes, so the
  default is longer than a hosted provider needs.
- An empty environment variable counts as unset. An `OMLX_TIMEOUT` that is
  not a positive number, or an `OMLX_HOST` that is not a URL, falls back to
  the default.

## Request parameters

The chat request carries ``CompletionConfig`` fields as follows:

| Config | Request body |
| ------ | ------------ |
| ``CompletionConfig/temperature`` | `temperature` |
| ``CompletionConfig/maxTokens`` | `max_tokens`, always. Never `max_completion_tokens` |
| ``CompletionConfig/topP`` | `top_p`, when set |
| ``CompletionConfig/reasoning`` | `reasoning_effort` (`low`, `medium` or `high`), when set |
| ``CompletionConfig/responseFormat`` | `response_format`, as for OpenAI |
| ``CompletionConfig/extraOptions`` | forwarded verbatim, for example `top_k` |
| ``CompletionConfig/numCtx`` | not sent. oMLX sets the context length per model |

`reasoning_effort` goes to the model's chat template, so its effect depends on
the model. Leave ``CompletionConfig/reasoning`` `nil` to keep the model's
default. Qwen 3 models think by default.

## Thinking

oMLX returns the model's reasoning in `reasoning_content`. The gateway puts it
in ``LLMGatewayResponse/thinking``, and the broker passes it on as
``LLMResponse/thinking``. A response without reasoning has `nil` thinking.
``OMLXGateway/stream(model:messages:tools:config:)`` yields reasoning as
``GatewayStreamEvent/thinkingDelta(_:)``. The single-turn events API has no
thinking event, so reasoning produces no events there.

### Truncation during thinking

When `max_tokens` ends generation while the model is still thinking, a
non-streaming response puts the partial reasoning in `content`, leaves
`thinking` `nil`, and reports ``FinishReason/length``. A streaming response
keeps the partial reasoning as thinking. The gateway maps the fields as they
arrive and does not move text between them.

Content is not an answer when the finish reason is not ``FinishReason/stop``.
Check ``LLMGatewayResponse/finishReason`` before you use it.

## Structured output

``OMLXGateway/completeStructured(model:messages:schema:config:)`` sends
`{"type": "json_schema", "json_schema": {"name": "response", "schema": …}}`
and decodes the content as JSON.

When oMLX cannot compile a grammar for the schema, it degrades the request to
prompt instructions and says so in a `Warning` response header. When a request
asked for structured output (the structured API, or a
``ResponseFormat/jsonObject`` or ``ResponseFormat/jsonSchema(_:)`` response
format) and the response has that header, the gateway:

- records the header value in ``LLMGatewayResponse/metadata`` under
  ``OMLXGateway/responseFormatWarningKey`` (`response_format_warning`), with
  several `Warning` headers joined by `,`
- logs a warning

It does not retry or fail. The header is evidence that the output was not
enforced, so validate the content yourself. Text and absent response formats
ignore the header.

## Usage and metadata

``LLMGatewayResponse/usage`` holds the prompt, completion and total token
counts oMLX reports. oMLX reports more (for example `model_load_duration`,
`time_to_first_token` and `prompt_tokens_details`). Non-streaming responses
keep the whole `usage` object, exactly as reported, in
``LLMGatewayResponse/metadata`` under `usage`. Usage is never estimated.

## Streaming

``OMLXGateway/completeStreamEvents(model:messages:config:)`` supports the
single-turn events API with the OpenAI completion rules: success needs
`finish_reason: "stop"` and `data: [DONE]`. See <doc:StreamingAndEvidence>.

oMLX opens every chat stream with a keep-alive frame, a `data:` line whose
`model` is `keepalive`, and sends more during long prefill. The gateway drops
these frames in both streaming APIs, so `keepalive` never appears as the
provider model.

## Models

``OMLXGateway/availableModels()`` lists the models the server can serve.
``OMLXGateway/loadModel(_:)`` blocks until a model is in memory, and
``OMLXGateway/unloadModel(_:)`` removes it. A chat request loads its model
automatically, so load is for warming a model up ahead of time. Unloading a
model that is not loaded is a 400 error. oMLX downloads models only through its
admin dashboard; there is no pull.

## Embeddings

``OMLXGateway`` is also an ``EmbeddingsGateway``. oMLX has no standard
embedding model, so the model is required: an empty model throws
``MojenticError/invalidArgument(message:)`` before any request. Each text goes
whole in its own request, with no client-side chunking. A chat model is
rejected by the server with a 400 error.

```swift
let vector = try await OMLXGateway().embed(text: "hello", model: "bge-small-en-v1.5-mlx")
```

## Errors

oMLX errors use the OpenAI shape. A non-2xx response throws
``MojenticError/http(status:body:)`` with the status and the error body, for
example 401 for a missing or wrong API key and 404 for an unknown model. In
the events API it is ``MojenticError/providerError(status:detail:)`` with the
status, and with the body where the platform's streaming transport exposes it.

Passing an explicit empty `apiKey` disables authentication, even when
`OMLX_API_KEY` is set in the environment.
