# Transient recovery conformance

This record describes the Swift implementation at source commit
`965e884aa39ab548dca42b7764b0b8e7b8f2d8b7`, mapped to the nine original
gaps, twelve binding owner decisions and the authoritative monorepo contract's
October 12 amendment. The previously reported authoritative contract SHA-256 is
`a53a3a4eb118fa4687dd703d6ce918dd40dd6cb4eda796abc6c429a6e932e7a3`.
That historical inspection is not repeated here; the repository's older contract
copy does not supersede it.

The original implementation requirements are closed by the executable evidence
mapped below. Under the October 13 owner decision, unavailable historical
per-call causes remain explicit historical limits. Controlled replacement
findings establish only their own measured interleavings. Passing validation
does not attribute the original failures.

Recovery is implemented for buffered and streaming completion on Ollama, oMLX,
OpenAI Chat Completions and trait-enabled Anthropic Messages. Lifecycle
expectations below use scripted loopback replies and contract semantics;
UUIDs are anchored to public wire capture, independently of lifecycle output.
No runtime behavior, dependency, version, gate, coverage floor or runtime pin
changes accompany this evidence update.

## Historical limits

The historical descriptor-only full-suite trace was reported without endpoint
and wire bytes, HTTP delegate callbacks or producer identities. It cannot
establish exact per-call causes for its readiness, timeout, malformed-tail or
interruption failures. Aggregate descriptor counts, matching case labels and successful
reruns do not reconstruct that missing evidence. Under the October 13 owner
decision this remains a historical evidence limit, not an open implementation
requirement. Current assertions do not establish the original per-call causes.

Controlled replacement comparisons recorded failures with per-call wire capture
and HTTP completion while fixtures were held. These findings apply to those
replacement calls only. They neither identify the original sends nor establish
production cancellation failure. The public ownership-selector proof separately
rejects selecting a sender by occurrence count and uses the actual producer's
call-site role. It establishes fixture selection behavior, not the cause of the
original readiness failures.

`SenderRegistrationCancellationTests.publicHTTPBeforeSenderRegistration`
compares an incomplete first record with the same response completed through a
separate fixture signal. Prefix bytes alone do not establish sender readiness.
With the record completed, cancellation occurs before continuation registration,
while consumer, registration and fixture are independently held. Assertions
compare exact request/response bytes and wire identities, observed/delivered
progress, typed causes and complete expected lifecycle fields. HTTP delegate
completion, actual producer completion and successful socket close or peer FIN
are checked separately before consumer resumption. JSON request inputs compare
as values because encoder key order can differ; raw bytes remain captured.
`scripts/characterize-recovery-traces.py` checks captured calls and ordering.
No new causal-reconstruction run accompanies this record correction.

## Focused validation evidence

The focused full-traits run exercises `SenderRegistrationCancellationTests` and
`PublicRecoveryInterruptionTests` with opt-in per-call tracing. The correlator
`scripts/characterize-recovery-traces.py` checks those calls for independent
byte/ordering violations and HTTP timeouts before registration. Commands,
results and log hashes for this validation are listed below.

| Focused coverage | Executable assertions |
| --- | --- |
| Incomplete versus completed framing | 20 paired cases: each of Ollama, oMLX, OpenAI and Anthropic, tool streams at gateway/broker/session and single-turn streams at gateway/broker. Single-turn session is inapplicable. Exact first-line prefix/suffix and request values are compared separately from raw captured bytes. |
| Relay ownership | Two additional Ollama cases, broker single-turn and session tool stream, select the actual producer role independently of the framing comparison. |
| Public interruption | 32 matrix cases across all four adapters: content/reasoning/tool at broker/session tool streams and content/reasoning at single-turn broker streams; one additional unfinished-tool session rollback case. |
| Boundary assertions | Exact socket/request/response bytes; unmasked logical and attempt identities; typed causes; independently expected complete lifecycle events; observed/delivered prefixes; one interrupted request; no admission or tool execution; seeded session rollback. Sender cases separately require HTTP completion, producer completion and socket closure before paused-consumer resumption. |

These controlled tests establish only their own measured interleavings; they
cannot reconstruct the original failures. They directly cover gaps 4 and 6 and
decisions 6, 8, 9 and 10. Other mappings below are exercised by the broad gates.

## Validation results

