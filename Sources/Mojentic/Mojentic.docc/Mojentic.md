#  ``Mojentic``

A Swift-idiomatic, async-first LLM integration framework with full feature
parity across Ollama, OpenAI, and Anthropic — including agents, tracer,
and realtime voice.

## Overview

Mojentic gives Swift developers one cohesive surface for building
production LLM applications: a broker that orchestrates completions and
recursive tool execution, a chat-session wrapper that auto-manages
history, a vendor-neutral tracer for observability, an event-driven
agent system, and a duplex realtime-voice session for OpenAI's Realtime
API. Every layer is composable — pick what you need and ignore the rest.

The framework is async-first end to end: `async/await`,
`AsyncThrowingStream`, structured tasks, actor isolation, and `Sendable`
correctness throughout. Swift 6 strict-concurrency clean.

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

See <doc:BuildingChatbots> for the multi-turn `ChatSession` form and
<doc:BuildingAgents> for the dispatcher-driven multi-agent flow.

## Topics

### Use Cases

- <doc:BuildingChatbots>
- <doc:StructuredOutput>
- <doc:BuildingAgents>
- <doc:ImageAnalysis>

### Examples

These provided tools are reference implementations, not core library
features. Use them directly when they fit, or read them as templates
for building your own.

- <doc:Example-FileTools>
- <doc:Example-TaskManagement>
- <doc:Example-WebSearch>

### Core — LLM

- ``LLMBroker``
- ``LLMGateway``
- ``OllamaGateway``
- ``OpenAIGateway``
- ``ChatSession``
- ``LLMMessage``
- ``CompletionConfig``
- ``LLMResponse``
- ``LLMGatewayResponse``
- ``ImageContent``
- ``StreamEvent``
- ``GatewayStreamEvent``
- ``TokenizerGateway``
- ``ApproximateTokenizerGateway``
- ``ContextWindowManager``
- ``TokenBudgetContextWindowManager``
- ``EmbeddingsGateway``
- ``OllamaEmbeddingsGateway``
- ``OpenAIEmbeddingsGateway``

### Core — Tools

- ``LLMTool``
- ``ToolDescriptor``
- ``ToolRunner``
- ``SerialToolRunner``
- ``ParallelToolRunner``
- ``ToolCallExecution``
- ``ToolCallOutcome``
- ``TracerContextAwareTool``
- ``ToolWrapper``
- ``CurrentDateTimeTool``
- ``DateResolverTool``

### Core — Tracer

- ``Tracer``
- ``NullTracer``
- ``EventStoreTracer``
- ``EventStore``
- ``TracerEvent``
- ``TracerContext``

### Core — Agents

- ``BaseAgent``
- ``BaseAsyncAgent``
- ``AsyncLLMAgent``
- ``AsyncAggregatorAgent``
- ``IterativeProblemSolver``
- ``SimpleRecursiveAgent``
- ``ReActAgent``
- ``Router``
- ``AsyncDispatcher``
- ``Event``
- ``TextEvent``
- ``LLMRequestEvent``
- ``LLMResponseEvent``
- ``CompositeEvent``
- ``SharedWorkingMemory``

### Core — Realtime

- ``RealtimeVoiceBroker``
- ``RealtimeGateway``
- ``OpenAIRealtimeGateway``
- ``RealtimeSession``
- ``RealtimeEvent``
- ``AudioFrame``
- ``AudioCodec``
- ``RealtimeTransport``
- ``URLSessionWebSocketTransport``
- ``VADMode``

### Errors

- ``MojenticError``
