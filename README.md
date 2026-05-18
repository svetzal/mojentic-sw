# Mojentic

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1%2B-orange)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS%20%7C%20Linux-blue)](Package.swift)

A modern LLM integration framework for Swift with full feature parity across
Python, Elixir, Rust, and TypeScript implementations.

Mojentic provides a clean abstraction over multiple LLM providers with tool
support, structured output generation, streaming, an event-driven agent system,
and realtime voice — all built natively on Swift Concurrency.

> **Status: Phase 5 — realtime voice shipped.** Adds `RealtimeVoiceBroker`,
> `OpenAIRealtimeGateway`, `RealtimeSession` (vendor-neutral
> `RealtimeEvent` stream plus a raw-events escape hatch), `AudioFrame` +
> `AudioCodec`, server- and manual-VAD modes, barge-in via cooperative
> task cancellation, and parallel tool-call dispatch inside voice turns —
> on top of the Phase 1–4 LLM + tracer + tool + agent foundation.
> Anthropic (text only) and docs polish remain — see `SWIFT.md` in the
> `mojentic-unify` monorepo for the full plan.

## Planned Features

- **🔌 Multi-Provider Support**: Ollama, OpenAI, and Anthropic gateways
- **⚡ Async-First**: Swift Concurrency end to end (`async/await`,
  `AsyncSequence`, actors, structured tasks)
- **🛠️ Tool System**: Extensible tool calling with automatic recursive
  execution, serial (default) or parallel runners
- **📊 Structured Output**: Type-safe `Codable`-based structured data
- **🌊 Streaming**: `AsyncThrowingStream` with full recursive tool execution
- **🔍 Tracer System**: Complete observability for debugging and monitoring,
  with correlation IDs threaded through nested broker/tool calls
- **🤖 Agent System**: Event-driven multi-agent coordination with the ReAct
  pattern and shared working memory
- **🎙️ Realtime Voice**: OpenAI Realtime API over `URLSessionWebSocketTask`
  with server/manual VAD and barge-in
- **🧩 Provider Trait Gating**: Swift Package Traits let consumers opt into
  only the providers they need

## Requirements

- **Swift 6.1+** (Package Traits + strict concurrency)
- Platforms: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+, Linux
  (current stable Swift toolchain)

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/svetzal/mojentic-sw.git", from: "0.1.0")
]
```

Then add `Mojentic` to your target's dependencies. To opt into specific
providers via traits:

```swift
.package(
    url: "https://github.com/svetzal/mojentic-sw.git",
    from: "0.1.0",
    traits: ["openai", "ollama"]
)
```

## Documentation

DocC documentation will be published to GitHub Pages on every tagged release.

## License

MIT — see [LICENSE](LICENSE).
