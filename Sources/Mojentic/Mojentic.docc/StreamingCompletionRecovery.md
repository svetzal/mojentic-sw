# Recovering Local Completion Streams

Enable request recovery without replaying tools or appending a replacement to partial output.

The same ``CompletionRecoveryPolicy`` now covers Ollama, oMLX and OpenAI Chat Completions `streamRecovering` and
`completeStreamEventsRecovering`, including the internal opt-in routing used by
``LLMBroker`` tool streams and ``ChatSession`` callers.
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
// Or: OpenAIGateway(apiKey: configuredKey, recovery: policy)
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
for await event in broker.generateRecoveryStreamEvents(model: "local-model", messages: messages) {
    switch event {
    case .content(let text): displayPartial(text)
    case .progress(let counts): recordProgress(counts)
    case .metrics(let metrics): recordProviderMetrics(metrics)
    case .completed(let evidence): acceptFinishedAnswer(evidence)
    case .recoveryFailure(let failure): recordSafeSummary(failure.description)
    case .error(let error): recordSafeSummary(error.description)
    }
}
```

``RecoveryCompletionStreamEvent/recoveryFailure(_:)`` retains the structured history and original cause.
Gateway tool streams throw ``RecoveryError`` directly. Observed reasoning, content,
tool fragments or completed tools prevent transparent recovery even if capture failed
before delivery. Delivery is counted separately; single-turn reasoning is observed
but remains absent from the content-only API. UTF-8 byte counters are exact.

## Completion evidence and telemetry

Recovery-enabled Ollama streams require `done: true` and `done_reason: "stop"`.
oMLX and OpenAI require a valid finish reason (`stop`, or `tool_calls` for a tool stream)
and `data: [DONE]`. End of transport is not completion proof. Malformed frames are
terminal and never retried. Ordinary buffered finish handling is unchanged.

Ollama adds progress events for validated frames and metrics when provider usage
or numeric durations are present. No model names, timestamps or echoed IDs appear
in these metrics. Terminal completion evidence retains the provider fields already
exposed by Swift; its default formatting is safe. A valid length-terminated Ollama
frame produces progress and reported metrics before the original finish failure.
Its semantic fields remain observed-only, and no completed tool is delivered.
Malformed frames produce no fabricated telemetry. oMLX has no invented Ollama
progress or metric events. OpenAI recovery emits metrics only for validated,
provider-reported usage counts, before success or finish failure; it adds no frame
counters, durations, provider identifiers or echoed metadata to those metrics.

Gateway consumption applies backpressure to semantic and telemetry delivery. Pausing on
terminal metadata cannot establish success or release a completed tool. Cancellation
closes locally owned HTTP resources and records a failed actual attempt followed by
one terminal cancellation. Swift stream iteration may return `nil` when `next()`
begins on an already cancelled task; the lifecycle/report observers retain the
cleanup outcome. Neither cancellation nor local socket closure claims remote
termination. Drop the stream/iterator to release its producer when stopping early.

## Capabilities and sensitive capture

Both local adapters expose local HTTP cancellation. Remote request cancellation,
exact-attempt status querying and provider idempotency remain unsupported. OpenAI Chat Completions also supports recovery; Anthropic, realtime voice and
embeddings remain outside this slice. Supported message/tool history and generation controls are preserved;
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
    for try await event in gateway.streamRecovering(
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

## Release baseline compatibility

Legacy `GatewayStreamEvent`, `CompletionStreamEvent`, and `MojenticError` keep
all v2.1.0 cases so existing exhaustive switches remain valid. The legacy
`stream`, `completeStreamEvents`, and broker `generateStreamEvents` entrypoints
retain their original single-request completion behavior even on a gateway
configured with a recovery policy. No recovery error conversion occurs on these
legacy streaming entrypoints.

Migrate gateway consumers to `streamRecovering` or `completeStreamEventsRecovering`
and single-turn broker consumers to `generateRecoveryStreamEvents` to receive
`RecoveryGatewayStreamEvent` or `RecoveryCompletionStreamEvent`. Match
`.recoveryFailure(let failure)` explicitly on the recovery completion stream;
`failure.failure.inspectEvidence()` retains the original typed cause, and
`failure.history` retains bounded attempt history.
Progress and metrics remain nonterminal and preserve provider values and order.
Broker tool streams and ChatSession streams retain their existing result types
and use the opt-in gateway boundary internally. Buffered recovery still throws
`RecoveryError` directly. Continue to use `withRecoveryStreamCancellation` for
cleanup while a consumer is paused outside iteration.

## OpenAI Chat Completions

Use `OpenAIGateway(apiKey: configuredKey, recovery: policy)` to opt in. Ordinary,
JSON and structured buffered completions use the policy; tool streams use
`streamRecovering`, and single turns use `completeStreamEventsRecovering`.
The broker and applicable chat session paths preserve completed tool results.
Legacy stream methods retain their original parsers and one-send behavior.

Request shaping still follows the model registry: token parameter, temperature,
reasoning effort and schema support are unchanged. Encoded request bytes are
identical across attempts. Received reasoning is observed for replay safety but
is not delivered as thinking or single-turn content. Neither client identities,
local socket cancellation nor empty output proves provider idempotency or remote
termination. Request status and remote cancellation are unsupported; ambiguous
retries require explicit caller admission. No native reasoning history is invented.
