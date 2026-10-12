# Recovering Buffered Completions

Opt Ollama, oMLX, OpenAI Chat Completions or Anthropic Messages into request recovery without replaying a broker or session.

Existing gateway initializers keep their one-send behavior and existing error
conversion. Pass a ``CompletionRecoveryPolicy`` through the new `recovery:`
initializer overload to receive ``RecoveryError`` with numeric status, bounded
history, typed causes, and separate observed/delivered progress. This covers
ordinary `complete`, `completeStructured`, and `completeJSON`, including calls
made by ``LLMBroker`` and ``ChatSession``. For streaming migration and terminal rules see <doc:StreamingCompletionRecovery>.

## Admission belongs to the caller

A local timeout, socket closure, HTTP 503/504, keepalive, or model activity cannot
prove that inference ended. Without a hook, eligible OpenAI and Anthropic failures
may retry within the configured limits. Ollama and oMLX require caller admission
unless acceptance is `no`; an ambiguous local failure ends with `admissionRequired`.
Public transports report acceptance as `unknown` after dispatch and cannot establish
that local exception. The default maximum is one attempt, including the initial request.

A configured hook controls every provider: `allow` permits the eligible retry,
`reject` ends with `admissionRejected`, and finishing without either decision ends
with `admissionUndecided`. Pending is never approval. Caller cancellation or recovery
budget expiry cancels pending stream iteration and prevents any subsequent dispatch.
The original actual failure remains in history, including its typed cause.

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
validation or schema enforcement is introduced. Recovery preserves role, content,
image, tool and native reasoning history (see
<doc:BufferedCompletionRecovery#Retain-native-assistant-reasoning-in-caller-owned-history>)
and existing controls exactly.

## Use the shared provider and operation types

``RecoveryFailure`` (including history and admission callback observations) and
``RecoveryEvent`` expose ``RecoveryProvider`` and ``RecoveryOperation``.
Providers are `.ollama`, `.omlx`, `.openAI` and `.anthropic`; their serialized
values are `ollama`, `omlx`, `openai` and `anthropic`. The Anthropic identity
is available even when its gateway trait is disabled.

Every adapter uses `.ordinary` for `complete`, `.structured` for
`completeStructured` and `completeJSON`, and `.streaming` for both recovery
stream APIs. Operation JSON values are `ordinary`, `structured` and `streaming`.
Migrate string comparisons to enum cases and use `rawValue` when a string is
needed for storage or display:

```swift
policy.admission = { failure, nextAttempt in
    let provider: RecoveryProvider = failure.provider
    let operation: RecoveryOperation = failure.operation
    if provider == .ollama && operation == .structured {
        // Supply the caller's decision after checking this exact attempt.
    }
    return controller.admission(failure, nextAttempt: nextAttempt)
}
policy.observer = { event in
    if event.operation == .ordinary {
        controller.recordSafeEvent(event)
    }
}
```

Codable round-trips these closed values, including within lifecycle events.
Unknown values are rejected. OpenAI and Anthropic formerly emitted `complete`
and `completeStructured`; stored lifecycle JSON must migrate those operation
values to `ordinary` and `structured` before decoding. There are no public
adapter-specific aliases. This vocabulary change preserves request encoding,
response handling and admission decisions.

## Sensitive traces are explicitly owned

``RecoveryEvent`` is Codable and contains correlation IDs, wire numbers, typed
transitions, status, phase, acceptance, eligibility, delays, and progress counts.
It contains no headers, model names, payload text, tool arguments, provider IDs,
or cause text. Reports and errors have safe default summaries and deliberately
have no automatic Codable conformance for their sensitive evidence.

Default `Mirror`, recursive reflection and `dump` also exclude sensitive evidence.
``RecoveryFailure``, ``RecoveryError`` and ``CompletionRecoveryReport`` retain
exact safe metadata, correlation identities, progress and recursively safe
failure histories. ``RecoveryEvidence`` exposes only validated provider code
and request ID through its mirror. ``RecoveryWireEvent`` exposes its `kind`,
exact `identity` and received `status` for headers; URLs, headers and bytes are
available only through explicit pattern matching. `inspectEvidence()` still
returns the original headers, received bytes and typed cause without redaction.
These explicit inspection boundaries require your sensitive-data storage policy.

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
Callers must handle that terminal `ineligible` result rather than relying on
admission to replay semantic output.
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

``OllamaGateway/recoveryCapabilities``, ``OMLXGateway/recoveryCapabilities`` and
``OpenAIGateway/recoveryCapabilities``, plus `AnthropicGateway.recoveryCapabilities`
under the `anthropic` or `full` trait, expose all five facilities. Local task
cancellation is supported; remote cancellation and active exact-attempt status
queries are unsupported; inference idempotency and exact-attempt termination are
unknown. See <doc:RecoveryCapabilities> for all twenty values, exact endpoints,
evidence sources, inspection dates and limits.

Recovery-enabled sends use a fresh ephemeral URLSession per wire attempt, with
redirects refused, cookie/credential storage disabled, and body-stream replay
refused. Caller idle timeout configuration is retained. Custom session protocol,
proxy, trust, or TLS configuration is not inherited by this isolated path; callers
that need those facilities must use the legacy entrypoints, which do not recover.

Retry-After supports integer seconds and all three HTTP-date forms from
[RFC 9110 section 5.6.7](https://www.rfc-editor.org/rfc/rfc9110.html#section-5.6.7):
IMF-fixdate, obsolete RFC 850, and asctime. Dates use UTC and the injected wall
clock; RFC 850 two-digit years more than 50 years ahead resolve into the past.
Absent and invalid headers remain distinct and use the jittered policy delay.
A valid value is a minimum backoff: future dates cannot shorten that delay,
and past dates retain jitter. A delay above the ceiling or remaining recovery
budget/deadline is refused rather than shortened. Authentication/invalid-request statuses 400/401/403 remain
permanent even after truncated bodies and explicit status selection. Protocol,
capture and cancellation failures cannot be selected into blind retries.

Buffered and recovery-stream entrypoints cover Ollama, oMLX, OpenAI Chat
Completions and Anthropic Messages. Continuous integration runs the tests on macOS
and on Linux, including the declared Swift 6.1 minimum toolchain.

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
termination. Request status and remote cancellation are unsupported. Eligible failures
may retry without a hook; a configured hook still controls admission. No native reasoning
history is invented.

## Anthropic Messages

Enable the `anthropic` or `full` package trait, then configure the gateway:

```swift
let gateway = AnthropicGateway(apiKey: configuredKey, recovery: policy)
let response = try await gateway.complete(
    model: "claude-sonnet-4-5", messages: [.user("Hello")], tools: nil,
    config: CompletionConfig(maxTokens: 8192, reasoning: .high)
)
let broker = LLMBroker(gateway: gateway)
let chat = ChatSession(broker: broker, model: "claude-sonnet-4-5")
```

The same policy applies to `completeJSON` and `completeStructured`, including
broker and session buffered calls. Structured output keeps the existing schema
instruction and JSON extraction; recovery does not introduce native schema
support. System prompts, supported thinking configuration, images, tool-use and
tool-result history, generation controls and schema instructions are encoded once
and reused byte for byte. Successful responses keep provider input/output usage,
model, message ID, thinking text and tools.

Recovery accepts `end_turn`, `stop_sequence` and `tool_use` finishes. Other finishes
(including `max_tokens`) retain observed evidence and fail without delivering
tools. Accepted `stop_sequence` responses preserve exact content/JSON, raw finish
reason, usage, model and message ID; the buffered typed mapping remains `.other`.
The original initializer and legacy finish handling remain unchanged.
Eligible failures may retry without a hook; a configured hook controls admission.
Request IDs do not imply idempotency. Status,
remote cancellation and termination proof remain unsupported. Recovery uses the
existing idle request timeout and adds no generation deadline.

The universal message adapter does not round-trip signed thinking or
redacted-thinking blocks. Retrying one frozen request preserves its supported
history; it does not add native reasoning history to later broker turns. Raw
capture and `inspectEvidence()` remain explicitly sensitive; safe error summaries
and lifecycle serialization exclude provider credential/payload echoes.

## Retain native assistant reasoning in caller-owned history

Existing message initializers and `.assistant(_:toolCalls:)` still create history
with `nil` thinking. Use the additive overload when retaining a supported provider's
response alongside its content and tool calls:

```swift
let assistant = LLMMessage.assistant(
    previous.content,
    toolCalls: previous.toolCalls,
    thinking: previous.thinking
)
let history: [LLMMessage] = [
    .user("Resolve tomorrow"), assistant,
    .tool(callId: "original-call", content: "Retained tool result"),
    .user("Continue")
]
let response = try await gateway.complete(
    model: "your-local-model", messages: history, tools: nil, config: .init()
)
```

Use the original provider tool-call identifier for the result's `callId`. This
example assumes the previous assistant requested that tool and its result is
already available. The same history can be supplied to `completeStructured` or
`completeJSON`; an admitted retry preserves the encoded request bytes.

Ollama sends populated assistant thinking as `thinking`; oMLX sends it as
`reasoning_content`. Nil values and non-assistant reasoning are omitted.
OpenAI-native Chat Completions omits this unsigned history field, including through
the public OpenAI message adapter. Anthropic also omits it: plain text cannot
represent its signed thinking blocks. This API does not change reasoning settings,
provider response parsing, or broker/session history construction. Callers manage
this history explicitly; no signed-history support or automatic broker retention
is implied.


## Inspect provider failure metadata safely

`RecoveryFailure.providerCode` and `providerRequestID` use the same filtered
values as `inspectEvidence().providerCode` and `providerRequestID`. These guarantees
apply to final failures, attempt history, admission callbacks and completion reports,
including streaming recovery.

Codes must belong to an explicit allowlist. Ollama, oMLX and OpenAI read
`error.code`: `invalid_api_key`, `insufficient_quota`, `rate_limit_exceeded`,
`server_error`, `model_not_found`, `context_length_exceeded`, `invalid_request_error`
and `content_policy_violation`. Anthropic reads native `error.type`:
`invalid_request_error`, `authentication_error`, `permission_error`, `not_found_error`,
`request_too_large`, `rate_limit_error`, `api_error` and `overloaded_error`.
Unknown codes are nil. A code does not change retry classification or grant admission.

Request IDs use `X-Request-ID`, or Anthropic's native `request-id`, with
case-insensitive header names. Only a single unambiguous token of 1–128 ASCII
letters, digits, periods, underscores or hyphens is accepted. Both metadata fields
reject overlap with outbound header values or decoded payload strings, including
credentials inside authorization wrappers, nested schema values and escaped JSON
carried inside payload strings. This conservative check can omit otherwise valid
metadata when it overlaps request content.

Rejected values remain available through explicit sensitive inspection: response
headers, exact received bytes and original typed causes are retained unchanged.
The public metadata filters do not redact that raw evidence. Raw inspection and
wire capture therefore still require the caller's sensitive-data storage policy.
