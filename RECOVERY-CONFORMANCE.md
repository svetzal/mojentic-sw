# Transient recovery conformance

This current-state record covers the transient recovery contract and original
request, the October 10 supplement, and the authoritative monorepo root
contract's October 12 amendment. The twelve binding decisions remain in force.
This change closes only the remaining RecoveryEvent lifecycle-evidence portion
of gap 6, under Evidence at the public boundary and binding decision 10.

Recovery is implemented for buffered and streaming completion on Ollama, oMLX,
OpenAI Chat Completions and trait-enabled Anthropic Messages. Lifecycle
expectations below use scripted loopback replies and contract semantics;
UUIDs are anchored to public wire capture, independently of lifecycle output.
No runtime behavior, dependency, version, gate, coverage floor or runtime pin
changes accompany this evidence update.

## Validation and review

All required gates passed on the integrated Linux x86_64 Swift 6.4 source,
with the process file-descriptor limit set to 65,536.
Validation covers every discovered
`.hone-gates.json` gate: strict swift-format, strict SwiftLint, release build,
parallel default tests, full-trait tests and DocC with warnings as errors,
through `scripts/with-gate-environment`. The configured unfiltered OSV scan
checked `Package.resolved`: three packages scanned, no issues found.
The delivered recovery example probe also passed against scripted loopback HTTP.
Apple platform and minimum Swift 6.1 CI results are not claimed for this tree.
The default-trait DocC gate excludes trait-gated Anthropic documentation.

Independent skeptical review inspected public implementation paths and the
strength of assertions, including classification versus terminal outcome,
observed versus delivered progress, cancellation scope and producer completion.
A controlled nil-phase regression first rejected the broker/session interruption
probe; restoration passed. Further event-field corruption, missing/reordered
transitions, masked identities and wrong progress are rejected through that real
boundary. Exact commands, actual exits and complete logs are retained by the
execution evidence system; they are not dependencies of this document.

## Public entrypoints

Every entrypoint below reaches the shared engine (`BufferedRecovery`, or
`StreamingRecovery` for streams) when the gateway is created with
`recovery:`.

| Adapter | Ordinary | Structured | JSON | Tool stream | Single-turn stream |
| --- | --- | --- | --- | --- | --- |
| Ollama | `OllamaGateway.complete` | `completeStructured` | `completeJSON` | `streamRecovering` | `completeStreamEventsRecovering` |
| oMLX | `OMLXGateway.complete` | `completeStructured` | `completeJSON` | `streamRecovering` | `completeStreamEventsRecovering` |
| OpenAI Chat Completions | `OpenAIGateway.complete` | `completeStructured` | `completeJSON` | `streamRecovering` | `completeStreamEventsRecovering` |
| Anthropic Messages (`anthropic` trait) | `AnthropicGateway.complete` | `completeStructured` | `completeJSON` | `streamRecovering` | `completeStreamEventsRecovering` |

`LLMBroker.complete`, `generate` and structured generation use the buffered
paths. `LLMBroker.stream` and `ChatSession.stream` use `streamRecovering`.
`LLMBroker.generateRecoveryStreamEvents` uses the single-turn stream.
`ChatSession.send` uses broker completion. Realtime voice and embeddings are
outside completion recovery.

| Caller | Recovery entrypoint | Error on failure | Legacy entrypoint |
| --- | --- | --- | --- |
| Buffered gateway call | `complete`, `completeStructured`, `completeJSON` on a `recovery:` gateway | `RecoveryError` | same methods on a gateway without `recovery:`, which throw `MojenticError` |
| Tool stream | `streamRecovering` | `RecoveryError` | `stream` |
| Single-turn stream | `completeStreamEventsRecovering` | `.recoveryFailure(RecoveryError)` event | `completeStreamEvents` |
| Broker single turn | `generateRecoveryStreamEvents` | `.recoveryFailure(RecoveryError)`; paused cancellation can expose `.error(.cancelled)` | `generateStreamEvents` |
| Broker tool stream, `ChatSession` | existing methods route to the recovery boundary | `RecoveryError` | existing methods on a gateway without `recovery:` |

The legacy entrypoints send exactly one request, even on a gateway that has a
recovery policy. They never convert a recovery error into a legacy error.

