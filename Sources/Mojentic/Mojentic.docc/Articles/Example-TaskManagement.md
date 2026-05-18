#  Example — Task Management

Reference implementation of an in-memory task list exposed to the LLM
as a cluster of tools.

## Overview

> Important: The ephemeral task manager is a **reference implementation,
> not a core library feature**. Use it directly when ephemeral, in-memory
> task state is enough, or read it as a template for tools that share a
> stateful actor.

``EphemeralTaskManager`` is an `actor` holding a list of ``EphemeralTask``
values. Five companion ``LLMTool`` implementations
(``AppendTaskTool``, ``ListTasksTool``, ``CompleteTaskTool``,
``RemoveTaskTool``, ``ClearTasksTool``) bind to the same manager
instance so the model can mutate the list across a multi-turn
conversation.

## Wiring up

```swift
import Mojentic

let manager = EphemeralTaskManager()
let session = ChatSession(
    broker: LLMBroker(gateway: OpenAIGateway(apiKey: key)),
    model: "gpt-4o-mini",
    systemPrompt: "Use the task tools to manage the user's to-do list.",
    tools: manager.toolBundle()
)
let response = try await session.send("Add 'buy milk' and 'call mom'.")
```

`manager.toolBundle()` returns all five tools at once. You can also pick
a subset by constructing the individual tools yourself.

## Customising / extending

The cluster pattern — one actor + several tools sharing it — generalises
to anything you'd model as a small mutable collection. Two rules to keep
the design honest:

1. Hold mutable state inside the actor, not the tool. Tools are value
   types; they should be cheap to construct against a shared coordinator.
2. Keep tool descriptors small and explicit. The model picks the right
   tool from its description, so describe each operation in one sentence
   and give every required field a clear `"description"`.

A persistent task manager would look the same on the outside — swap
``EphemeralTaskManager``'s internal `[EphemeralTask]` for a SQLite-backed
store, and the tools don't change.

## See Also

- ``EphemeralTaskManager``
- ``EphemeralTask``
- ``AppendTaskTool``
- ``ListTasksTool``
- ``CompleteTaskTool``
- ``RemoveTaskTool``
- ``ClearTasksTool``