All commands below test source commit
`965e884aa39ab548dca42b7764b0b8e7b8f2d8b7` with this documentation correction
applied. Only `RECOVERY-CONFORMANCE.md` differs from that commit; implementation,
tests, dependencies and gates are identical. Every log SHA-256 below is computed
from a run performed for this correction, over stdout bytes followed by stderr
bytes. Commands use the existing gate environment.

| Command | Result | Log SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0; no format diagnostics | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0; 209 files, 0 violations | `e79a9f5c4d3e297f0ab8b5705b38e7cd5023058bb3e8849bf4bf1c99bde33972` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0; release build succeeded | `494240bb9a513d16a99931ca77d775146dddacae498096c63524e03ff15818a6` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 388 tests, 109 suites, 0 failures | `43fca73e51b8a31fe227ac66c4a5e7f5e45797966e7d34da444daf32e383ee48` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 401 tests, 114 suites, 0 failures | `4783621ce4216ddf49cae1d6d601c293efbe76a0f742e1193d27b4f2fe1fc346` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0; 1 target (Mojentic), warnings-as-errors | `91e27ba424e01cb99d180d19a34e67417cad25ee98f20432ade294b67a4f8c0c` |
| `RECOVERY_TRACE_DIRECTORY="$TRACE_DIRECTORY" ./scripts/with-gate-environment swift test --traits full --filter 'SenderRegistrationCancellationTests\|PublicRecoveryInterruptionTests'` | Exit 0; 4 test functions, 2 suites, 0 failures | `f254b3290f20b248244c5abeb5d7156c34a6c46f137a80abfc0e9b792a9e27b0` |
| `python3 scripts/characterize-recovery-traces.py "$TRACE_DIRECTORY" --output "$CORRELATION_OUTPUT"` | Exit 0; 75 calls, 0 byte/ordering violations, 0 HTTP timeouts before registration | `b24ba639a96285a3875bd232f442d2ab9cad7b4d74e25982adc3d3588b460d79` |
| `python3 scripts/probe-recovery-example.py` | Exit 0; 2 HTTP requests, 1 admitted retry, identical resend bytes and safe diagnostics | `bf1ef1f033198c63b62ff241f5b30ca8de18081d031d9293aebd1a54b7935100` |

For the focused commands, `$TRACE_DIRECTORY` represents the same trace input
directory in both commands; `$CORRELATION_OUTPUT` represents the correlator's
output argument. The format log is empty (the successful command is silent).

The six required gates are defined in `.hone-gates.json`. A successful test
count alone is insufficient evidence of boundary conformance; the assertion
mappings below describe the behavior checked.

