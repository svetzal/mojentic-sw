# Transient recovery conformance

This file records how the Swift port meets
[the transient recovery contract](TRANSIENT-RECOVERY-2026-10.md), the
[original request](RECOVERY-REQUEST-2026-10.txt), and the October 10, 2026
supplement that aligns the ports with the reviewed Rust implementation
(`mojentic-ru` at `4ca1ed279c02eab37827a1ed07c30e961155ecf3`).

It is a current-state record. It replaces the cycle-by-cycle journals that the
implementation work wrote here. Those journals, `RECOVERY-ACCEPTANCE.md` and
`RECOVERY-REVIEW-EVIDENCE.json` are in git history at `b505f7d`. Do not use
them as evidence: many of their claims were stale at that commit.

## Review

- Revision reviewed: `b505f7d` (October 11, 2026).
- Review date: October 12, 2026.
- Method: a static review of the source and test code against each
  requirement, with Rust `4ca1ed2` as the behavioural reference. The review
  checked that each public entrypoint reaches the recovery engine, and it
  checked the strength of each assertion, not the test names.

**Verdict: met with limits, and with open gaps.** The recovery engine is
complete for buffered and streaming requests on all four maintained completion
adapters. The safety properties hold and have strong tests: one encoded
payload, no replay after observed output, completed tools run once,
authoritative cancellation, and provider-specific admission. The open gaps are in the
section [Open gaps](#open-gaps). Capability gap 1 and provider metadata gap 2
are closed by the acceptance evidence below; the remaining gaps stay open.

## Validation

| Check | Result |
| --- | --- |
| GitHub Actions `build.yml` run 38183304850 on `b505f7d` | `build-macos`, `build-linux`, `build-linux-minimum` (Swift 6.1), `lint` and `format-check` passed |
| All six `.hone-gates.json` gates on macOS 27.2, Swift 6.4, October 12, 2026 | Passed. `swift test --parallel`: 338 tests in 90 suites. `swift test --traits full`: 350 tests in 95 suites. |
| Provider metadata correction, Linux Swift 6.4, October 12, 2026 | All six required gates passed. Default: 341 tests in 92 suites; full traits: 353 tests in 97 suites. Strict format, SwiftLint, release build and DocC with warnings as errors passed. |
| Dependency security for the metadata correction | `osv-scanner scan source --lockfile=Package.resolved`: three packages scanned, no issues found. No dependency changes. |
| Preserved admission amendment | The earlier all-six-gates claim is withdrawn: cancellation could commit session history, and the rollback assertion lacked a producer-completion boundary. The deterministic probe rejected all eight delayed session cases before correction. |
| Cancellation correction, Linux x86_64 Swift 6.4, October 12, 2026 | All six required gates passed on the corrected tree through `scripts/with-gate-environment`: strict format, SwiftLint, release build, default tests (350 in 94 suites), full-trait tests (362 in 99 suites), and DocC with warnings as errors. The focused public-boundary probe failed without the cancellation check and passed with it. |
| Dependency security for the admission amendment and cancellation correction | `osv-scanner scan source --lockfile=Package.resolved` (2.6.0): three packages scanned, no issues found. No dependency changes. |
| oMLX keepalive correction, Linux Swift 6.4, October 12, 2026 | All six required gates passed through `scripts/with-gate-environment`: strict format, SwiftLint, release build, default tests (353 in 95 suites), full-trait tests (365 in 100 suites), and DocC with warnings as errors. The fixture-shaped loopback regression suite failed without the oMLX guard and passed with it. No dependency changes. |
| Capability correction, Linux x86_64 Swift 6.4, October 12, 2026 | All six required gates passed through `scripts/with-gate-environment`: strict format, SwiftLint, release build, default tests (356 in 96 suites), full-trait tests (369 in 101 suites), and DocC with warnings as errors. The full-trait public capability probe rejected the old idempotency value and passed with the correction. |
| Dependency security for the capability correction | `osv-scanner scan source --lockfile=Package.resolved`: three packages scanned, no issues found. No dependency changes. |
| Provider/operation vocabulary correction, Linux Swift 6.4, October 12, 2026 | All six required gates passed through `scripts/with-gate-environment`: strict format, SwiftLint, release build, default tests (361 in 98 suites), full-trait tests (374 in 103 suites), and DocC with warnings as errors. The public loopback probe rejected the old operation vocabulary and passed after migration. OSV scanned three packages with no issues; no dependencies changed. |
| Strict concurrency | Swift 6 language mode (`swiftLanguageModes: [.v6]`), zero warnings |
| DocC | `generate-documentation --warnings-as-errors` passes with default traits. The Anthropic symbols are behind the `anthropic` trait, so this gate does not build their documentation. |

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
| Broker single turn | `generateRecoveryStreamEvents` | `.recoveryFailure(RecoveryError)` event | `generateStreamEvents` |
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
| 503 then success | met, all adapters and operations, exact | `RecoveryStatusConformanceTests`, `RecoveryJSONConformanceTests`, `RecoveryConformanceTests.bothOperationsPreserveShapingAndResults`, `StreamingRecoveryProofTests.publicHTTPRecovery`, `RecoveryMetadataConformanceTests.publicMetadata` |
| 429 and Retry-After | met, all adapters and operations, all three date forms, exact | `RecoveryTimingTests.retryAfterUsesInjectedTiming`, `.pastDateDoesNotReplaceJitterDelay`, `.retryAfterLimitRefusesResend`, `StreamingRecoveryTimingTests.retryAfterPreservesPolicy`, `.retryAfterRefusal`, `RecoveryHTTPDateTests` |
| Persistent 504 | met, all adapters and operations, exact | `RecoveryStatusConformanceTests.persistent504ExhaustsExactLimit` |
| Ambiguous local timeout | met for buffered; streaming uses a truncated body, not a client timeout | `ambiguousFailureWithoutHookRequiresAdmission`, `pendingAdmissionRequiresExplicitDecision`, `timeoutRemainsPendingUntilExplicitAllowOrReject`, `keepaliveAdmissionRemainsPending`, `RecoveryMetadataConformanceTests.metadataDisconnectRequiresAdmission` |
| Cancellation | met; request, admission, backoff, capture and terminal delivery | `RecoveryAdmissionSafetyTests.cancellationWinsOverRefusal` (exact), `RecoveryCancellationTests.cancellationWinsAtEveryBoundary`, `PausedRecoveryOwnershipTests.pausedConsumerClosesActiveHTTPBeforeResuming`, `TerminalRecoveryDeliveryTests.terminalAcceptanceOwnsAttempt`, `pausedTerminalTelemetryCannotSucceed`, `SenderRegistrationCancellationTests`, `StreamingRecoveryCancellationTests` |
| Partial stream | met at the gateway; not tested through broker or session (gap 4) | `StreamingRecoveryTests.semanticInterruptionNeverRetries`, `RecoveryAdmissionSafetyTests.observedSemanticEvidenceRefusesReplay` |
| Permanent errors | met; 400, 401 and 403 stay ineligible with truncated bodies and explicit selection | `RecoveryStatusConformanceTests.permanentStatusesKeepOneSend`, `malformedResponseNeverResends`, `redirectsAreNotFollowed` |
| Keepalive only | met; fixture-shaped oMLX data frames are raw progress only in both recovery APIs, exact bytes and explicit admission | `StreamingRecoveryTimingTests.keepaliveAdmissionRemainsPending`, `OMLXRecoveryKeepAliveTests.keepaliveOnlyRequiresAdmission` |
| oMLX interleaved keepalives | met; October 12 amendment, exact output, genuine metadata and frame indices preserved, terminal success and lifecycle order; OpenAI and `keepalive-2` preserved | `OMLXRecoveryKeepAliveTests.interleavedKeepalivesPreserveGenuineFrames`, `.exactModelAndProviderGuard` |
| Compatibility | met, exact | `ReasoningHistoryConformanceTests.defaultPolicyKeepsOneAttemptWithNilHistory`, `RecoveryConformanceTests.disabledRecoveryRetainsLegacyOneSend`, `.successfulLegacyAndRecoveryResultsMatch`, `ReleaseBaselineCompatibilityTests.configuredRecoveryDoesNotChangeLegacyStreams`, `StreamingRecoveryTests.legacyRemainsSingleSend` |
| Privacy | partial (gaps 2 and 6) | sentinel checks of `String(describing:)`, `String(reflecting:)` and event JSON in `StreamingRecoveryTests`, `AnthropicRecoveryCaptureTests`, `RecoveryStatusConformanceTests` |
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
| Typed causes preserved through broker and session | partial | tested for admission rejection and cancellation; not for capture or length causes (gap 6) |
| Credential-echo tests | partial | safe strings and event JSON are tested; `providerCode` and `providerRequestID` are not (gap 2) |

## Provider metadata acceptance (October 12, 2026)

Gap 2 is closed. `BufferedRecovery.makeFailure` constructs filtered metadata once;
`RecoveryFailure` delegates to those same `RecoveryEvidence` values. Streaming
uses this shared constructor. Unknown codes and outbound credential/payload echoes
are nil on both public surfaces. Codes are explicitly allowlisted; Anthropic reads
native `error.type` and `request-id`. SSE codes are read from the existing typed
provider-error cause when the raw response is not a JSON document. Eligibility,
admission, request encoding and other characterized behavior are unchanged.

`RecoveryProviderMetadataTests.everyPublicExposure` exercises real scripted loopback
HTTP through ordinary, structured, JSON, tool-stream and single-turn recovery for
Ollama, oMLX, OpenAI and Anthropic (under `full`). It separately echoes credentials
into code and request-ID fields, then echoes user text, nested schemas, quoted text
and a Unicode-escaped value inside JSON carried in a payload string into request IDs.
An unrelated request ID and allowed code survive; unknown codes do not. Assertions
read final failure, full history, admission callbacks, completion report history and
both public metadata accessor surfaces. Exact response bytes, captured header
dictionaries, typed HTTP causes, logical/attempt identities, request counts and
byte-for-byte immutable outbound requests are compared.

`wrappedCredentialAndEscapedPayload` explicitly checks a Bearer-wrapped outbound
credential and decoded user content. `RecoveryProviderFrameMetadataTests` covers
allowed, credential and unknown codes in provider-error frames on both streaming
APIs for all four adapters, comparing original typed provider causes and raw frames.
The original implementation failed these public accessor assertions; the corrected
implementation passes `swift test --traits full --filter RecoveryProvider`.

Only gap 2 is removed. Raw evidence is still sensitive and retained unchanged for
explicit inspection. Conservative overlap checks can omit a legitimate token that
also appears in outbound data. The complete token rules and code allowlists are in
[BufferedCompletionRecovery.md](Sources/Mojentic/Mojentic.docc/BufferedCompletionRecovery.md).

## Retry-After HTTP-date acceptance (October 12 robustness amendment)

`RecoveryHTTPDateTests` uses scripted loopback HTTP on Ollama, oMLX, OpenAI
and Anthropic through ordinary, structured, JSON, tool-stream and single-turn
recovery entrypoints. Each IMF-fixdate, RFC 850 and asctime case asserts the
exact parsed UTC date, injected sleep, immutable outbound bytes, logical identity,
distinct attempt identities, wire numbers and lifecycle after 429 then success.
Future minima exceed jitter; past dates retain jitter. Date-based ceiling and
remaining-budget refusals retain typed failure/history and make exactly one wire
request. RFC 850 year tests use the injected clock on both sides of the 50-year
boundary, including exactly 50 years. Absence, invalidity and integer seconds
remain distinct. Existing timing assertions are preserved, including the shared
admission budget timer; StreamingRecovery still delegates timing to BufferedRecovery.

The obsolete-date ceiling probe failed against the original parser by treating
the date as invalid and sending a second request. It passes with the shared
three-format parser. Only gap 3 is closed by this amendment; other gaps below
remain explicit. Legacy non-recovery entrypoints are unchanged.

## Admission amendment acceptance evidence

`RecoveryAdmissionContractTests` closes gap 8 through scripted loopback HTTP on
ordinary, structured, JSON, recovering tool-stream and single-turn stream calls
for Ollama, oMLX, OpenAI and Anthropic (the latter under full traits).

- `providerAdmissionRules` asserts no-hook remote success with exactly two
  requests, byte-identical bodies, unchanged logical identity, distinct actual
  attempt identities and consecutive wire numbers. Ambiguous local failures
  stop after one request with `admissionRequired`. Explicit allow and reject
  control every provider. Reports retain the original typed HTTP cause and
  one-element failure history; lifecycle order and eligibility, acceptance,
  phase, category, reason, operation and scheduled delay are asserted.
- `emptyAdmissionDoesNotReject` proves an empty decision stream never resends,
  returns `admissionUndecided`, preserves the typed original cause/history,
  and emits the matching terminal lifecycle transition.
- `pendingAdmissionTerminates` awaits the hook stream's termination callback
  and asserts its `cancelled` reason for owning-call cancellation and budget
  expiry. It then asserts the public result (`cancelled` or `limitRefused`),
  original typed cause in history, exact lifecycle order, one actual request
  and no subsequent dispatch through each public entrypoint.
- `syntheticUnacceptedLocalFailure` exercises the local acceptance `no`
  exception using an eligible failure with no dispatched identity. It also
  proves a configured rejecting hook controls that case. This is synthetic
  pre-dispatch evidence, not proof of remote termination or nonacceptance.

All admission decisions still converge in `BufferedRecovery.admit`, including
both `StreamingRecovery` entrypoints. Eligibility, cancellation, attempt limits,
Retry-After/backoff, capture and no-replay-after-output checks remain in place.
Other open gaps below remain explicit.

## Paused session cancellation correction

The admission implementation and its tests are preserved. `ChatSession.runStream`
now checks scoped producer cancellation inside its rollback-protected block after
upstream iteration, before committing an assistant turn. Swift can end a cancelled
iterator normally; that end no longer establishes successful session completion.
The check is scoped to recovery cancellation ownership; legacy unscoped streaming
keeps its existing behavior.

`PausedRecoveryOwnershipTests.pausedConsumerClosesActiveHTTPBeforeResuming` keeps
both the original scheduling cases and a deterministic interleaving that pauses the
session producer before upstream iteration. It uses the real public stream and
scripted loopback HTTP across Ollama, oMLX, OpenAI and Anthropic. The caller and
public stream remain alive while HTTP cleanup and keepalive peer closure are
checked. A report callback signals HTTP cleanup; both broker and session relay
completion callbacks must arrive before history is inspected. No sleep substitutes
for either completion boundary.

Assertions retain exact lifecycle order, body bytes, headers, request payload,
logical/attempt identity, one actual wire request, observed and delivered progress,
zero tool executions, restored empty session history, and cancellation on the
retained public stream. The deterministic session cases fail without the scoped
cancellation check and pass with it, for both keepalive and terminal responses.
A broker single-turn relay can expose `.error(.cancelled)` rather than a typed
`recoveryFailure`; this existing limitation is retained, not corrected here.
Other open gaps below remain explicit.

## oMLX keepalive acceptance (October 12 amendment)

`RecoveryStreamDecoder` reuses `OMLXKeepAliveFilter.isKeepAlive` only for the
`omlx` provider, after raw byte capture and before indexing or parsing a frame.
Both recovery stream entrypoints use this decoder. Legacy filtering and the
other three providers retain their existing parsing paths.

`OMLXRecoveryKeepAliveTests` sends the first data frame from the tracked
`stream_thinking.sse` fixture through scripted loopback HTTP and both public
recovery APIs. Keepalive-only truncation retains exact inspected body bytes
and zero observed/delivered semantic progress; admission remains pending with
one wire request until explicitly rejected. Interleaved streams deliver exactly
`é猫`, preserve genuine model/id/timestamp evidence, and end in success with
exact lifecycle order and raw byte totals. A genuine frame precedes a keepalive
so metadata overwriting is detectable. Single-turn terminal evidence is inspected
through the public API; synchronized decoder snapshots additionally verify
metadata and frame indices for both paths, since oMLX does not emit recovery
metrics events. Indices match the stream without keepalives. OpenAI frames with
model `keepalive` and oMLX model `keepalive-2` remain ordinary semantic frames.
The focused suite fails when the provider guard is removed and passes when it
is restored. Only gap 5 is closed by this correction.

## Capability acceptance (October 12 amendment)

`RecoveryCapabilityTests` imports the public module and reads each gateway's
`recoveryCapabilities`. Its four tests assert the literal expected value of all
five fields independently, twenty assertions in total; Anthropic is compiled
and executed under `--traits full`. They neither count fields nor compare
adapters with the shared default. No network dispatch is needed to read this
public capability boundary.

Regression proof: after adding the missing exact-attempt termination field and
Anthropic accessor, the full-trait focused probe exited 1 with four individual
idempotency assertion failures against the old `.unsupported` classification.
Changing that source value to `.unknown` made the same probe exit 0 with all
four tests passing. The additive API surfaces were present in both runs, so the
rejection is behavioral rather than a compilation failure. Assertions also
reject an incorrect local cancellation, remote cancellation, status or
termination field. Only capability gap 1 is closed by this correction.

Limits: no request behavior, admission policy, request bytes, wire counts,
cancellation implementation, legacy entrypoint or provider trait boundary
changes. Capability values do not authorize a retry or prove remote termination.
No live provider cancellation/status/idempotency experiment was performed.

## Provider and operation acceptance (October 12 amendment)

The authoritative root contract's **Operation and provider** amendment is met
by `RecoveryProvider` and `RecoveryOperation`, closed Sendable, Codable enums.
All four provider identities are available independently of provider traits.
Every adapter uses `ordinary`, `structured` and `streaming`, including both
recovery stream APIs. Failures, history, admission callbacks and lifecycle
events expose these types; no adapter-specific string aliases remain.

`RecoveryVocabularyTests.publicVocabulary` characterizes loopback HTTP through
ordinary and structured buffered calls and both recovery streaming paths for
Ollama, oMLX, OpenAI and Anthropic (full traits). Before migration, the same
assertions passed with the old operation expectations. Changing only the
licensed operation expectations rejected OpenAI and Anthropic failures and
lifecycle JSON; the migrated implementation passes. It asserts final failures,
retry and report history, admission observations, lifecycle order, exact
captured/socket request bytes, response evidence, two actual sends, shared
logical identity and distinct attempt identities. Event Codable round-trips
and rejects unknown provider and operation values.

`RecoveryVocabularyCodableTests` consumes the public types without testable
import, exhaustively switches over all cases, asserts exact serialized values
and round-trips, and rejects unknown values and former operation aliases.

Routing retains every characterized decision: buffered operation phase and
interruption handling; streaming provider framing and finish handling; buffered
provider semantic fields; metadata code allowlists and native error/header
fields; oMLX's typed `recoveryChat` operation and keepalive guard. Admission,
cancellation, tools and legacy non-recovery paths keep their prior behavior.
The required gates exercise the existing regression suites for these paths.

Only the vocabulary sub-gap of gap 9 is closed. Other documentation omissions
and the remaining open gaps below remain explicit. No dependency, version,
release or live-inference change is included.

## Open gaps

These are requirements with no implementation, or with an implementation that
no test would catch if it regressed.

4. **Interruption through broker and session.** The content, reasoning and
   tool interruption cases are tested only at the gateway stream APIs. No test
   runs them through `LLMBroker.stream`, `ChatSession.stream` or
   `generateRecoveryStreamEvents`.
6. **Weaker privacy and cause evidence.**
   - No type customises `Mirror`, so `dump` and debugger views reach private
     evidence. No test checks this.
   - The safe fields of `RecoveryEvent` (phase, category, eligible, reason,
     acceptance, delay, operation) are now asserted for admission scenarios.
     Equivalent coverage for other recovery scenarios remains incomplete.
   - Capture and length causes are not asserted after broker or session calls.
   - An invalid policy on the single-turn stream becomes
     `requestFailed("Recovery setup failed")` and loses its typed error.
7. **Policy selection and validation.** No test shows that changing
   `retryableStatuses` or `retryableCategories` changes eligibility. HTTP 500
   and 502 are never exercised. Policy validation, the jitter clamp and the
   exponent cap have no tests.
9. **Documentation.** `CHANGELOG.md` records scoped recovery corrections but
   lacks a general introduction of the recovery API, which is new since
   `v2.1.0`. There is no runnable example under `Examples/`.
   The provider/operation vocabulary sub-gap is closed by the October 12
   acceptance above; the broader recovery API changelog entry and runnable
   example remain missing.

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
