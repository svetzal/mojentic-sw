#  Building Chatbots

Multi-turn conversational interfaces with auto-managed history, streaming,
and tool use.

## Overview

### Why

A chat-style UI keeps the entire conversation in context so the model can
remember earlier turns. Doing that by hand means tracking message
ordering, system prompts, context-window trimming, tool exchanges, and
streaming deltas. ``ChatSession`` collapses that bookkeeping into one
actor.

### When

Reach for ``ChatSession`` whenever the interaction is back-and-forth
across more than one turn. For single-shot completions stay with
``LLMBroker`` directly — it's lower overhead and avoids carrying state
you don't need.

### How

#### 1. Pick a gateway

```swift
import Mojentic

let broker = LLMBroker(gateway: OllamaGateway())
// or
let broker = LLMBroker(gateway: OpenAIGateway(apiKey: openAIKey))
```

#### 2. Open a session

```swift
let session = ChatSession(
    broker: broker,
    model: "gpt-4o-mini",
    systemPrompt: "You are a concise assistant."
)
```

#### 3. Send turns

```swift
let response = try await session.send("What is the capital of France?")
print(response.content)
let followUp = try await session.send("And its population?")
print(followUp.content)
```

Both turns share the same history; the second call sees the first
exchange.

#### 4. Stream deltas as they arrive

```swift
for try await event in session.stream("Tell me a haiku about Swift.") {
    if case .textDelta(let delta) = event {
        print(delta, terminator: "")
        fflush(stdout)
    }
}
```

Partial responses do NOT commit to history if the stream errors or is
cancelled — the convo state stays consistent.

#### 5. Add tools

```swift
let session = ChatSession(
    broker: broker,
    model: "gpt-4o-mini",
    systemPrompt: "Use the time tools whenever the user asks about now.",
    tools: [CurrentDateTimeTool(), DateResolverTool()]
)
let response = try await session.send("What is the date next Friday?")
```

The broker handles tool-call recursion inside `complete`; the session
sees only the final assistant turn.

#### 6. Cap the context window

```swift
let manager = TokenBudgetContextWindowManager(
    budget: 8_000,
    model: "gpt-4o-mini",
    tokenizer: ApproximateTokenizerGateway()
)
let session = ChatSession(
    broker: broker,
    model: "gpt-4o-mini",
    systemPrompt: "...",
    contextWindowManager: manager
)
```

Oldest non-system turns are evicted before each send when the estimated
total exceeds `budget - reserving` tokens. The system prompt and the
most recent user turn are always preserved.

## Known Limitations

`ChatSession.stream(_:)` proxies the broker's stream events directly;
tool-exchange turns the broker performs internally are not separately
re-appended to the session's persistent history. If your application
needs the tool exchange visible in `messages()`, drive the broker
directly and manage history yourself.

## See Also

- ``ChatSession``
- ``LLMBroker``
- ``ContextWindowManager``