Apple-platform and minimum Swift 6.1 validation on this revision remain pending.
Linux results do not establish those results. Default-trait DocC excludes
trait-gated Anthropic symbols. No cross-repository boundary changed in this
record correction; this record makes no claim of a shared versioned executable
contract verified by another repository.

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
accessor remains gated on the `anthropic` trait. The capability table links
the provider references:
[Ollama chat](https://docs.ollama.com/api/chat),
[oMLX documentation](https://github.com/jundot/omlx),
[OpenAI Chat Completions create](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create),
and [Anthropic Messages create](https://platform.claude.com/docs/en/api/messages/create).
[URLSessionTask.cancel()](https://developer.apple.com/documentation/foundation/urlsessiontask/cancel())
is the local task facility, not a provider termination promise.

The authoritative root contract's October 12 Capabilities amendment controls:
`supported` requires a documented facility for the exact endpoint;
`unsupported` means the inspected reference describes no such operation;
`unknown` covers absent or ambiguous guarantees. The capability table records
no cancellation/status operation for an active exact request and no inference
idempotency guarantee. Exact-attempt termination remains unknown
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

The lifecycle fixture suites serialize their parameterized cases to bound
additional socket usage. The gate environment sets a descriptor floor of 8,192.

Sender-registration tests assert ownership selection, cleanup, socket closure
and producer completion independently. A paused broker single-turn relay can
expose its established typed `MojenticError.cancelled`; its underlying recovery lifecycle/report still has
the exact cancelled attempt. No scheduling cause or remote termination is
inferred, and no cancellation behavior is changed.

## Contract assertions

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
success and identical payload bytes against scripted loopback HTTP.

## Reconciliation of the nine original gaps

Closure is based on public implementation paths and assertion bodies, not names,
aggregate counts, masked identities or a schema match. The existing assertions
and coverage remain unchanged.

| Original gap at `54a0662` | Current evidence and disposition |
| --- | --- |
| 1. Provider capabilities | Closed: all five fields on all four public adapters are asserted in `RecoveryCapabilityTests`; API comments and `RecoveryCapabilities.md` retain endpoint, source, inspection date and evidence limits. |
| 2. Credential-shaped metadata | Closed: provider-specific allowlisted codes and non-echo IDs, including Anthropic fields, are checked across safe exposures in `RecoveryProviderMetadataTests`; raw values remain explicit-inspection evidence. |
| 3. Retry-After dates | Closed: `RecoveryHTTPDateTests` checks all three date forms and invalid/past values; timing suites assert provider minimums and refusal rather than shortening limits. |
| 4. Public interruption | Closed: `StreamingRecoveryTests.semanticInterruptionNeverRetries` exercises gateway paths; `PublicRecoveryInterruptionTests` and its support exercise broker and session paths with exact captured identities/bytes, delivered prefixes, typed causes, full lifecycle, zero replay/tool execution and seeded session rollback. Tool fragments do not apply to single-turn APIs. |
| 5. oMLX keepalive frames | Closed: `OMLXRecoveryKeepAliveTests` checks real data frames, interleaved frames, metadata/index preservation and provider/model guards through both recovery stream APIs. |
| 6. Privacy, lifecycle and typed causes | Closed: `RecoveryReflectionTests` checks exact safe reflection children and recursive private evidence exclusion; lifecycle suites compare independently expected complete events; `TypedRecoveryErrorTests` retains policy/capture/length types across public paths. Sender assertions distinguish HTTP completion, producer completion and socket closure. Historical traced causes remain limited as described above. |
| 7. Policy selection/validation | Closed: `RecoveryPolicySelectionTests` removes defaults, adds a non-default and removes categories through real HTTP paths, including 500/502; `TypedRecoveryErrorTests.invalidPolicy` checks validation; `RecoveryBoundedTimingTests` checks non-finite jitter, saturation and exponent bounds. |
| 8. Admission edges | Closed: `RecoveryAdmissionContractTests` checks missing hooks, allow/reject, distinct undecided reason and pending-stream termination on cancellation/expiry; request bytes, typed causes, histories and lifecycle supplement attempt counts. |
| 9. Documentation and typed vocabulary | Closed: Unreleased notes, DocC capability/error guidance and `RecoveryExample` are delivered; `RecoveryProvider` and `RecoveryOperation` are closed types used across adapters. The executable probe checks actual HTTP and identical resend bytes. |

## Twelve binding decisions

| Decision | Evidence |
| --- | --- |
| 1. Remote/local admission without hook | `RecoveryAdmissionContractTests.providerAdmissionRules`; local acceptance `no` is synthetic pre-dispatch evidence only. |
| 2. No decision is not rejection | `emptyAdmissionDoesNotReject` asserts `admissionUndecided` and no resend. |
| 3. Five documented capabilities | Gap 1 evidence above, including trait-enabled Anthropic. |
| 4. Safe provider metadata | Gap 2 evidence above; private raw evidence remains inspectable. |
| 5. Three HTTP-date forms | Gap 3 evidence above. |
| 6. Closed provider/operation types | `RecoveryProvider`, `RecoveryOperation`; exact lifecycle/metadata assertions on adapter matrices. |
| 7. oMLX keepalive semantics | Gap 5 evidence above. |
| 8. Typed policy/capture/length errors | Gap 6 evidence above, including broker single-turn and applicable session paths. |
| 9. Public partial interruption | Gap 4 evidence above, including delivered versus observed progress and no tool replay. |
| 10. Lifecycle, policy, jitter and admission termination | Lifecycle matrix above; gaps 7 and 8 evidence; exact fields and histories rather than counts alone. |
| 11. Safe default formatting/reflection | `RecoveryReflectionTests` and metadata/privacy suites retain sentinel and exact-child assertions. |
| 12. Documentation/migration/example | Gap 9 evidence above; `LocalModelsWithOMLX.md` describes the delivered keepalive behavior. |

## Open gaps

No remaining implementation or executable assertion requirement from the nine
original gaps or twelve binding decisions was identified in this reconciliation.
Apple-platform and minimum Swift 6.1 verification remains pending on the
reviewed revision. Historical per-call attribution is an
explicit evidence limit under the October 13 owner decision, not an unimplemented
recovery requirement. Controlled findings and green gates cannot close it.

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
