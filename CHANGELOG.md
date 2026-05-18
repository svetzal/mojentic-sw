# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Major and minor versions are synchronised with the other Mojentic ports
(`mojentic-py`, `mojentic-ts`, `mojentic-ex`, `mojentic-ru`); patch versions
move independently.

## [1.4.0] - 2026-05-18

First production release. Reaches cross-port parity with the Python,
TypeScript, Elixir, and Rust implementations across all four layers.

### Added

- **Layer 1 — LLM**: `LLMBroker` (complete / completeJSON / streaming
  with recursive tool dispatch), `LLMGateway` protocol, `OllamaGateway`,
  `OpenAIGateway` (Chat Completions + SSE + model registry),
  `AnthropicGateway` (gated behind the `anthropic` package trait,
  Messages API + named-event SSE), `ChatSession` actor with auto history
  + streaming send, multimodal `ImageContent`,
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
  + correlation tree, router fan-out + dispatcher drain + lifecycle
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
