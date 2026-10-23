# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Major and minor versions are synchronised with the other Mojentic ports
(`mojentic-py`, `mojentic-ts`, `mojentic-ex`, `mojentic-ru`); patch versions
move independently.

## [Unreleased]

### Changed

- Remove the Google osv-scanner requirement and Supply Chain workflow. Record
  the pinned SwiftPM inventory and native tooling review in `AGENTS.md`; no
  suitable native automated advisory check was identified. Native quality gates
  remain required and do not prove dependency safety.

- **Dependencies**: `swift-log` 1.16.1 → 1.16.2 in `Package.resolved`. The
  `Package.resolved` digest in the context-window and request-fidelity contract
  manifests moves with the lockfile; no contract source changed.

- Isolate in-process HTTP fixtures and recovery session configurations so parallel
  conformance tests cannot share sessions or globally registered protocols.

- Completion conformance tests now use in-process HTTP and line transports,
  injected timing and explicit cancellation handshakes. Retain recovery,
  reasoning, request identity and privacy assertions without sockets or sleeps.
- Add an internal Anthropic streaming transport injection point; public
  initialization and production dispatch behavior are unchanged.
- Verify executable contract manifests in both test gates, remove server-based
  packaged/example probes, and bound every CI job with a timeout.

### Fixed

- The Swift 6.1 minimum CI job verifies committed contract inputs, then resolves
  compatible dependencies from the manifest without the stable-toolchain
  lockfile before running all provider tests and the debug build. The tracked
  Swift 6.4 pins and declared Swift 6.1 minimum are unchanged.
- The in-process HTTP test fixture reads request bodies from `httpBodyStream`
  when `httpBody` is nil. Darwin's URLSession moves the body there, so macOS
  test runs captured empty requests.
- The deterministic-test guard and the contract manifest verifier are POSIX sh
  scripts. The Linux CI containers have no python3, so the test gates exited
  with status 127 before they ran the tests.

## [3.0.0] - 2026-10-18

### Added — client streaming timing

- Built-in streams report first-token kind, milliseconds from actual first
  dispatch, and terminal duration on success and failure.
  Thinking wins over content and tool arguments within a frame; the first
  argument fragment counts before assembly. Empty frames and keepalives do not.
- Admitted retries share one monotonic origin. Tool continuations start fresh
  clocks. Concurrent completions have independent measurements. Provider metrics
  retain their original values and units alongside client fields.
- Production legacy HTTP streams observe progressive responses on Linux and
  Darwin before parsing and tool assembly. They retain the configured URLSession,
  its authentication and pool, and the original request payloads. Encoding errors
  before dispatch retain their original typed error without client timing.
- Anthropic initial `tool_use.input: {}` does not start timing. The first
  nonempty `input_json_delta` starts `tool_call` timing. Successful zero-argument
  calls without fragments retain duration with both first-token fields absent.

### Breaking changes and migration — streaming evidence

- Gateway `done` events add a third `evidence` associated value, defaulting to
  `nil` for existing event constructors. Update pattern matches to three values.
- Broker/session `StreamEvent` adds `metrics(CompletionEvidence)` for each
  completed provider turn; final `LLMResponse.metadata` carries the final turn's
  metadata. Older Codable responses decode with metadata absent.
- Streaming errors retain timing in `StreamFailure.evidence` and their original
  typed cause in `StreamFailure.cause`. Throwing streams and single-turn error
  events use the new `MojenticError.streamFailure` case. Update exhaustive switches
  and inspect the cause when matching earlier error cases. Recovery errors retain their type,
  outcome, cause and history, with additional `RecoveryError.evidence`.
  Recovery reports also retain terminal evidence when cancellation stops iteration.

### Breaking changes and migration — request fidelity

- `CompletionConfig.temperature` and `maxTokens` are optional; both and
  `numCtx` default to `nil`. Read numeric values with optional handling.
  Legacy Codable records retain explicit numeric values; absent/null request
  fields stay unset. To restore previous requests, use
  `CompletionConfig(temperature: 1.0, maxTokens: 16384, numCtx: 32768)`.
- Ollama now inherits model/server context, sampling and output settings.
  With neither configured, Ollama's built-in context can be smaller and output
  can be unlimited, so looping generations may run longer. `maxTokens` remains
  the single output limit, mapped to `options.num_predict`.
