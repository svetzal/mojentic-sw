# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Major and minor versions are synchronised with the other Mojentic ports
(`mojentic-py`, `mojentic-ts`, `mojentic-ex`, `mojentic-ru`); patch versions
move independently.

## [Unreleased]

- Add a single-response broker API for caller-owned context and native tool requests.
- Support explicit unlimited tool rounds while retaining finite defaults.
- Unknown tools produce error exchanges in both ordinary and streaming broker calls.

### Added

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
