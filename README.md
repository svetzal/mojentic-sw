# Mojentic

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1%2B-orange)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS%20%7C%20Linux-blue)](Package.swift)

A modern LLM integration framework for Swift with full feature parity across
Python, Elixir, Rust, and TypeScript implementations.

Mojentic provides a clean abstraction over multiple LLM providers with tool
support, structured output generation, streaming, an event-driven agent system,
and realtime voice — all built natively on Swift Concurrency.

> **Status: 2.0.0 — production.** All four layers (LLM, Tracer, Agents,
> Realtime Voice) ship at cross-port parity. Realtime Voice is the 2.0
> line across all Mojentic ports. See `SWIFT.md` in the `mojentic-unify`
> monorepo for the original plan and parity notes.

## Quick Start

```swift
import Mojentic

let broker = LLMBroker(gateway: OllamaGateway())
let response = try await broker.complete(
    model: "llama3.2",
    messages: [
        .system("You are a concise assistant."),
        .user("Name one fact about the moon."),
    ]
)
print(response.content)
```

For a multi-turn conversation use `ChatSession`; for an agent flow use
`AsyncDispatcher`; for voice use `RealtimeVoiceBroker`. The DocC site
has full walkthroughs for each.

## Features

- **Multi-Provider Support**: Ollama, OpenAI, and Anthropic gateways.
- **Async-First**: Swift Concurrency end to end (`async/await`,
  `AsyncSequence`, actors, structured tasks).
- **Tool System**: Extensible tool calling with automatic recursive
  execution, serial (default) or parallel runners.
- **Structured Output**: Type-safe `Codable`-based decoding with
  provider-aware schema routing.
- **Streaming**: `AsyncThrowingStream` with full recursive tool
  execution and per-event broker context.
- **Tracer System**: `EventStore`-backed correlation tracking that
  follows broker calls, tool dispatches, agent lifecycle, and parallel
  tool batches.
- **Agent System**: `Router` + `AsyncDispatcher` with `AsyncLLMAgent`,
  `AsyncAggregatorAgent`, `IterativeProblemSolver`, `SimpleRecursiveAgent`,
  `ReActAgent`, and `SharedWorkingMemory`.
- **Realtime Voice**: OpenAI Realtime API over `URLSessionWebSocketTask`
  with server/manual VAD, barge-in via cooperative task cancellation,
  and parallel tool dispatch inside voice turns.
- **Provider Trait Gating**: Swift Package Traits let consumers opt
  into only the providers they need.

## Requirements

- **Swift 6.1+** (Package Traits + strict concurrency)
- Platforms: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+,
  Linux (current stable Swift toolchain)

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/svetzal/mojentic-sw.git", from: "2.0.0")
]
```

Then add `Mojentic` to your target's dependencies. To opt into specific
providers via traits:

```swift
.package(
    url: "https://github.com/svetzal/mojentic-sw.git",
    from: "2.0.0",
    traits: ["openai", "ollama", "anthropic"]
)
```

## Documentation

- **DocC site**: <https://svetzal.github.io/mojentic-sw/> (published on
  every `v*` tag).
- Use Cases: Building Chatbots, Structured Output, Building Agents,
  Image Analysis.
- Tool Examples: File Tools, Task Management, Web Search.
- Core API reference auto-generated from public symbol doc comments.

Build the docs locally:

```bash
swift package --disable-sandbox preview-documentation --target Mojentic
```

## License

MIT — see [LICENSE](LICENSE).
