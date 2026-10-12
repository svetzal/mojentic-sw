# Completion recovery capabilities

All four completion gateways expose `recoveryCapabilities`; Anthropic requires
its `anthropic` or `full` package trait. Each accessor returns five independent
``RecoveryCapabilitySupport`` values. The table applies to buffered, structured
and streaming completions on the listed endpoint; embeddings and realtime voice
are outside this contract.

`Supported` requires documentation of the facility for the exact endpoint.
`Unsupported` means the inspected endpoint reference describes no such operation.
`Unknown` means the documentation is absent or ambiguous. In particular, omission
of an inference deduplication guarantee leaves idempotency unknown. Exact-attempt
termination always remains unknown: a facility classification, completed response,
local cancellation, or correlation ID does not establish termination of a failed
remote attempt.

## Inspected endpoint evidence

Every row was inspected on October 12, 2026. Local cancellation is an adapter
facility established by [URLSessionTask.cancel()](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
and the cancellation regression tests, rather than a remote endpoint promise.

| Provider | Exact endpoint (POST) | Facility | Support | Evidence source and limit | Inspection date |
| --- | --- | --- | --- | --- | --- |
| Ollama | `/api/chat` | Local request cancellation | supported | [Provider reference](https://docs.ollama.com/api/chat); [URLSessionTask.cancel()](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel()): local task cancellation; no remote guarantee | 2026-10-12 |
| Ollama | `/api/chat` | Remote request cancellation | unsupported | [Provider reference](https://docs.ollama.com/api/chat): no active-request cancellation operation described | 2026-10-12 |
| Ollama | `/api/chat` | Request status | unsupported | [Provider reference](https://docs.ollama.com/api/chat): no active exact-attempt status query described | 2026-10-12 |
| Ollama | `/api/chat` | Idempotency | unknown | [Provider reference](https://docs.ollama.com/api/chat): no inference deduplication guarantee specified | 2026-10-12 |
| Ollama | `/api/chat` | Exact-attempt termination | unknown | [Provider reference](https://docs.ollama.com/api/chat): no evidence for one particular attempt | 2026-10-12 |
| oMLX | `/v1/chat/completions` | Local request cancellation | supported | [Provider reference](https://github.com/jundot/omlx); [URLSessionTask.cancel()](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel()): local task cancellation; no remote guarantee | 2026-10-12 |
| oMLX | `/v1/chat/completions` | Remote request cancellation | unsupported | [Provider reference](https://github.com/jundot/omlx): no active-request cancellation operation described | 2026-10-12 |
| oMLX | `/v1/chat/completions` | Request status | unsupported | [Provider reference](https://github.com/jundot/omlx): no active exact-attempt status query described | 2026-10-12 |
| oMLX | `/v1/chat/completions` | Idempotency | unknown | [Provider reference](https://github.com/jundot/omlx): no inference deduplication guarantee specified | 2026-10-12 |
| oMLX | `/v1/chat/completions` | Exact-attempt termination | unknown | [Provider reference](https://github.com/jundot/omlx): no evidence for one particular attempt | 2026-10-12 |
| OpenAI Chat Completions | `https://api.openai.com/v1/chat/completions` | Local request cancellation | supported | [Provider reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create); [URLSessionTask.cancel()](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel()): local task cancellation; no remote guarantee | 2026-10-12 |
| OpenAI Chat Completions | `https://api.openai.com/v1/chat/completions` | Remote request cancellation | unsupported | [Provider reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create): no active-request cancellation operation described | 2026-10-12 |
| OpenAI Chat Completions | `https://api.openai.com/v1/chat/completions` | Request status | unsupported | [Provider reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create): no active exact-attempt status query described | 2026-10-12 |
| OpenAI Chat Completions | `https://api.openai.com/v1/chat/completions` | Idempotency | unknown | [Provider reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create): no inference deduplication guarantee specified | 2026-10-12 |
| OpenAI Chat Completions | `https://api.openai.com/v1/chat/completions` | Exact-attempt termination | unknown | [Provider reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create): no evidence for one particular attempt | 2026-10-12 |
| Anthropic Messages | `https://api.anthropic.com/v1/messages` | Local request cancellation | supported | [Provider reference](https://platform.claude.com/docs/en/api/messages/create); [URLSessionTask.cancel()](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel()): local task cancellation; no remote guarantee | 2026-10-12 |
| Anthropic Messages | `https://api.anthropic.com/v1/messages` | Remote request cancellation | unsupported | [Provider reference](https://platform.claude.com/docs/en/api/messages/create): no active-request cancellation operation described | 2026-10-12 |
| Anthropic Messages | `https://api.anthropic.com/v1/messages` | Request status | unsupported | [Provider reference](https://platform.claude.com/docs/en/api/messages/create): no active exact-attempt status query described | 2026-10-12 |
| Anthropic Messages | `https://api.anthropic.com/v1/messages` | Idempotency | unknown | [Provider reference](https://platform.claude.com/docs/en/api/messages/create): no inference deduplication guarantee specified | 2026-10-12 |
| Anthropic Messages | `https://api.anthropic.com/v1/messages` | Exact-attempt termination | unknown | [Provider reference](https://platform.claude.com/docs/en/api/messages/create): no evidence for one particular attempt | 2026-10-12 |

The Ollama, oMLX and OpenAI references reuse the sources cited in Rust
`4ca1ed279c02eab37827a1ed07c30e961155ecf3`'s `RECOVERY-CONFORMANCE.md`, inspected
there on October 10 and inspected again for this table on October 12, 2026.
Anthropic uses its official Messages create reference.

## Limits

Request status here means the status of the exact active attempt, not retrieval
of a stored OpenAI completion. OpenAI Responses cancellation and Anthropic batch
management are different endpoints. Ollama unload and loaded-model lists and
oMLX activity describe models or aggregate work; none prove that this attempt
ended. Local HTTP cancellation proves no remote termination.

Capability reporting does not change recovery admission or implement a remote
facility. No idempotency header, model unload, process termination or tool replay
is added. Logical and wire IDs provide correlation only.