- OpenAI and oMLX omit unset output limits and temperature. OpenAI reasoning
  models keep `max_completion_tokens`; other models keep `max_tokens`.
  OpenAI may generate more tokens and cost more without an explicit output cap.
  Caller-set temperature is rewritten to a model's only allowed value; models
  accepting no temperature omit it. Unsupported reasoning effort warns and drops.
- Anthropic requires `max_tokens`: use the exact registered output maximum
  when known, otherwise 4096. The thinking budget remains
  `max(1024, effectiveMaxTokens / 4)`, using that same resolved limit.
- ChatSession reserves only an explicit `maxTokens` during context trimming,
  or zero when unset. It does not synthesize provider parameters.
- Production HTTP encoding uses sorted JSON object keys. Discovery preserves
  complete captured body bytes across ordinary, JSON, structured and both
  streaming APIs for Ollama, oMLX and OpenAI with unset and explicit configs.

### Fixed — registered Anthropic output limits

- Complete exact output metadata for all registered Claude 3.x IDs and aliases:
  Claude 3 Haiku/Opus use 4096, Claude 3.5 Haiku/Sonnet use 8192, and Claude
  3.7 Sonnet uses 64000. Include the known 3.7 dated alias. Explicit `maxTokens`
  still wins; unknown IDs keep 4096. Thinking budgets use the resolved limit.
- Extend request-fidelity-v1 public URLSession and fresh packaged-consumer
  verification across the registered set, with named default/explicit cases.
  Assert the actual unsupported-reasoning warning as well as payload omission;
  a warning-suppression mutation must fail the regression.

### Added — context-window discovery

- `LLMGateway.modelContextWindow(model:)` returns advertised capacity and field
  provenance, `nil` when unadvertised, or existing typed provider/transport errors.
  Existing conformers inherit `nil`; no implementation changes are required.
- Configured Ollama `/api/show` preserves architecture provenance and separates
  optional model `num_ctx` from capacity. Authenticated oMLX `/v1/models` selects
  the exact model. OpenAI uses exact registry entries without HTTP or inferred
  model profiles.
- `effectiveContextWindow(_:config:)` computes Ollama's upper bound using caller,
  model, then advertised limits. The default config now considers model defaults.
  Discovery never applies limits to later requests.

### Breaking changes and migration (native reasoning)

- `ReasoningEffort` adds `.disabled`, `.enabled` and `.xhigh`. Update exhaustive
  switches. Ollama now sends exact booleans for disabled/enabled and exact
  strings for low/medium/high/xhigh; named effort no longer means `think: true`.
  To preserve the old boolean enable behavior, select `.enabled` explicitly.
- oMLX sends boolean controls through `chat_template_kwargs.enable_thinking`
  and named levels through `reasoning_effort`. Omitted effort remains unknown.
- Select `CompletionConfig.reasoningProfile` explicitly for model validation;
  `.qwen38` supports disabled/low/medium/xhigh and native history. Model names
  never select a profile. Unsupported controls fail before HTTP or tool dispatch.
  OpenAI and Anthropic retain legacy low/medium/high behavior and reject the new
  controls, model profiles and retention requests explicitly.
- Set `CompletionConfig.retainThinking = true` to retain completed native
  assistant/tool exchanges in broker continuations and ChatSession history.
  Reasoning stays separate from visible content and tool results. Cancellation,
  failed continuations and unfinished streams never commit native history.
  oMLX requests `chat_template_kwargs.preserve_thinking`; server overrides can
  still prevent preservation. Defaults continue to discard retained reasoning.

- **Dependencies**: `swift-log` 1.15.1 → 1.16.1 in `Package.resolved`. The
  `Package.swift` constraint is unchanged.

### Changed

- Recovery failures, evidence, wire captures, errors and reports now expose only
  safe children through `CustomReflectable`, including nested failure histories
  and public streaming failure events. Default reflection and `dump` omit raw
  headers, URLs, body bytes and causes while retaining exact safe metadata and
  identities. Explicit evidence inspection and wire associated values retain
  their original headers, bytes and typed causes.

- Recovery failures, admission observations and lifecycle events now expose
  closed `RecoveryProvider` and `RecoveryOperation` enums. All four adapters
  share `ordinary`, `structured` and `streaming` operation values. OpenAI and
  Anthropic buffered operation JSON changes from `complete`/`completeStructured`
  to `ordinary`/`structured`; unknown values and old aliases are rejected when
  decoding. Request bytes, recovery routing and legacy behavior are preserved.

