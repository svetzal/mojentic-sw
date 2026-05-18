# Mojentic Swift — Project Charter

## Purpose

Mojentic-sw is the Swift implementation of the Mojentic LLM integration
framework. It provides a Swift-idiomatic, async-first abstraction over multiple
LLM providers (Ollama, OpenAI, Anthropic) with tool calling, structured output,
streaming, an event-driven agent system, and realtime voice support. It exists
to give Swift developers — on Apple platforms and on server-side Linux — a
production-ready library for building LLM-powered applications without provider
lock-in.

## Goals

- Provide a unified async API for interacting with multiple LLM providers
  through a single `LLMBroker` interface, mirroring the Python reference design.
- Be **distinctly Swift-idiomatic**: Swift Concurrency end to end
  (`async/await`, `AsyncSequence`, structured tasks, actor isolation,
  `Sendable`), not a transliteration of any other port.
- Support an event-driven multi-agent architecture with shared working memory
  and ReAct-pattern reasoning.
- Maintain full feature parity with the Python, Elixir, Rust, and TypeScript
  implementations of Mojentic (see `PARITY.md` in the monorepo).
- Ship as a first-class Swift Package consumable directly from a Git URL +
  tagged release, surfaced through the Swift Package Index.
- Include comprehensive DocC tutorials and examples so the library is learnable
  without external guidance.

## Non-Goals

- Being a standalone AI application or end-user product — this is a library.
- Apple-only support — Linux server is a first-class target, not an afterthought.
- Synchronous/blocking APIs — the library is async-only by design.
- Reimplementing provider SDKs feature-by-feature; raw escape hatches stay narrow.
- A SwiftUI showcase app; example clients ship under `Examples/`, not as a
  packaged binary product.

## Target Users

Swift developers integrating LLMs into Apple-platform apps, command-line tools,
server-side Swift services, or cross-platform Swift code. Especially those who
already use Mojentic on another stack and want consistent semantics.
