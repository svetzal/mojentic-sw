# Recovering Buffered Completions

Opt Ollama, oMLX or OpenAI Chat Completions into request recovery without replaying a broker or session.

Existing gateway initializers keep their one-send behavior and existing error
conversion. Pass a ``CompletionRecoveryPolicy`` through the new `recovery:`
initializer overload to receive ``RecoveryError`` with numeric status, bounded
history, typed causes, and separate observed/delivered progress. This covers
ordinary `complete`, `completeStructured`, and `completeJSON`, including calls
made by ``LLMBroker`` and ``ChatSession``. For streaming migration and terminal rules see <doc:StreamingCompletionRecovery>.

## Admission belongs to the caller

A local timeout, socket closure, HTTP 503/504, keepalive, or model activity cannot
prove that inference ended. Eligibility does not authorize a resend. Without an
admission hook, an eligible failure returns `admissionRequired` if another attempt
is available. The default maximum is one attempt, including the initial request.

```swift
var policy = CompletionRecoveryPolicy()
policy.maximumAttempts = 3
policy.baseDelay = 0.2
policy.delayCeiling = 10
policy.budget = 30 // recovery admission/backoff only, not healthy generation
policy.admission = { failure, nextWireNumber in
    AsyncStream { continuation in
        let decisionTask = Task {
            // Your controller verifies resource ownership and this exact attempt.
            // A pending verification must remain pending; elapsed time is not approval.
            let allowed = await controller.admit(failure, next: nextWireNumber)
            guard !Task.isCancelled else { continuation.finish(); return }
            continuation.yield(allowed ? .allow : .reject)
            continuation.finish()
        }
        continuation.onTermination = { _ in decisionTask.cancel() }
    }
}
let gateway = OllamaGateway(recovery: policy)
let broker = LLMBroker(gateway: gateway)
let session = ChatSession(broker: broker, model: "your-local-model")
let response = try await session.send("Continue the conversation")
```

For oMLX use `OMLXGateway(host: localURL, recovery: policy)`. A completed tool is
outside the recovered request: only the subsequent completion is resent, with
its original encoded messages and tool result. Recovery attempts do not consume
or reset tool depth. A terminal session failure propagates unchanged; recovery
of an entire failed session or mission remains the caller's responsibility.

## Structured results preserve provider evidence

```swift
let structured = try await gateway.completeStructured(
    model: "your-local-model",
    messages: [.user("Return an object with an answer")],
    schema: ["type": "object", "properties": ["answer": ["type": "string"]]],
    config: CompletionConfig(reasoning: .high)
)
let value = structured.value
let usage = structured.response.usage
```

The existing provider mapping is preserved: reasoning, usage, model, finish
reason, tools, and oMLX response-format warnings remain available. A malformed
provider envelope or non-JSON structured content is terminal. No new finish
validation or schema enforcement is introduced. Typed message history has no
native reasoning-history field in this revision; recovery preserves supported
role/content/image/tool history and existing controls exactly, without adding one.

## Sensitive traces are explicitly owned

``RecoveryEvent`` is Codable and contains correlation IDs, wire numbers, typed
transitions, status, phase, acceptance, eligibility, delays, and progress counts.
It contains no headers, model names, payload text, tool arguments, provider IDs,
or cause text. Reports and errors have safe default summaries and deliberately
have no automatic Codable conformance for their sensitive evidence.

```swift
policy.observer = { event in controller.recordSafeEvent(event) }
policy.wireObserver = { wireEvent in
    // Explicitly sensitive: request body/headers and response headers/body chunks.
    // The caller chooses storage, access control, retention, and credential handling.
    try secureCapture.record(wireEvent)
}

// Configure the gateway with this updated policy value before making the call.
do {
    _ = try await OllamaGateway(recovery: policy).complete(
        model: "your-local-model", messages: [.user("Hello")], tools: nil,
        config: CompletionConfig()
    )
} catch let error as RecoveryError {
    controller.recordSafeSummary(error.description)
    let sensitive = error.failure.inspectEvidence()
    // Inspect the typed cause/headers/partial bytes only within your protected boundary.
    controller.inspectPrivately(sensitive)
}
```

The body is encoded once; every admitted attempt uses exactly those bytes.
The duration budget starts at the first failure, so a slow initial request does
not consume it. The absolute deadline and duration budget govern retry admission,
including a final check after request capture. An admitted active request may
finish beyond either limit. A refused proposed retry retains the failed actual
attempt's identity, progress and history; it adds no actual attempt.

Observed reasoning, content or tool evidence makes a failed attempt ineligible
for replay, even when buffered delivery is zero and the caller would allow it.
Callers migrating from the preserved recovery slice must handle that terminal
`ineligible` result rather than relying on admission to replay semantic output.
Whitespace keepalives alone still do not count as semantic output.
Request capture precedes dispatch; capture failure there sends zero requests.
Response capture runs at header/body receipt. Decodable semantic evidence is
counted before body capture. Capture failure is terminal, preserves available
observed reasoning/content/tools, and delivers none. Incomplete JSON retains raw
bytes; semantic counters describe decodable evidence, not guessed text.
Cancellation preserves available evidence and wins over successful return and
all retry refusals. A cancellation from `attemptFailed` retains that actual
failure before exactly one terminal cancellation event. Start events describe
launched HTTP tasks; cancellation from those observers cancels the active task.
A request capture identity is proposed until launch and must not be counted as
another wire attempt merely because capture ran.

Wire capture exposes exact body bytes and caller request headers. URLSession
normalizes response headers; this is not raw HTTP framing, TLS traffic, or an
exact duplicate-header/order archive. Hooks are synchronous and must return
promptly; admission producers and injected sleepers must cooperate with cancellation.

## Verified capability limits

``OllamaGateway/recoveryCapabilities`` and ``OMLXGateway/recoveryCapabilities``
report local HTTP task cancellation as supported and remote request cancellation,
exact-attempt status queries, and inference idempotency as unsupported by these
adapters. Local cancellation does not prove remote termination. No invented
idempotency header, model unload, process termination, or tool replay is used.

Recovery-enabled sends use a fresh ephemeral URLSession per wire attempt, with
redirects refused, cookie/credential storage disabled, and body-stream replay
refused. Caller idle timeout configuration is retained. Custom session protocol,
proxy, trust, or TLS configuration is not inherited by this isolated path; callers
requiring those facilities should keep the existing path pending adapter review.

Retry-After supports integer seconds and IMF-fixdate HTTP dates. It is a minimum
backoff; a delay above the ceiling or recovery budget/deadline is refused rather
than shortened. Authentication/invalid-request statuses 400/401/403 remain
permanent even after truncated bodies and explicit status selection. Protocol,
capture and cancellation failures cannot be selected into blind retries.

This buffered slice does not claim streaming, OpenAI, Anthropic, whole-mission,
or six-port parity. Apple controller validation and the declared Swift 6.1
minimum-toolchain validation remain pending when only Linux Swift 6.4 evidence
is available. See the repository's `RECOVERY-CONFORMANCE.md` for actual assertions
and gate outcomes.

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