### Added

- Opt-in completion recovery for Ollama, oMLX, OpenAI Chat Completions and
  Anthropic Messages via `CompletionRecoveryPolicy` and recovery streaming APIs.
  Recovery owns one frozen, encoded provider request, with bounded attempts,
  jitter/backoff and Retry-After, caller admission, safe lifecycle summaries,
  typed `RecoveryError` evidence and separate observed/delivered progress.
  Cancellation is authoritative; failed semantic output, capture failure and
  malformed responses cannot replay. Recovery never restarts agents, replays
  broker loops or repeats tool actions. Budgets limit recovery waits, not active
  generation. Local cancellation, keepalive and timeouts do not prove remote
  termination or idempotency; dispatched acceptance remains unknown. Ollama and
  oMLX need explicit admission after ambiguous failures; a configured hook controls
  every provider, and pending or empty admission never permits a resend.
- Runnable `RecoveryExample` with scripted loopback acceptance and complete
  instructions in `Examples/RecoveryExample/README.md`.

- Recovery stream progress and metrics events now carry the wire attempt's
  `RecoveryIdentity` and a one-based `frameIndex` that resets for each attempt.
  Both are `nil` outside recovery telemetry. `RecoveryIdentity` is now
  `Hashable`.

### Breaking changes (authorized recovery contract)

- Recovery-enabled buffered, broker and session calls expose `RecoveryError`;
  throwing recovery streams throw it, while single-turn recovery event streams
  deliver `.recoveryFailure`. Invalid recovery limits still throw
  `MojenticError.invalidArgument` through buffered and throwing APIs; single-turn
  recovery event streams deliver `.error(.invalidArgument(...))`. Both occur
  before dispatch. Legacy entrypoints retain one-send behavior; streaming error
  migration is described above. Recovery length-limit responses are terminal typed
  failures rather than successful partial completions.
- Recovery provider/operation metadata uses closed enums, including the
  `ordinary`/`structured` serialized vocabulary described above; old aliases
  are rejected. Safe default reflection omits sensitive raw evidence, which
  remains available only through explicit inspection or opt-in wire capture.

### Migration for the coordinated 3.0.0 release

- Catch `RecoveryError` for recovery-enabled buffered and throwing streaming
  APIs; handle `.recoveryFailure` for single-turn recovery event streams.
  Existing callers can retain gateway initialization without `recovery:` to
  keep legacy one-send behavior.
- Update recovery metadata switches to `RecoveryProvider`/`RecoveryOperation`
  and persisted operation values to `ordinary`, `structured`, or `streaming`.
  Old `complete`/`completeStructured` JSON aliases are rejected. Read sensitive
  headers, body bytes and causes through explicit evidence inspection rather
  than reflection.
- Native reasoning and model metadata/request fidelity use the migrations above.
  Full timing conformance still awaits the Anthropic initial tool-input decision.

### Fixed

- Recovery conformance expectations now account for Apple URLSession's Latin-1
  interpretation of UTF-8 HTTP header octets. Exact header dictionaries and
  non-ASCII body bytes remain asserted; captured runtime evidence is unchanged.
- The recovery loopback test fixture now stops its accept thread on macOS.
  `shutdown` on a listening socket does not wake `accept` on Darwin, so every
  fixture leaked its thread and listener, and macOS CI requests timed out with
  no response. On Apple platforms the header-boundary capture test now sends
  one body byte before holding, because Apple URLSession reports a response
  only after its first body byte.
  Test harness only; library behaviour is unchanged.
- The first-token failure-after-content test now holds its truncated reply
  open until the caller has received the content. Legacy streams have no
  delivery report, so the fixture closed the connection with the partial
  body, and Apple URLSession can discard a partial body that arrives with
  EOF; the token then never reached the client on macOS. Test harness only;
  library behaviour is unchanged.

- On Apple platforms, a recovery attempt whose non-2xx body ends before its
  `Content-Length` now keeps a `URLError.networkConnectionLost` cause.
  URLSession on Apple platforms reports such a body as complete;
  FoundationNetworking reports the lost connection. The status still decides
  the failure category and eligibility.
- On Apple platforms, legacy streaming calls that get a non-2xx status now
  throw `MojenticError.http(status:body:)` with the response body, as on Linux.
  The body was empty before.

## [2.1.0] - 2026-09-30

