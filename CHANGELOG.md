# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Major and minor versions are synchronised with the other Mojentic ports
(`mojentic-py`, `mojentic-ts`, `mojentic-ex`, `mojentic-ru`); patch versions
move independently.

## [Unreleased]

### Added

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