## Provider capabilities

| Adapter and exact POST endpoint | Local HTTP cancellation | Remote cancellation | Active exact-attempt status | Idempotency | Exact-attempt termination |
| --- | --- | --- | --- | --- | --- |
| Ollama `/api/chat` | supported | unsupported | unsupported | unknown | unknown |
| oMLX `/v1/chat/completions` | supported | unsupported | unsupported | unknown | unknown |
| OpenAI `https://api.openai.com/v1/chat/completions` | supported | unsupported | unsupported | unknown | unknown |
| Anthropic `https://api.anthropic.com/v1/messages` | supported | unsupported | unsupported | unknown | unknown |

Every provider/facility pair has an endpoint, evidence source, inspection date
(October 12, 2026) and evidence limit in the
[DocC capability table](Sources/Mojentic/Mojentic.docc/RecoveryCapabilities.md)
and API comments on its public `recoveryCapabilities` accessor. Anthropic's
accessor remains gated on the `anthropic` trait. The provider references reuse
Rust `4ca1ed279c02eab37827a1ed07c30e961155ecf3`'s citations, inspected again:
[Ollama chat](https://docs.ollama.com/api/chat),
[oMLX documentation](https://github.com/jundot/omlx),
[OpenAI Chat Completions create](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create),
and [Anthropic Messages create](https://platform.claude.com/docs/en/api/messages/create).
[URLSessionTask.cancel()](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
is the local task facility, not a provider termination promise.

The authoritative root contract's October 12 Capabilities amendment controls:
`supported` requires a documented facility for the exact endpoint;
`unsupported` means the inspected reference describes no such operation;
`unknown` covers absent or ambiguous guarantees. The endpoint references describe
no cancellation/status operation for an active exact request and provide no
inference idempotency guarantee. Exact-attempt termination remains unknown
because no adapter has evidence for one attempt. Stored OpenAI completion
retrieval and cancellation on other endpoints do not establish active-attempt
status or termination here. Ollama unload/loaded-model lists and oMLX model
activity are model-level evidence, never exact-attempt proof. The engine never
uses them. No remote facility or idempotency header is implemented.

## Contract acceptance cases

"Exact" means the test asserts equality on bytes, identities, counts and
lifecycle order. Test suites are in `Tests/MojenticTests/Gateways/`.

| Case | Status | Proving tests |
| --- | --- | --- |
| Successful completion and 503 then success | met, all adapters and operations, exact | `RecoveryLifecycleCompletionTests`, `RecoveryStatusConformanceTests`, `RecoveryJSONConformanceTests`, `RecoveryConformanceTests.bothOperationsPreserveShapingAndResults`, `StreamingRecoveryProofTests.publicHTTPRecovery`, `RecoveryMetadataConformanceTests.publicMetadata` |
| 429 and Retry-After | met, all adapters and operations, all three date forms, exact | `RecoveryTimingTests.retryAfterUsesInjectedTiming`, `.pastDateDoesNotReplaceJitterDelay`, `.retryAfterLimitRefusesResend`, `StreamingRecoveryTimingTests.retryAfterPreservesPolicy`, `.retryAfterRefusal`, `RecoveryHTTPDateTests` |
| Persistent 504 | met, all adapters and operations, exact | `RecoveryStatusConformanceTests.persistent504ExhaustsExactLimit` |
| Ambiguous local timeout | met for buffered; streaming uses a truncated body, not a client timeout | `ambiguousFailureWithoutHookRequiresAdmission`, `pendingAdmissionRequiresExplicitDecision`, `timeoutRemainsPendingUntilExplicitAllowOrReject`, `keepaliveAdmissionRemainsPending`, `RecoveryMetadataConformanceTests.metadataDisconnectRequiresAdmission` |
| Cancellation | met; exact lifecycle at pre-dispatch capture, active request, admission and backoff; existing terminal delivery and ownership checks preserved | `RecoveryLifecycleFailureTests.cancellationAtRequestCapturePreventsDispatch`, `RecoveryLifecycleScopedCancellationTests`, `RecoveryAdmissionSafetyTests.cancellationWinsOverRefusal` (exact), `RecoveryCancellationTests.cancellationWinsAtEveryBoundary`, `PausedRecoveryOwnershipTests.pausedConsumerClosesActiveHTTPBeforeResuming`, `TerminalRecoveryDeliveryTests.terminalAcceptanceOwnsAttempt`, `pausedTerminalTelemetryCannotSucceed`, `SenderRegistrationCancellationTests`, `StreamingRecoveryCancellationTests` |
| Partial stream | met at gateway and public broker/session boundaries; complete expected lifecycle, exact prefixes, typed interruption, no admission/replay/tool execution, seeded session rollback | `StreamingRecoveryTests.semanticInterruptionNeverRetries`, `RecoveryAdmissionSafetyTests.observedSemanticEvidenceRefusesReplay`, `PublicRecoveryInterruptionTests` |
| Permanent errors | met; 400, 401 and 403 stay ineligible with truncated bodies and explicit selection | `RecoveryStatusConformanceTests.permanentStatusesKeepOneSend`, `malformedResponseNeverResends`, `redirectsAreNotFollowed` |
| Keepalive only | met; fixture-shaped oMLX data frames are raw progress only in both recovery APIs, exact bytes and explicit admission | `StreamingRecoveryTimingTests.keepaliveAdmissionRemainsPending`, `OMLXRecoveryKeepAliveTests.keepaliveOnlyRequiresAdmission` |
| oMLX interleaved keepalives | met; October 12 amendment, exact output, genuine metadata and frame indices preserved, terminal success and lifecycle order; OpenAI and `keepalive-2` preserved | `OMLXRecoveryKeepAliveTests.interleavedKeepalivesPreserveGenuineFrames`, `.exactModelAndProviderGuard` |
| Compatibility | met, exact | `ReasoningHistoryConformanceTests.defaultPolicyKeepsOneAttemptWithNilHistory`, `RecoveryConformanceTests.disabledRecoveryRetainsLegacyOneSend`, `.successfulLegacyAndRecoveryResultsMatch`, `ReleaseBaselineCompatibilityTests.configuredRecoveryDoesNotChangeLegacyStreams`, `StreamingRecoveryTests.legacyRemainsSingleSend` |
| Privacy: default formatting and reflection | met; exact safe children, recursive private-field exclusion and explicit evidence retention | `RecoveryReflectionTests`, `RecoveryReflectionTestSupport`; event JSON checks remain in `RecoveryStatusConformanceTests` |
| Broker tools | met, exact | `StreamingRecoveryConsumerTests.completedToolRunsOnceAcrossFollowUp`, `.recoveryPreservesStreamingToolDepth`, `RecoveryToolSafetyTests.recoveryDoesNotResetToolDepth` |
| Capabilities | met; all twenty values explicitly asserted through public accessors, including Anthropic under full traits | `RecoveryCapabilityTests` |

## Supplement requirements

| Requirement | Status | Evidence |
| --- | --- | --- |
| One encoded payload, identical bytes across attempts | met | encoded once in `BufferedRecovery` and `StreamingRecovery`; `assertStatusWires` compares socket bytes |
| Hidden transport retries and redirects disabled | met | one ephemeral `URLSession` per attempt, redirects refused (`RecoveryHTTP`); `redirectsAreNotFollowed` |
| Attempts separate from completions, interactions and tool depth | met | `recoveryDoesNotResetToolDepth`, `recoveryPreservesStreamingToolDepth` |
| Numeric status, headers, bytes, causes and history retained | met | `inspectEvidence()`; exact checks in `RecoveryStatusTestSupport` |
| Truncated body never overrides a permanent status | met | `permanentStatusesKeepOneSend` (4 adapters, 5 operations, 3 statuses) |
| Evidence counted before the body capture hook; failed hook is terminal | met | `RecoveryConformanceTests`, `StreamingRecoveryTests`, `AnthropicRecoveryCaptureTests`, `OpenAIRecoveryProofTests` |
| Duration budget from first failure, monotonic; absolute deadline; no generation timeout | met | `slowInitialFailureStartsBudgetAndAdmittedRequestMayOutliveLimits`, `expiredAbsoluteDeadlinePreventsAdmission`, `expiresWhileAdmissionIsPending`, `healthyActiveGenerationOutlivesRecoveryBudget`, `expiryDuringRetryCapturePreventsResend` |
| Provider progress and metrics preserved, with identity and per-attempt frame index | met | `RecoveryMetadataConformanceTests.publicMetadata`, `validatedLengthPreservesTelemetryOnly` |
| Native reasoning history (owner decision, October 11) | met | `LLMMessage.thinking`; sent as Ollama `thinking` and oMLX `reasoning_content`, omitted for OpenAI and Anthropic; `populatedHistoryAcrossPublicRetryBoundaries` (5 operations, 4 adapters, full message arrays), `additiveMessageAPIsAndCodableCompatibility` |
| Streaming tool follow-up with exact assistant and tool structure | met | `completedToolRunsOnceAcrossFollowUp` compares the whole `messages` array |
| Typed causes preserved through broker and session | met for policy, capture and length | `TypedRecoveryErrorTests`: every provider and public recovery boundary, scoped and unscoped streams, exact policy case/message, synthetic capture values, original length evidence, wire identities and seeded rollback |
| Credential echoes | met | `RecoveryProviderMetadataTests`, `RecoveryProviderFrameMetadataTests`: safe code/request ID filtering, outbound credential/payload echoes, raw evidence retained |

## Complete lifecycle evidence

The lifecycle acceptance arrays compare the complete ordered `RecoveryEvent` array:
logical ID, attempt ID, wire number, transition, provider, operation, phase,
category, status, eligibility, reason, acceptance, delay and complete observed
and delivered progress, including nil values. `RecoveryLifecycleEvidence`
constructs expectations from explicit fixture values and wire identities, never
from emitted events or production classification helpers. Before-encoding
cancellation has no wire candidate, so only its logical UUID is anchored to
the public error; all other expected fields remain independently specified.

| Scenario | Public acceptance evidence |
| --- | --- |
| Success and retry-to-success | `RecoveryLifecycleCompletionTests`, `RecoveryLifecycleBufferedCallerTests`: ordinary, structured and JSON buffered calls, broker projections and session/image callers; gateway/broker/session tool streams and gateway/broker single-turn recovery streams; exact socket bytes, identities, Unicode content and terminal delivery |
| Partial content, reasoning and tools | `PublicRecoveryInterruptionTests`: `LLMBroker.stream`, `ChatSession.stream`, `generateRecoveryStreamEvents`; hidden reasoning and withheld tools remain observed-only; exact prefixes, raw bytes, typed causes, no admission/replay/tool execution and seeded rollback |
| Cancellation before dispatch | `RecoveryCancellationTests` before encoding; `RecoveryLifecycleFailureTests` at request capture on all typed public paths; no wire attempt consumed, nil identity, acceptance no and zero socket requests |
| Active request, admission and backoff cancellation | `RecoveryCancellationTests`, `StreamingRecoveryCancellationTests`, `RecoveryLifecycleBufferedCancellationTests`, `RecoveryLifecycleScopedCancellationTests`: original attempt retained, exactly one request, observed/delivered progress, ordered terminal events, held active socket closure and completed relay before session history assertion |
| Capture before/after dispatch | `TypedRecoveryErrorTests.captureCause`: all applicable gateway, broker, session, image, projected, tool-stream and single-turn paths, scoped/unscoped; `RecoveryCancellationTests` separates request/header/body capture; exact synthetic causes and zero delivered progress |
| Malformed and length responses | `RecoveryLifecycleFailureTests.malformedAtEveryPublicPath`, `TypedRecoveryErrorTests.lengthCause`: all typed public paths; original length evidence, exact observed versus delivered bytes, socket bodies, no tool execution and session rollback |
| Budget/deadline refusal | `RecoveryLifecycleLimitTests`: all typed public paths, pre-admission and prospective backoff refusal; HTTP classification stays selected/eligible, original typed cause/attempt retained, no resend |
| Status exhaustion, permanent errors, policy and bounded delays | Existing `assertSelectionLifecycle`, `RecoveryPolicySelectionTests`, `RecoveryBoundedTimingTests` remain intact, including HTTP 500/502/418 selection, category selection, saturation, non-finite jitter and exponent cap |

All adapter matrices include Anthropic under full traits. Tool fragments are
inapplicable to single-turn APIs, which accept content and reasoning only.
A streaming length response after observed content ends as interrupted;
a buffered length response ends as ineligible for Anthropic (adapter decoding
rejects length) and malformedResponse for the other adapters, with no delivered
content. All retain the original typed length cause.
Lifecycle reasons describe classification: observed semantic output can take
precedence over capture/cancellation/length outcome names. Limit refusal keeps
the original selected HTTP classification. Starting events have no status,
phase, category, eligibility, reason or delay, and zero progress.

The new lifecycle fixture suites serialize their parameterized cases to bound
additional socket usage. The gate environment retains its existing descriptor
floor; validation uses a higher host limit. The parallel gate and all
existing cancellation tests remain unchanged.

The existing sender-registration cancellation, cleanup, socket closure, terminal
ownership, telemetry, completed-tool execution and tool-depth checks remain
unchanged. A paused broker single-turn relay can expose its established typed
`MojenticError.cancelled`; its underlying recovery lifecycle/report still has
the exact cancelled attempt. No scheduling cause or remote termination is
inferred, and no cancellation behavior is changed.

## Preserved contract evidence

Provider metadata tests assert allowlisted codes and non-echo request IDs across
all public exposures, including Anthropic native field names, while retaining raw
private evidence for explicit inspection. Reflection tests require typed safe
children and exact identities/history, excluding private evidence recursively.
Capability tests assert all twenty facility values and their evidence limits.
Retry-After tests cover all three HTTP-date forms, invalid and past values,
provider minimum delays and bounded monotonic recovery timing.

Admission tests cover missing hooks (remote retries versus local admission),
explicit allow/reject, undecided streams, asynchronous expiry and cancellation
precedence. Exact request bytes, status, raw response bytes, histories and typed
causes accompany the checks. Recovery budgets start at first failure and do not
cut off healthy generation. Policy selection and bounded backoff retain their
complete independently expected lifecycle arrays.

Typed policy/capture/length tests retain the original errors before projection,
including multimodal image payloads and session rollback. Native history support
remains Ollama/oMLX only. Recovery metadata tests retain provider telemetry,
frame indices and length progress/metrics/failure ordering. Completed tool
follow-up tests still prove one tool execution without depth reset or replay.

Binding decision 12 documentation remains delivered in the Unreleased notes,
DocC recovery guides and executable `RecoveryExample`, with
`scripts/probe-recovery-example.py` exercising explicitly admitted 503 then
success and identical payload bytes. No changelog or example change is needed
for this assertion-only correction.

## Open gaps

No remaining portion of gap 6 is open. The documented limits below remain
explicit; this statement concerns completion recovery evidence, not coordinated
cross-port release readiness or live inference.

## Documented limits

These are permitted by the contract and documented. They are not gaps.

- Without a hook, eligible OpenAI and Anthropic failures may retry. Ollama and
  oMLX need admission unless acceptance is `no`. A configured hook controls all
  providers, and a stream ending without a decision returns `admissionUndecided`.
  Public transport evidence cannot establish acceptance `no` after dispatch;
  the local exception is covered with synthetic pre-dispatch evidence only.
- The admission hook runs before the Retry-After ceiling check. A caller's
  checks can therefore run for a retry that the engine then refuses. Rust
  refuses first.
- Acceptance is `unknown` for every dispatched attempt. Phase is nil until
  headers arrive.
- Recovery requests use an isolated session. It does not inherit custom session
  protocols, proxy, trust or TLS settings. It keeps the idle timeout.
- The paused-consumer guarantee needs `withRecoveryStreamCancellation`.
- Native reasoning history is not carried into broker tool follow-ups or
  session history. Anthropic signed or redacted thinking and OpenAI-native
  reasoning history are not supported.
- There is no remote cancellation, request status, termination proof or
  inference idempotency for any adapter.
- On Apple platforms, CFNetwork can discard partial body bytes when the server
  closes immediately after sending them. The attempt then shows no progress,
  and local-provider replay still needs caller admission with acceptance `unknown`.
  The library cannot see the discarded bytes.
- The tests cover only some unsupported request options.
