# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Major and minor versions are synchronised with the other Mojentic ports
(`mojentic-py`, `mojentic-ts`, `mojentic-ex`, `mojentic-ru`); patch versions
move independently.

## [Unreleased]

### Added

- Phase 3: full tracer system. `TracerEvent` enum (llmCall, llmResponse,
  toolCall, toolResult, toolBatch, agentLifecycle) with correlationId +
  parentId nesting, timestamp, and Duration on paired events.
  `TracerContext` with `child(parent:)` derivation; `EventStore` actor with
  `events(correlatedTo:)` resolving the full nested correlation tree;
  `EventStoreTracer` recording into a backing store. The broker now wires
  correlationId + parentId through every gateway/tool dispatch and accepts
  an injected `TracerContext` so agents and `ToolWrapper` can nest calls
  under the parent tree.
- `ParallelToolRunner` (actor) using `ThrowingTaskGroup` with bounded
  fan-out. Preserves input ordering, isolates per-tool failures into
  `ToolCallOutcome.failure`, emits a `toolBatch` tracer event with total
  duration. `TracerContextAwareTool` opt-in protocol lets tools (notably
  `ToolWrapper`) thread the parent context to nested broker calls.
- Provided tools: `FilesystemGateway` + eight sandbox-rooted file tools
  (`ListFilesTool`, `ListAllFilesTool`, `ReadFileTool`, `WriteFileTool`,
  `DeleteFileTool`, `MoveFileTool`, `CreateDirectoryTool`, `FileExistsTool`)
  plus `FileTools.bundle(for:)` convenience. `EphemeralTaskManager` actor
  with five companion tools (`AppendTaskTool`, `ListTasksTool`,
  `CompleteTaskTool`, `RemoveTaskTool`, `ClearTasksTool`). `IOGateway`
  protocol with `StdIOGateway` default and `ScriptedIOGateway` for tests;
  `AskUserTool` + `TellUserTool` build on it. `WebSearchTool` against
  Serper.dev (API key injected at init). `ToolWrapper` adapts an
  `LLMBroker` invocation into an `LLMTool` and nests its tracer events
  under the calling context via `TracerContextAwareTool`.
- Eight new executable examples: `FileTool`, `CodingFileTool`,
  `BrokerAsTool`, `EphemeralTaskManagerExample`, `TellUser`, `AskUser`,
  `WebSearch` (skips gracefully without SERPER_API_KEY), `TracerDemo`
  (prints the recorded event tree for an Ollama broker call).
- Phase 2: `OpenAIGateway` over `/v1/chat/completions` with `OpenAIMessageAdapter`
  (multimodal user content, tool calls, tool messages with `tool_call_id`),
  `OpenAIModelRegistry` (per-model token-parameter routing, reasoning effort
  + temperature gating, JSON-schema vs JSON-object response format), SSE
  streaming with per-chunk tool-call accumulation, and `availableModels()`.
- `ChatSession` actor with `send`, multimodal `send(text:images:)`, `stream`
  (auto-history), `messages()` snapshot accessor, `clear()` reset, and error
  rollback (failed sends do not leave a dangling user turn).
- `ContextWindowManager` protocol + `TokenBudgetContextWindowManager` that
  evicts oldest non-system turns while pinning the system prompt and the most
  recent user turn.
- `TokenizerGateway` protocol + `ApproximateTokenizerGateway` default
  (`chars / 4` heuristic with configurable per-message overhead).
- `ImageContent` value type (URL or inline base64) plus
  `LLMMessage.user(text:images:)` composer. `OllamaGateway` forwards inline
  images via the `images` array; `OpenAIGateway` forwards them via
  `content` parts with `image_url`.
- `EmbeddingsGateway` protocol with `OllamaEmbeddingsGateway` (`/api/embed`)
  and `OpenAIEmbeddingsGateway` (`/v1/embeddings`) implementations.
- Five new executable examples: `BrokerExamples`, `ChatSessionExample`,
  `ChatSessionWithTool`, `ImageAnalysis`, `Embeddings`.
- New Swift Testing suites: multimodal messages, approximate tokenizer,
  context-window manager eviction, chat session history + rollback +
  streaming commit, OpenAI message adapter, OpenAI model registry.
- Phase 1: core LLM layer shipping `LLMBroker` (non-streaming completion,
  structured output via `Codable`-derived JSON Schema, streaming completion
  with recursive tool dispatch), `LLMGateway` protocol with `OllamaGateway`
  implementation (chat/JSON/streaming + `/api/tags`), `LLMTool` protocol with
  `SerialToolRunner`, reference tools `DateResolverTool` and
  `CurrentDateTimeTool`, foundational value types (`LLMMessage` with composer
  factories, `CompletionConfig`, `ReasoningEffort`, `JSONValue`,
  `LLMResponse`, `LLMGatewayResponse`, `MojenticError`), `Tracer` placeholder
  protocol with `NullTracer`, `JSONSchemaGenerator` (Mirror inference plus
  `JSONSchemaProviding` opt-in), and the `HTTPClient` URLSession wrapper.
- Five executable examples wired into `Package.swift` (`SimpleLLM`,
  `ListModels`, `SimpleStructured`, `SimpleTool`, `Streaming`).
- Swift Testing suites covering messages, completion config, JSON value,
  schema generation, serial tool runner, date resolver, and broker semantics
  (recursive tool loop, depth cap, structured output decode, streaming event
  ordering, streaming with tools).
- `swift-log` dependency for library logging.

### Changed

- Bumped package version to `0.1.0` (first usable build).

## [0.0.0] - Phase 0

### Added

- Phase 0 skeleton: `Package.swift` (`swift-tools-version: 6.1`) with provider
  trait gating (`ollama` / `openai` / `anthropic` / `full`), umbrella module,
  smoke-test target using Swift Testing, project documentation files, and CI
  workflow running format/lint/build/test on macOS and Linux.
