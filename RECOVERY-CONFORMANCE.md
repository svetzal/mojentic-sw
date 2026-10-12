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
authoritative cancellation, and explicit admission. The open gaps are in the
section [Open gaps](#open-gaps). The most important are the provider
capability surface (gap 1); provider metadata gap 2 is closed by the acceptance
evidence below.

## Validation

| Check | Result |
| --- | --- |
| GitHub Actions `build.yml` run 38183304850 on `b505f7d` | `build-macos`, `build-linux`, `build-linux-minimum` (Swift 6.1), `lint` and `format-check` passed |
| All six `.hone-gates.json` gates on macOS 27.2, Swift 6.4, October 12, 2026 | Passed. `swift test --parallel`: 338 tests in 90 suites. `swift test --traits full`: 350 tests in 95 suites. |
| Provider metadata correction, Linux Swift 6.4, October 12, 2026 | All six required gates passed. Default: 341 tests in 92 suites; full traits: 353 tests in 97 suites. Strict format, SwiftLint, release build and DocC with warnings as errors passed. |
| Dependency security for the metadata correction | `osv-scanner scan source --lockfile=Package.resolved`: three packages scanned, no issues found. No dependency changes. |
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

| Adapter | Local HTTP cancellation | Remote cancellation | Exact-attempt status | Idempotency | Recovery telemetry |
| --- | --- | --- | --- | --- | --- |
| Ollama | supported | unsupported | unsupported | unsupported | progress and reported metrics |
| oMLX | supported | unsupported | unsupported | unsupported | none (no invented events) |
| OpenAI Chat Completions | supported | unsupported | unsupported | unsupported | usage metrics |
| Anthropic Messages | supported | unsupported | unsupported | unsupported | usage, model, message ID, finish |

Local cancellation does not prove that remote inference stopped. Ollama model
unload, loaded-model lists and oMLX model activity are model-level evidence,
not proof that one request ended. The engine never uses them.
`OllamaGateway`, `OMLXGateway` and `OpenAIGateway` expose these values as
`recoveryCapabilities`. See gap 1 for what is missing.

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
| Keepalive only | met; oMLX frame shape not tested (gap 5) | `StreamingRecoveryTimingTests.keepaliveAdmissionRemainsPending` |
| Compatibility | met, exact | `ReasoningHistoryConformanceTests.defaultPolicyKeepsOneAttemptWithNilHistory`, `RecoveryConformanceTests.disabledRecoveryRetainsLegacyOneSend`, `.successfulLegacyAndRecoveryResultsMatch`, `ReleaseBaselineCompatibilityTests.configuredRecoveryDoesNotChangeLegacyStreams`, `StreamingRecoveryTests.legacyRemainsSingleSend` |
| Privacy | partial (gaps 2 and 6) | sentinel checks of `String(describing:)`, `String(reflecting:)` and event JSON in `StreamingRecoveryTests`, `AnthropicRecoveryCaptureTests`, `RecoveryStatusConformanceTests` |
| Broker tools | met, exact | `StreamingRecoveryConsumerTests.completedToolRunsOnceAcrossFollowUp`, `.recoveryPreservesStreamingToolDepth`, `RecoveryToolSafetyTests.recoveryDoesNotResetToolDepth` |
| Capabilities | not met (gap 1) | none |

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

## Open gaps

These are requirements with no implementation, or with an implementation that
no test would catch if it regressed.

1. **Provider capabilities.** No test reads any capability value.
   `AnthropicGateway` has no `recoveryCapabilities`.
   `CompletionRecoveryCapabilities` is one set of constants for every adapter
   and never reports `unknown`. The contract requires unsupported and unknown
   facilities to be explicit, with the documented evidence source. Rust reports
   idempotency as unknown, cites the provider documentation it inspected, and
   tests the values. To close: decide `unknown` or `unsupported` with a cited
   source for each facility, add the Anthropic property, and test every field
   for every adapter.
4. **Interruption through broker and session.** The content, reasoning and
   tool interruption cases are tested only at the gateway stream APIs. No test
   runs them through `LLMBroker.stream`, `ChatSession.stream` or
   `generateRecoveryStreamEvents`.
5. **oMLX keepalive frames on the recovery path.** The legacy transport drops
   oMLX `data:` frames whose `model` is `keepalive`. The recovery decoder does
   not. Such a frame increments the frame index and records `keepalive` as the
   provider model in private evidence. Retry eligibility is not affected.
   `LocalModelsWithOMLX.md` says both streaming APIs drop these frames. Rust
   skips them.
6. **Weaker privacy and cause evidence.**
   - No type customises `Mirror`, so `dump` and debugger views reach private
     evidence. No test checks this.
   - The safe fields of `RecoveryEvent` (phase, category, eligible, reason,
     acceptance, delay, operation) are almost never asserted.
   - Capture and length causes are not asserted after broker or session calls.
   - An invalid policy on the single-turn stream becomes
     `requestFailed("Recovery setup failed")` and loses its typed error.
7. **Policy selection and validation.** No test shows that changing
   `retryableStatuses` or `retryableCategories` changes eligibility. HTTP 500
   and 502 are never exercised. Policy validation, the jitter clamp and the
   exponent cap have no tests.
8. **Admission edge cases.** No test asserts that a pending admission stream is
   terminated when its call is cancelled or its budget expires. A stream that
   finishes without a decision is reported as `admissionRejected`, and no test
   covers that case.
9. **Documentation.** `CHANGELOG.md` has no entry for the recovery API, which
   is new since `v2.1.0`. There is no runnable example under `Examples/`.
   Operation names are free strings and differ between adapters (`ordinary`
   and `structured` for Ollama and oMLX, but `complete` and
   `completeStructured` for OpenAI and Anthropic).

## Documented limits

These are permitted by the contract and documented. They are not gaps.

- Retries need an admission hook for every adapter, including OpenAI and
  Anthropic. Without one, the outcome is `admissionRequired`. Rust retries
  remote providers without a hook.
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
  and replay still needs caller admission with acceptance `unknown`. The
  library cannot see the discarded bytes.
- The tests cover only some unsupported request options.