- Reject malformed completion stream control fields instead of ignoring them.
- Preserve Ollama model, token counts and timing evidence across sparse frames.
- An explicit empty oMLX API key disables authentication even when the environment has a key.
- Reject blank oMLX load and unload model IDs before sending a request.

- Test split-chunk tool-call IDs through OpenAI and oMLX broker streaming follow-ups.
- Add a single-response broker API for caller-owned context and native tool requests.
- Support explicit unlimited tool rounds while retaining finite defaults.
- Unknown tools produce error exchanges in both ordinary and streaming broker calls.

### Added

- **Layer 1 — LLM**: `OMLXGateway` reaches an [oMLX](https://github.com/jundot/omlx)
  server on Apple Silicon. It is configured by `host`, `apiKey` and `timeout`
  (seconds), falling back to `OMLX_HOST` (default `http://localhost:8000`;
  the gateway adds `/v1`), `OMLX_API_KEY` (bearer header only when set) and
  `OMLX_TIMEOUT` (milliseconds; default 600 seconds, for every request
  including model load). It reuses the OpenAI message adapter and stream
  parsers without the OpenAI model registry, so every parameter is sent
  unchanged whatever the model is called; `max_tokens` is always sent.
  `reasoning_content` becomes `thinking`, and a streamed
  `.thinkingDelta` in the legacy stream. Structured output sends a
  `json_schema` response format; a `Warning` header on a structured request
  is recorded in metadata under `response_format_warning` and logged.
  oMLX's full `usage` object is kept in metadata under `usage`. Supports the
  single-turn events API with the OpenAI completion rules, and drops oMLX
  keep-alive frames in both streaming APIs. Adds `loadModel(_:)`,
  `unloadModel(_:)`, and embeddings (`EmbeddingsGateway`, one request per
  text, model required). See the "Local models with oMLX" article.
- **Layer 1 — LLM**: `CompletionConfig.responseFormat` requests an output
  format (`ResponseFormat.text`, `.jsonObject`, `.jsonSchema(_:)`). The
  OpenAI gateway forwards it as `response_format` and the Ollama gateway as
  `format`, in both ordinary and streaming requests. `nil` leaves the request
  unchanged. The field records what was requested; callers still validate the
  content.
- **Layer 3 — Tracer**: `LLMResponsePayload` exposes `usage`,
  `providerModel`, `finishReason` and `metadata` exactly as the gateway
  reported them (`nil` when unreported, never estimated); `model` stays the
  requested model. The trace's `finishReason` is the provider's raw string
  (`String?`), so unknown values such as Ollama's `load` survive unchanged;
  the typed `FinishReason` stays on `LLMGatewayResponse.finishReason` and
  `LLMResponse`. `LLMGatewayResponse` gains `providerFinishReason`,
  `providerModel` and `metadata`,
  filled by the OpenAI, Ollama and Anthropic gateways. Structured calls now
  trace the provider response through the new
  `LLMGateway.completeStructured(model:messages:schema:config:)` (default
  implementation wraps `completeJSON`, so custom gateways keep compiling).
  The legacy `LLMBroker.stream` keeps its existing tracing.
- **Layer 1 — LLM**: `LLMBroker.generateStreamEvents(model:messages:config:context:)`
  streams one turn, with no tools, as an `AsyncStream<CompletionStreamEvent>`:
  `.content(String)` events, then exactly one terminal `.completed(CompletionEvidence)`
  or `.error(MojenticError)`. OpenAI succeeds only on `finish_reason: "stop"`
  plus `[DONE]`; Ollama only on `done: true` with `done_reason: "stop"`.
  Anything else ends in an error carrying the provider's evidence. One
  request, tool iterations forced to zero, no retry; stopping consumption
  cancels the request. The tracer records the call, and the response with
  usage, provider model, finish reason and metadata at the terminal event;
  an early stop records no response. Supported by `OpenAIGateway` and
  `OllamaGateway` through the new `LLMGateway.completeStreamEvents` (default:
  unsupported, so Anthropic and custom gateways yield
  `streamEventsUnsupported` without a request).
- `MojenticError` gains `incompleteCompletion`, `incompleteStream`,
  `unexpectedToolCalls`, `providerError(status:detail:)`, `requestFailed`,
  `invalidStreamEvent` and `streamEventsUnsupported`.
- **Layer 1 — LLM**: `OpenAIModelRegistry` now recognises the OpenAI
  GPT-5.4 and GPT-5.5 reasoning families (`gpt-5.4`, `gpt-5.4-mini`,
  `gpt-5.4-nano`, `gpt-5.5`, `gpt-5.5-pro`, plus their dated snapshots).
  These are registered explicitly as reasoning models with image-input
  support, and pattern matching for `gpt-5.3`/`gpt-5.4`/`gpt-5.5`
  variants is checked ahead of the bare `gpt-5` pattern so unknown
  snapshots still resolve to a reasoning profile.
- **Layer 1 — LLM**: `OpenAIModelCapabilities` reaches structural parity
  with the other Mojentic ports' `ModelCapabilities`. New fields:
  `maxContextTokens` and `maxOutputTokens` (per-model token limits),
  `supportedTemperatures` (`nil` = unrestricted, empty = parameter not
  accepted, populated = only those exact values), and the three per-API
  support flags `supportsChatApi` / `supportsCompletionsApi` /
  `supportsResponsesApi`. A new `supportsTemperature(_:)` helper checks a
  specific temperature value; `supportsTemperatureControl` is now a
  computed property derived from `supportedTemperatures` and keeps its
  prior semantics. `OpenAIModelType` gains a `moderation` case.
- **Layer 1 — LLM**: `OpenAIModelRegistry` catalog reaches parity with
  the cross-port reference — backfilled the o1/o3/o4 reasoning models
  (including dated snapshots, `deep-research`, `pro`, and `codex`
  variants), the bare `gpt-5` / `5.1` / `5.2` families, the full GPT-4 /
  GPT-4.1 / GPT-4o chat catalog (audio and search-preview variants
  included), the GPT-3.5 series, and the legacy `babbage-002` /
  `davinci-002` completions-only models. Every entry — including the
  GPT-5.4/5.5 families — now carries context-window, output-token, and
  per-API support data. Pattern matching gains `gpt-5.1` / `gpt-5.2` /
  `chatgpt` / `text-moderation` mappings and now logs a warning (via
  `swift-log`) when it infers a profile for an unknown model. New
  `isReasoningModel(_:)` and `registeredModels` accessors.

### Changed

- **Tooling**: The code passes `swift format lint --strict` under Swift 6.4
  on Linux, where swift-format splits doc-comment sentences without the
  NaturalLanguage framework. Four doc-comment summaries were rewritten, and
  two DocC links that did not resolve now point at real symbols.
- **CI**: macOS jobs run on the `xcode-27` image (Swift 6.4). Linux jobs use
  the `swift:6.4-noble` image, and a `swift:6.1-noble` job checks the
  declared minimum. The format gate runs on Linux, SwiftLint runs from the
  `ghcr.io/realm/swiftlint:0.65.1` image, every build job also runs
  `swift test --traits full`, and the Linux job builds the DocC catalog with
  warnings as errors. `swift-tools-version` stays at 6.1, the lowest version
  with package traits.
- **Dependencies**: `swift-log` 1.12.0 → 1.15.1 (minimum raised from
  1.5.0 to 1.15.1) and the `swift-docc-plugin` minimum raised from 1.4.0 to
  1.5.0, its latest release. `swift-docc-symbolkit` stays at 1.0.0, its only
  release. GitHub Actions move to `actions/checkout@v7`,
  `actions/upload-pages-artifact@v5` and `actions/deploy-pages@v5`.
- **CI**: A `Supply Chain` workflow scans `Package.resolved` with
  osv-scanner 2.6.0 on every push and weekly.
- **Tooling**: `.hone-gates.json` defines the mandatory gate for Foundry
  (format, lint, build, test, test-full-traits, docs), all required and all
  runnable on macOS and Linux.
- **Tests**: The `ParallelToolRunner` concurrency test no longer compares
  wall-clock times, which failed on a loaded CI runner. Each tool now waits
  at a barrier until every call in the batch is in flight.

## [2.0.0] - 2026-05-18

First production release. Reaches cross-port parity with the Python,
TypeScript, Elixir, and Rust implementations across all four layers,
including Layer 4 Realtime Voice — which moves Mojentic to the 2.0 line
across all ports.

### Added

- **Layer 1 — LLM**: `LLMBroker` (complete / completeJSON / streaming
  with recursive tool dispatch), `LLMGateway` protocol, `OllamaGateway`,
  `OpenAIGateway` (Chat Completions + SSE + model registry),
  `AnthropicGateway` (gated behind the `anthropic` package trait,
  Messages API + named-event SSE), `ChatSession` actor with auto history
  - streaming send, multimodal `ImageContent`,
  `TokenBudgetContextWindowManager`, `ApproximateTokenizerGateway`,
  Ollama + OpenAI embeddings gateways.
- **Layer 1 — Tools**: `LLMTool` protocol, `SerialToolRunner`,
  `ParallelToolRunner` (bounded fan-out, ordered output), `ToolWrapper`
  (broker-as-tool with tracer-context propagation), reference tools
  (file tools + sandboxed `FilesystemGateway`, ephemeral task manager,
  Ask/TellUser, web search, date/datetime utilities).
- **Layer 2 — Tracer**: `TracerEvent` union (llmCall, llmResponse,
  toolCall, toolResult, toolBatch, agentLifecycle), `TracerContext`
  with nested-correlation derivation, `EventStore` actor with
  `events(correlatedTo:)` tree resolution, `EventStoreTracer`. Broker,
  tool runners, dispatcher, and realtime session all wire correlation
  IDs through.
- **Layer 3 — Agents**: `BaseAgent` protocol, `AsyncLLMAgent`,
  `AsyncAggregatorAgent`, `Router`, `AsyncDispatcher` (TaskGroup
  fan-out, agentLifecycle tracing, error-event re-dispatch),
  `SharedWorkingMemory` actor with scoped namespaces, higher-order
  agents (`IterativeProblemSolver`, `SimpleRecursiveAgent`,
  `ReActAgent`).
- **Layer 4 — Realtime Voice**: `RealtimeVoiceBroker` + `RealtimeSession`
  actors, `OpenAIRealtimeGateway` over `URLSessionWebSocketTask`,
  vendor-neutral `RealtimeEvent` union plus a raw-events escape hatch,
  `AudioFrame` + `AudioCodec` for base64 PCM round-tripping, server-
  and manual-VAD modes, barge-in via cooperative task cancellation,
  parallel tool-call dispatch inside voice turns.
- **Documentation**: DocC catalog at `Sources/Mojentic/Mojentic.docc/`
  with a topic-organised landing page, four Use Case tutorials
  (Building Chatbots, Structured Output, Building Agents, Image
  Analysis), three Example articles (File Tools, Task Management, Web
  Search), and per-symbol API reference auto-generated from public doc
  comments. GitHub Pages publishing workflow + `.spi.yml` for Swift
  Package Index integration.
- **Examples**: 26 executable examples covering every layer, wired as
  `.executableTarget` products in `Package.swift`.
- **Testing**: 118 Swift Testing tests covering message composers,
  completion config, JSON value + schema generation, tool runners
  (serial + parallel), date/datetime tools, broker semantics
  (recursive tool loop, depth cap, structured output decode, streaming
  with tools), file-tool sandboxing, ephemeral task manager round-trip,
  ScriptedIOGateway, ToolWrapper tracer linkage, tracer event store
  - correlation tree, router fan-out + dispatcher drain + lifecycle
  tracing, AsyncLLMAgent correlation propagation, higher-order agent
  behaviour, OpenAI + Anthropic message adapters and model registries,
  context-window manager eviction, ApproximateTokenizerGateway
  monotonicity, AudioCodec round-trip, OpenAIRealtimeEventMapper
  translation, RealtimeSession orchestration via a `FakeTransport`,
  and RealtimeVoiceBroker runner/tracer wiring.

### Notes

- `BaseAsyncAgent` is shipped as a typealias for `BaseAgent` per SWIFT.md
  §4 "async-first subsumption" — there is no separate synchronous
  agent contract.
- `ChatSession.stream(_:)` proxies the broker's stream events directly;
  internal tool exchanges are not separately re-appended to the
  session's persistent history.
- Anthropic gateway is trait-gated; opt in via `traits: ["anthropic"]`
  (or `["full"]`).
- Audio capture/playback is explicitly out of library scope — wire
  AVAudioEngine / ALSA in your app boundary.

## [0.0.0] - Phase 0

### Added

- Phase 0 skeleton: `Package.swift` (`swift-tools-version: 6.1`) with provider
  trait gating (`ollama` / `openai` / `anthropic` / `full`), umbrella module,
  smoke-test target using Swift Testing, project documentation files, and CI
  workflow running format/lint/build/test on macOS and Linux.
