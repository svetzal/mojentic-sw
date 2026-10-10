# Recovering Local Completion Streams

Enable request recovery without replaying tools or appending a replacement to partial output.

The same ``CompletionRecoveryPolicy`` now covers Ollama and oMLX `stream` and
`completeStreamEvents`, including ``LLMBroker`` and ``ChatSession`` callers.
Initializers without `recovery:` retain their legacy parsing and one-send behavior.
Policy presence defaults to one attempt. Request bytes are encoded once and remain
identical across explicitly admitted retries; client IDs provide correlation,
not provider idempotency.

## Migrate a tool-capable stream

Reuse the admission policy from <doc:BufferedCompletionRecovery>, with a controller
that verifies ownership and termination of this exact attempt before allowing a
resend. Pending admission is never approval. A keepalive, timeout or closed socket
does not prove that remote inference ended.

```swift
let gateway = OllamaGateway(recovery: policy)
// Alternatively: OMLXGateway(host: localURL, recovery: policy)
let broker = LLMBroker(gateway: gateway)
let session = ChatSession(broker: broker, model: "local-model", tools: tools)
do {
    for try await event in session.stream("Continue") {
        if case .textDelta(let text) = event {
            displayPartial(text)
        }
    }
} catch let error as RecoveryError {
    recordSafeSummary(error.description)
    // Explicit inspection is sensitive and belongs to your storage policy.
    let originalCause = error.failure.inspectEvidence().cause
}
```

A failed or recovered completion after a completed tool preserves the tool result
in its exact request bytes. Neither retries nor backoff reset tool depth or execute
the completed tool again. A failed session turn follows the existing history rollback
rules; the caller owns any subsequent session recovery.

## Consume a single turn with typed terminal errors

```swift
for await event in broker.generateStreamEvents(model: "local-model", messages: messages) {
    switch event {
    case .content(let text): displayPartial(text)
    case .progress(let counts): recordProgress(counts)
    case .metrics(let metrics): recordProviderMetrics(metrics)
    case .completed(let evidence): acceptFinishedAnswer(evidence)
    case .error(.recovery(let failure)): recordSafeSummary(failure.description)
    case .error(let error): recordSafeSummary(error.description)
    }
}
```

``MojenticError/recovery(_:)`` retains the structured history and original cause.
Gateway tool streams throw ``RecoveryError`` directly. Observed reasoning, content,
tool fragments or completed tools prevent transparent recovery even if capture failed
before delivery. Delivery is counted separately; single-turn reasoning is observed
but remains absent from the content-only API. UTF-8 byte counters are exact.

## Completion evidence and telemetry

Recovery-enabled Ollama streams require `done: true` and `done_reason: "stop"`.
oMLX requires a valid finish reason (`stop`, or `tool_calls` for a tool stream)
and `data: [DONE]`. End of transport is not completion proof. Malformed frames are
terminal and never retried. Ordinary buffered finish handling is unchanged.

Ollama adds progress events for validated frames and metrics when provider usage
or numeric durations are present. No model names, timestamps or echoed IDs appear
in these metrics. Terminal completion evidence retains the provider fields already
exposed by Swift; its default formatting is safe. A valid length-terminated Ollama
frame produces progress and reported metrics before the original finish failure.
Its semantic fields remain observed-only, and no completed tool is delivered.
Malformed frames produce no fabricated telemetry. oMLX has no invented Ollama
progress or metric events.

Gateway consumption applies backpressure to semantic and telemetry delivery. Pausing on
terminal metadata cannot establish success or release a completed tool. Cancellation
closes locally owned HTTP resources and records a failed actual attempt followed by
one terminal cancellation. Swift stream iteration may return `nil` when `next()`
begins on an already cancelled task; the lifecycle/report observers retain the
cleanup outcome. Neither cancellation nor local socket closure claims remote
termination. Drop the stream/iterator to release its producer when stopping early.

## Capabilities and sensitive capture

Both local adapters expose local HTTP cancellation. Remote request cancellation,
exact-attempt status querying and provider idempotency remain unsupported. Recovery
for OpenAI and Anthropic completion adapters, realtime voice and embeddings is outside
this slice. Supported message/tool history and generation controls are preserved;
no native reasoning-history field is invented.

Lifecycle events contain numeric status, identities, progress, classification and
bounded attempt counts without payloads or raw cause text. Exact encoded request
bytes, normalized HTTP headers and received response chunks are available only
through the caller-owned ``CompletionRecoveryPolicy/wireObserver`` hook. This is
body capture, not raw HTTP framing or TLS capture. A throwing capture hook is terminal
and cannot authorize a resend. No recovery deadline limits an already admitted,
healthy generation; budgets apply to admission and backoff.

## Cancellation while the consumer is paused

Create and consume the stream inside ``withRecoveryStreamCancellation(operation:)``
when cancellation must close local HTTP resources while the consumer awaits work
outside `next()`:

```swift
try await withRecoveryStreamCancellation {
    for try await event in gateway.stream(
        model: model, messages: messages, tools: nil, config: config
    ) {
        try await consume(event)
    }
}
```

The scope registers recovery producers and is inherited by broker and chat session
relays. Its cancellation handler stays active while `consume` is paused, and scope
exit cancels unfinished producers. Scoped broker/session relays apply backpressure
instead of draining provider terminal events into an unbounded consumer buffer.
Cancellation keeps the actual failed attempt and emits `attemptFailed` followed by
one `cancelled` event, with no retry or success. Reports describe delivery at the
gateway boundary; a relay receiving a value does not establish final application
delivery.

Cancellation remains effective between a sender's initial task check and its
continuation registration. Cancellation and registration share one lock, and the
cancellation state stays recorded even when there is no sender to resume yet.
The producer reaches cleanup while the consumer, returned stream, and fixture
response remain retained independently. This applies to both gateway event APIs
and the scoped broker/session relays; cancellation cannot deliver a completed
tool or establish success through a buffered terminal frame.

Existing stream signatures remain compatible. A bare `AsyncStream` only receives
consumer cancellation during iteration; keeping a stream alive while awaiting
unrelated work does not install a cancellation handler for that work. Migrate the
consumer operation to this scope for the paused-consumer guarantee. Create streams
inside the scope, and use a separate scope inside detached tasks. Local cleanup
still provides no evidence that a remote request stopped.
