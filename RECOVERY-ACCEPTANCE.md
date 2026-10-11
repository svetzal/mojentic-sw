# Independent whole-mission recovery acceptance review

Reviewed delivered main `3afa86f7514a597630b05b6b063d12a6fa48c739` on October 11,
2026. This is a fresh source and assertion review independent of the earlier
implementation slices, performed by the correction reviewer. It is not a second
concurrent reviewer or a controller gate receipt. No recovery code, fixtures,
dependencies, workflow commands or refs are changed by this review.

The authority is [the contract](TRANSIENT-RECOVERY-2026-10.md), [the original
request](RECOVERY-REQUEST-2026-10.txt), and Stacey's binding October 10 supplement
retained in the external cycle-9 `execution/controller-supplement.txt`. Rust was
inspected from Git objects at exactly `4ca1ed279c02eab37827a1ed07c30e961155ecf3`,
including recovery engine, adapter, frames, policy, types, public tests,
`book/src/core/recovery.md` and `RECOVERY-CONFORMANCE.md`; no sibling working-tree
state is used as normative evidence. Input/source hashes and archive verification
are recorded in [the evidence index](RECOVERY-REVIEW-EVIDENCE.json).

**Verdict: the independent review is complete; unconditional whole-port alignment
is not established.** The integrated request engines and public terminal/tool
boundaries provide substantial Linux conformance evidence. The acceptance ledger
below preserves the narrower assertion coverage rather than treating passing test
names or aggregate counts as proof of every cell. Native-history retry fixtures,
some direct JSON-operation cases, Apple/Darwin and Swift 6.1 validation remain
unproved. These are evidence limits, not newly demonstrated runtime defects.
The formation-gate timeout remains a separate controller obligation. Passing
foreground worktree gates cannot close it.

## Public paths and operation vocabulary

| Provider | B: ordinary | S: structured | J: JSON convenience | T: tool-capable stream | C: single-turn stream |
| --- | --- | --- | --- | --- | --- |
| Ollama | `OllamaGateway.complete` | `.completeStructured` | `.completeJSON` delegates to S | `.streamRecovering` | `.completeStreamEventsRecovering` |
| oMLX | `OMLXGateway.complete` | `.completeStructured` | `.completeJSON` delegates to S | `.streamRecovering` | `.completeStreamEventsRecovering` |
| OpenAI Chat Completions | `OpenAIGateway.complete` | `.completeStructured` | `.completeJSON` delegates to S | `.streamRecovering` | `.completeStreamEventsRecovering` |
| Anthropic Messages (`anthropic` trait) | `AnthropicGateway.complete` | `.completeStructured` | `.completeJSON` delegates to S | `.streamRecovering` | `.completeStreamEventsRecovering` |

B/S require a recovery-configured gateway initializer. Their provider request
builders call `BufferedRecovery.run`; S projects the same decoded response to JSON
inside that attempt. T/C call `StreamingRecovery.run` with the provider decoder.
`OMLXGateway+RecoveryStreams.swift` holds oMLX's stream entrypoints;
`AnthropicGateway+RecoveryDecoding.swift` and `AnthropicRecoveryStreamParser.swift`
hold Anthropic decoding. The common engine serializes one `Data` payload before
its attempt loop. `RecoveryHTTP` owns an isolated ephemeral session, request launch,
header/body observation and local cancellation. The redirect delegate refuses
redirects; there is no application transport retry loop below the request engine.
This review does not prove every opaque URLSession transport behavior on Apple.

`LLMBroker.complete`/`generate` and structured generation call the gateway's buffered
paths. `ChatSession.send` uses broker completion. `Broker.swift` routes tool streams
to `streamRecovering`; `LLMBroker.generateRecoveryStreamEvents` routes single turns
to C. `ChatSession.stream` uses the broker relay. `RecoveryScopedStreaming`,
`RecoveryDelivery`, `RecoveryStreamCancellation` and `RecoveryTerminalAccounting`
retain ownership and settle the attempt at the outer public terminal delivery;
broker tool turns settle before tool dispatch, which clears the outer accounting
scope for arbitrary tool work. None of the request engines executes tools.

Legacy `stream`, `completeStreamEvents` and `generateStreamEvents` retain their
single-send paths. `RecoveryStreamingGateway` lifts unsupported gateways without
fabricated recovery telemetry. Realtime and embeddings are outside completion
recovery; there are no other maintained HTTP completion adapters in this tree.

## Current JSON/status assertion correction

The October 11 correction adds public-boundary evidence Q below. The original
review and A/C limitations remain historical descriptions of those earlier tests.
The targeted permanent-status and persistent-504 cells now use the new assertions;
other J D cells retain their narrower scope rather than inheriting unrelated JSON
coverage. Direct J retry success is established by Q. Populated native-history
retry remains open, as do controller gates. The streaming tool-follow-up correction
below closes the follow-up assertion gap.
Cycle 17 reconciles preservation commit `da8cd59` against read-only verified main
`3cc1d1f`, preserving its integrated metadata and Darwin corrections. Ordered wire
captures also require the previous response's exact bytes before the next request;
terminal and successful operations must publish exactly one recovery report.
These worker changes await Foundry integration and exact-commit platform validation.

## Requirement by provider by operation ledger

Each cell names the exercised operations and evidence keys defined below.
`E` means an applicable public HTTP assertion exists; `L` means limited evidence
(the precise missing conjunction is disclosed below); `D` means delegation was
inspected but that operation is not separately exercised for the requirement;
`S` means inspected public source/documentation without a dedicated HTTP probe;
`N` means the case is inapplicable. A shared engine is supporting source evidence,
not a substitute for a missing public-operation assertion. A cell does not claim
that every listed evidence key individually tests all its operations.

| Requirement / acceptance case | Ollama | oMLX | OpenAI | Anthropic |
| --- | --- | --- | --- | --- |
| Typed errors/status/cause/history, safe inspection | B,S E A; T,C E C,F; J D | B,S E A; T,C E C,F; J D | B,S E A; T,C E C,F; J D | B,S E A; T,C E C,F,H; J D |
| 503 then success: frozen payload, IDs, lifecycle, wire bytes | B,S E A; T E B; C E D; J E Q | B,S E A; T E B; C E D; J E Q | B,S E A; T E B; C E D; J E Q | B,S E A; T,C E D,H; J E Q |
| 429 Retry-After seconds/date/invalid, ceiling/budget refusal | B,S,T,C E D; J D | B,S,T,C E D; J D | B,S,T,C E D; J D | B,S,T,C E D; J D |
| Past dates, exponential bounded delays | B,S E D; T,C L D; J D | B,S E D; T,C L D; J D | B,S E D; T,C L D; J D | B,S E D; T,C L D; J D |
| Persistent 504 exhaustion and final history | B,S,J,T,C E Q | B,S,J,T,C E Q | B,S,J,T,C E Q | B,S,J,T,C E Q |
| Ambiguous timeout/pending admission/allow/reject | B,S,T,C E D; J D | B,S,T,C E D; J D | B,S,T,C E D; J D | B,S,T,C E D,H; J D |
| Admission required without safe evidence | B,S E D; T,C L D; J D | B,S E D; T,C L D; J D | B,S E D; T,C L D; J D | B,S E D; T,C L D; J D |
| Cancellation: pre-dispatch, request, admission, backoff | B,S,T,C E E; J D | B,S,T,C E E; J D | B,S,T,C E E; J D | B,S,T,C E E,H; J D |
| Terminal cancellation, paused consumer, failed-before-cancel order | T,C E F; B,S E E; J D | T,C E F; B,S E E; J D | T,C E F; B,S E E; J D | T,C E F,H; B,S E E,H; J D |
| Successful terminal acceptance and stream end | T,C E F | T,C E F | T,C E F | T,C E F,H |
| Observed content/reasoning/tool fragments forbid resend | B,S E I; T,C E C,H; J D | B,S E I; T,C E C,H; J D | B,S E I; T,C E C,H; J D | B,S E I,H; T,C E C,H; J D |
| Observe before failed capture; typed cause and zero delivery | B,S E A; T,C E C; J D | B,S E A; T,C E C; J D | B,S E A,I; T,C E C; J D | B,S,T,C E H; J D |
| Permanent 400/401/403 despite selected status and truncated body | B,S,J,T,C E Q | B,S,J,T,C E Q | B,S,J,T,C E Q | B,S,J,T,C E Q |
| Malformed protocol, unsupported options, no blind retries | B,S L A,I; T,C L C; J D | B,S L A,I; T,C L C; J D | B,S L A,I; T,C L C,I; J D | B,S,T,C L H; J D |
| Keepalive raw-only progress; no implicit approval | T,C E D | T,C E D | T,C E D | T,C E D |
| Default one attempt, legacy success/API compatibility | B,S E A,K; T,C E K; J D | B,S E A,K; T,C E K; J D | B,S E A,K; T,C E K; J D | B,S E A,H; T E H; legacy C unsupported E H; J D |
| Privacy against credential/payload metadata echoes | B,S E A; T,C E C,F; J D | B,S E A; T,C E C,F; J D | B,S E A; T,C E C,F,I; J D | B,S,T,C E H; J D |
| Progress/metrics values, order, per-attempt accounting | T,C L F,M | T,C L F,M | T,C L F,I | T,C L F,H |
| Rejected length terminal: Progress, Metrics, Failed; no tools | T,C E M | T,C L M | T,C E I | T,C E H |
| Exact wire traces: request and response, including failures | B,S E A; T E B; T,C E F; J D | B,S E A; T E B; T,C E F; J D | B,S E A; T E B; T,C E F; J D | B,S E A; T,C E F,H; J E H |
| Completed tool once, failed/recovered follow-up, depth retained | broker/session B E G; T L G (terminal E) | broker/session B E G; T L G (terminal E) | broker/session B E G; T L G (terminal E) | broker/session B E G; T L G (terminal E) |
| Native reasoning history preserved byte-for-byte across retries | B,S,T,C L N; J D | B,S,T,C L N; J D | B,S,T,C L N (existing omission); J D | B,S,T,C L N (signed history unsupported); J D |
| Redirect refusal/no added total generation timeout | B,S E A,E; T,C L E; J D | B,S E A,E; T,C L E; J D | B,S E A,E; T,C L E; J D | B,S E A,E; T,C L E; J D |
| Remote cancellation/status/idempotency truthfulness | B,S,J,T,C S P | B,S,J,T,C S P | B,S,J,T,C S P | B,S,J,T,C S P |
| Migration examples, all maintained adapters covered | B,S,J,T,C S P | B,S,J,T,C S P | B,S,J,T,C S P | B,S,J,T,C S P |

B/S use `RecoveryBoundary.all` (six default combinations, eight with full traits).
T/C use `StreamingBoundary.all` or `.withAnthropic` as explicitly noted below.
The former excludes Anthropic. The matrix does not infer Anthropic coverage from
an `.all` test. Broker/session tool cases exclude S/C because those are single-turn
operations that do not dispatch tools. Ordinary finish handling outside recovery
and disabled-reasoning parity are not added to this correction.

## Assertion evidence and its limits

All paths below are relative to `Tests/MojenticTests/Gateways/` unless specified.
These descriptions identify assertions to inspect, not just test labels.

**A — buffered request conformance.** `RecoveryConformanceTests.bothOperationsPreserveShapingAndResults`
uses B/S on `RecoveryBoundary.all`: socket `Data` arrays equal capture `Data` arrays,
first/last bytes equal, full logical UUIDs equal, attempt UUIDs differ, wire numbers
are `[1,2]`. It checks exact lifecycle sequence from start through admission/delay/
retry/success, shaped model/schema/tools/sampling/token controls, decoded usage,
private 503 bytes and `RecoveryHTTPStatusFailure`. `assertWireEvidence` checks
captured status/body and capture identity. `successfulCaptureFailureRetainsObservedAndTypedCause`
requires reasoning/content/completed-tool counters, zero delivery and a
`RecoveryCaptureSentinel`. `malformedResponseNeverResends` retains `DecodingError`.
`permanentTruncatedStatusWins` checks selected permanent status, numeric
status, exact partial bytes/headers, `URLError`, ineligibility and lifecycle.
However, those permanent-error and `persistent504IsBounded` tests do not themselves
assert the full socket/capture/identity/lifecycle conjunction. Persistent 504 checks
history wire numbers `[1,2,3]`, distinct attempts/one logical ID, raw counters and
three sends; count/set assertions alone do not close the stronger exhaustion cell.

**B — streaming retry.** `StreamingRecoveryProofTests.publicHTTPRecovery` uses T
on `.all.filter { !$0.single }`: captured and socket request arrays equal, immutable
first/last request bytes, same logical/different attempt UUIDs, ordered eight-event
lifecycle, final delivered UTF-8 count 2, failed identity/status/typed HTTP cause,
and response chunks grouped by the full attempt UUID equal each scripted body.
It covers Ollama/oMLX/OpenAI, not Anthropic or C.

**C — streaming failure/protocol/privacy.** `StreamingRecoveryTests.numericFailuresAndPrivateEvidence`
uses T/C `.withAnthropic`: HTTP 400/401/403 with truncated bodies remain permanent
even after selecting those statuses and transport eligibility; 504 has three failed
attempts. Exact private body bytes, status, raw/delivered counters and `URLError`
versus `RecoveryHTTPStatusFailure` are asserted. Descriptions/reflection/event JSON
exclude sentinel values. It lacks per-attempt socket/capture equality and full
identity/order assertions for this case. `semanticInterruptionNeverRetries` checks
content 6 bytes, reasoning 3 bytes, one observed tool fragment, provider-dependent
reasoning delivery, zero completed delivery, exact retained body and no success.
`captureAfterObservationPreventsDelivery` observes received semantics before capture
failure. `StreamingRecoveryProtocolTests` refuses malformed frames/missing terminal,
invalid counts and privacy echoes without fabricating telemetry.

**D — timing/admission.** `RecoveryTimingTests` B/S checks injected sleeps for
seconds, HTTP dates and invalid values, `.seconds(31)` limit refusal, past-date
jitter, exponential ceilings, bounded history, absolute deadlines and pending
admission. Timeout cases wait for the explicit allow/reject signal and retain typed
transport evidence. `StreamingRecoveryTimingTests` T/C `.withAnthropic` checks exact
sleep arrays `[2]`, `[3]`, `[1]`, ceiling/budget refusal, and keepalive-only raw bytes
with zero observed/delivered semantic progress. `assertRecoveryRequests` compares
all captured/socket bytes, immutable retries, full logical and attempt identities
and wire sequence, and requires every lifecycle identity to match a captured
identity. Past-date/exponential streaming behavior and streaming no-hook refusal
are supported by the shared engine, but not equivalent dedicated T/C fixtures.

**E — cancellation/ownership/limits.** `RecoveryCancellationTests` B/S exercises
request, admission and backoff synchronization, pre-dispatch zero sends and healthy
active generation exceeding the recovery budget. `RecoveryAdmissionSafetyTests`
checks cancellation precedence over refusal; `RecoveryDispatchSafetyTests` checks
expiry at capture/start and actual launch accounting. Streaming cancellation,
`PausedRecoveryOwnershipTests`, `PausedRecoveryDeliveryTests` and
`ScopedRecoveryRelayTests` exercise T/C, broker and session relays. Paused tests
assert peer FIN/cleanup while the same iterator is held and before consumer resume,
exact observed/delivered byte counters and lifecycle failure/cancellation order.
Local FIN proves local cleanup only. It cannot prove remote model termination.
Source limits apply to admission/backoff/retry start rather than an active-generation
wall-clock cutoff; streaming redirect/no-total-timeout evidence is not a full
provider-by-operation wire fixture.

**F — public terminal receipt.** `TerminalRecoveryDeliveryTests.terminalAcceptanceOwnsAttempt`
uses `.withAnthropic`, gateway/broker/session paths and success/cancel controls;
C/session is skipped because no session single-turn event API exists. The held
consumer accepts all expected nonterminal events, pauses immediately before final
sender registration, then cancels without draining. Failure history and exactly
`attemptStarted, attemptFailed, cancelled` must exist before resume. Success accepts
one terminal and stream end and records `attemptStarted, attemptSucceeded`.
`TerminalRecoveryEvidence.verifyTerminalEvidence` compares actual socket request
bytes to capture, full UUID identities across lifecycle/report/request, wire number
1, HTTP 200 and `X-Request-ID`, exact response chunk concatenation, retained body,
`CancellationError`, observed content/reasoning 2/3 UTF-8 bytes and exact delivered
counters. `verifyPublicTerminalCancellation` matches public failure identities,
progress and cause to the retained report. Metrics checks require 3 prompt/12
completion tokens and Anthropic's initial zero completion count. The probe was
executed before this review's document edits: 1 test with 48 parameterized cases (40 execute HTTP; eight C/session cases return early),
exit 0. Historical cycle-11 rejecting delivery proof remains retained separately.

**G — tools across logical requests.** `RecoveryToolSafetyTests.completedToolSurvivesRecoveredFollowUp`
uses all four providers' B through broker/session: original user/assistant/tool
history is decoded, tool input equals `{"relative":"tomorrow"}`, result equals
`{"original-result":"tool-sentinel"}`, original tool ID is retained where encoded,
and follow-up socket bodies are byte-identical across the 503 retry. Full request
identities distinguish the first logical tool turn from the follow-up retry;
`failurePreservesTypedCauseAfterCompletedTool` and `recoveryDoesNotResetToolDepth`
cover typed failure and preserved interaction limit. `TerminalRecoveryToolTests.completedToolRunsOnceBeforeCancelledFinalDelivery`
uses T through broker/session on `.withAnthropic`: consumed events are exactly
`tool, tool-result, content:é`, invocation count is 1, two socket bodies equal the
capture array, two full logical/attempt IDs differ, each wire number is 1, and
lifecycle is exactly first success then second failure/cancel with matching
identities. Final private bytes/cancellation cause and session rollback are checked.
Follow-up tool name/result/ID assertions there use substring checks; the buffered
G fixture supplies the stronger decoded history assertions. Count 1 alone is not
used as tool-safety acceptance.

**H — Anthropic-specific public coverage.** `AnthropicRecoveryTests` covers
B/S/J shaping and supported thinking controls, failed/successful stream telemetry,
legacy unsupported C and privacy. Unsupported-option failure before dispatch
is supported by provider validation code; a complete recovery-enabled public
fixture matrix for that case was not found. `AnthropicRecoveryCaptureTests.captureAndCancellationRetainExactObservedEvidence`
uses ordinary/structured/tool/single paths, exact 2/3-byte content/reasoning counts,
tool fragments/completed calls, zero delivered progress, `RecoveryCaptureSentinel`
including cancellation precedence, exact private body and lifecycle/request IDs.
`partialToolArgumentsInterruptWithoutDelivery` retains partial tool fragments and
`URLError` or original `MojenticError.unexpectedToolCalls` with no replay.
`AnthropicStopSequenceTests.successfulStopSequencePreservesEvidence` directly calls
B/S/J/T/C, checks JSON/content, exact provider evidence and stream metadata/terminal
order, socket/capture equality and raw response bytes. It does not substitute for
all missing direct J error/admission cases. Signed thinking-history round trips are
unsupported in the existing message representation.

**I — observed buffered tails and OpenAI.** `RecoveryAdmissionSafetyTests.observedSemanticEvidenceRefusesReplay`
and `RecoveryConformanceTests.receivedSemanticProgressSurvivesMalformedTail`
retain reasoning/tool evidence from valid prefixes before malformed tails with
zero delivery. `OpenAIRecoveryProofTests.captureFailureRetainsReceivedSemanticsWithoutResend`
uses B: received reasoning/content/tool counters, explicit typed capture cause,
private bytes and exact failed lifecycle. `OpenAIRecoveryTests` covers the original
single-turn tool rejection, recovered generation-control shaping, length/unsupported
terminals and progress/metrics privacy. Unsupported finish reasons here are response
validation, not proof of unsupported request options. OpenAI's observed reasoning does not become
legacy delivered reasoning. The review preserves this existing provider behavior.

**K — compatibility.** `ReleaseBaselineCompatibilityTests` imports the public
module, compiles exhaustive legacy enum switches and checks generic routing/schema
APIs. Its six legacy HTTP combinations are Ollama/oMLX only: 503/body unchanged,
one send, no recovery observer event. `RecoveryConformanceTests.successfulLegacyAndRecoveryResultsMatch`
compares decoded result and request JSON for B/S all providers; disabled recovery
is one send. OpenAI/Anthropic-specific suites supply their narrower legacy stream
coverage. No new `MojenticError` case is introduced by this review.

**M — terminal telemetry.** `StreamingRecoveryTests.validatedLengthPreservesTelemetryOnly`
checks exact UTF-8 content/reasoning, observed tools but no delivered semantics,
12 completion tokens, 6,000,000,000 eval-duration units and Progress, Metrics, Failure
order for Ollama T/C. It does not assert all frame indices or throughput values.
The common terminal and protocol suites exercise oMLX finish evidence and
semantic order; oMLX supplies no separate recovery progress/metrics events in
these fixtures. Existing legacy oMLX length tests are not recovery-boundary proof,
so the oMLX rejected-length recovery cell remains limited.
Full IDs and socket/capture equality at final delivery come from F, not a count-only
telemetry assertion. Public progress and metrics event payloads have no identity
field: F correlates wire, lifecycle, report and public failure identities within
one logical stream, not an ID attached to every public metadata event. Rust-style
per-event identity and per-attempt frame-index assertions are not established by
these tests; fields absent from the normal Swift stream are not fabricated. Malformed frames cannot produce unvalidated metadata.

**N — immutable native history limit.** The engines encode once and reuse bytes,
and ordinary gateway mapping tests check supported reasoning representations.
However, `RecoveryBoundary.complete` supplies only a user message; B/S conformance
therefore does not prove preservation of populated native assistant reasoning
history across a retry. The tool fixtures prove tool history, not signed reasoning
history. No universal public-native-history retry fixture was found. Existing
OpenAI history omission and Anthropic signature limitations remain explicit;
source immutability alone cannot manufacture support or close this evidence gap.

**P — capabilities and migration.** `LocalRecoveryCapabilities.swift`, Anthropic's
capabilities and `CompletionRecoveryCapabilities` report unsupported request status
and remote cancellation and unknown idempotency. A caller's explicit admission
can authorize a resend, but a correlation UUID or model unload/list cannot establish
idempotency or exact request termination. The two DocC recovery guides document
buffered/streaming opt-in migration, typed inspection, sensitive raw captures,
cancellation scope, provider tables and legacy limitations. Realtime/embeddings,
remote inference termination, live efficacy and original 504 attribution remain
outside the proved capabilities.

**Q — direct JSON and complete status evidence.**
`RecoveryJSONConformanceTests.completeJSONRetrySuccess` directly calls J for all
four providers (Anthropic only with its trait), admits a 503 and asserts the exact
JSON result, request schema shaping, immutable ordered socket/capture bytes,
response headers and bodies, full UUID/wire correlation through admission,
lifecycle and report, original typed HTTP cause, and observed/delivered UTF-8
content/reasoning counters. OpenAI retains observed reasoning without claiming
reasoning delivery. It does not expose response metadata through the JSON result.

`RecoveryStatusConformanceTests.permanentStatusesKeepOneSend` and
`.persistent504ExhaustsExactLimit` call B/S/J/T/C through
`RecoveryStatusBoundary.invoke` for Ollama, oMLX, OpenAI and trait-enabled Anthropic.
Every permanent 400/401/403 fixture is truncated. Selected permanent statuses,
transport categories and a permissive admission callback still yield exactly one
socket send, no admission calls and terminal ineligibility. Persistent 504 runs
at limits one and three, each with complete and truncated bodies, and exhausts
without semantic delivery or success. Responses carry distinct per-attempt headers
and UTF-8 bodies; `assertStatusWires` compares ordered complete socket request Data
arrays to opt-in captures, immutable payloads, pairwise distinct attempt UUIDs,
shared logical UUIDs, exact wire numbers, all normalized response headers and
concatenated response bytes. `assertStatusFailure` applies the same exact evidence
to public error, every history entry, each admission and the terminal report.
It retains `RecoveryHTTPStatusFailure.status` for complete bodies and platform-native
`URLError` codes for partial transfers. Exact lifecycle transition/identity arrays,
logical IDs and raw/observed/delivered progress are checked together. Streaming
consumers record no content, reasoning, tools, metadata or successful terminal event.

The early `.jsonPermanentTruncationProof` directly exercised Ollama J before matrix
expansion: the complete 401 input rejected the partial-transfer cause assertion
(exit 1); synchronized truncation preserved that cause and passed (exit 0).
Foundry retains both captures and the validated behavioral proof as execution
scratch. This is assertion/input proof, not a newly fixed runtime defect.

## Comparison and acceptance disposition

Rust at the pinned revision corroborates permanent-status precedence over body
transport failure, observed-before-capture accounting, pending admission, bounded
wire history, safe inspection and no-tool-replay rules. Its wrapper API, typed
`MojenticError::Recovery` and explicit cancellation token differ idiomatically from
Swift's opt-in streaming vocabulary, direct buffered `RecoveryError` and task-local
ownership. Rust's earlier provisional finalization wording is historical. Its lack
of Anthropic and oMLX telemetry coverage is not imported as a Swift exemption;
Swift H/F/M evidence is assessed directly. Neither Rust's live harness cells nor
its gate results prove this Swift revision.

Acceptance remains conditional on the L/D cells and pending platform validation.
The ledger closes the missing review obligation by documenting those limits, not
by converting them to passes. No release, coordinated parity assertion, inference,
benchmark restart or formation-gate success is authorized by this review.

## Historical review verification

All six required gates and three unfiltered audits exited zero on Linux Swift 6.4:
323 default tests and 334 full-trait tests passed, OSV reported no issues and the
API audit reported no breaking changes against `v2.1.0`. Current validation is
foreground execution, independent of historical slice gate receipts. Documentation
clarifications made after that run are followed by a second unchanged full check
set in the same external archive; final receipts apply to the final review files.

Foreground validation results are recorded in `RECOVERY-REVIEW-EVIDENCE.json`.
Complete captures are external execution evidence in the archive named there;
repository documentation does not depend on disposable worker scratch paths.
The six unchanged project gates, standalone SwiftFormat, unfiltered tracked-lockfile
OSV and native full-trait API audit against `v2.1.0` are required for this review.
Historical successful gates are not used as current executions.


## Preservation-run correction verification

All six unchanged required gates passed on Linux Swift 6.4 after the test changes:
native format, strict SwiftLint, release build, default parallel tests (333 tests),
full-trait tests (344 tests) and DocC with warnings as errors. Standalone SwiftFormat,
unfiltered OSV against tracked `Package.resolved` (three packages, no issues) and
the native full-trait API audit against `v2.1.0` (no breaking changes) also exited zero.
Foundry capture retains complete logs; the historical evidence index above describes
earlier executions and is not a receipt for these worker changes. The early proof's
JSON field types, nonzero/zero actual exit receipts and both logs were validated.

This is local working-tree verification, not landed acceptance. Controller validation
of `build-macos` and `build-linux-minimum` on the exact integrated commit remains
required after Foundry finalization; historical CI cannot satisfy it. Native-history
retry and streaming tool-follow-up coverage remain open. No refs were changed.

## Cycle-17 reconciliation verification

The reconciled files retain the cycle-16 public JSON/permanent-status/persistent-504
matrix on controller main `3cc1d1f`. Capture ordering now checks each prior response's
exact bytes before the next request, and report observers retain every callback
rather than finishing a stream after the first report. Both success and terminal
failure require a single report, with the existing history and evidence assertions.
The permanent-401 socket proof was re-executed before these refinements: complete
body rejection exited 1 and synchronized truncation passed with exit 0.

Fresh cycle-17 foreground captures passed all six discovered gates on Linux Swift
6.4: strict native format, SwiftLint, release build, 333 default tests, 344 full-trait
tests and DocC with warnings as errors. Standalone SwiftFormat, unfiltered OSV
(three tracked packages, no issues) and the unchanged native full-trait API audit
against `v2.1.0` (no breaking changes) also passed. These are local file validation
results, not receipts for an integrated main commit.

Foundry owns integration directly onto main. Green `build-macos` and
`build-linux-minimum` on the exact integrated commit remain required before landed
acceptance; no worker refs or runtime behavior are changed by this reconciliation.

## Streaming follow-up acceptance correction

On controller-synchronized main `d99d5c4`, the public streaming G cells now use
`StreamingRecoveryConsumerTests.completedToolRunsOnceAcrossFollowUp` and
`StreamingFollowUpAssertions`. All four providers execute both broker/session
paths for admitted 503 recovery and rejected admission. Assertions compare every
ordered decoded message in actual socket bodies: original user, assistant tool
call with exact name/arguments, and exact tool result. IDs remain `original-tool`
where supported, including Anthropic's native block linkage. Ollama's request
encoding remains ID-less; its emitted call/result IDs must still agree.

The ordered socket bytes equal the full ordered request captures; response headers
and concatenated body bytes match each request identity in order. Retry bytes are
identical. Initial tool completion and follow-up attempts use separate logical IDs,
distinct attempt IDs and wire numbers 1 then 1/2. Exact identity and transition
sequences match admission, lifecycle, both reports and original typed HTTP 503
failure/history/body. Success emits exactly tool/result/content/done, rejection
exactly tool/result then the typed rejection, with one tool execution and no resend
or success terminal after rejection. Successful session history retains exact user
and assistant content; rejected history rolls back. Both public paths also retain
interaction limit 2 across the recovered tool follow-up, rejecting further recursion.

The early public-boundary proof deliberately expected a different original user;
all 16 cases rejected it (exit 1). Restoring the exact original user passed all 16
(exit 0) before expanding identities and event assertions. Foundry retains that
proof, complete foreground logs and independent scoped review as execution evidence.
This correction changes tests and acceptance documentation only.

Populated native reasoning-history retry remains open under N: tool-history
assertions do not establish signed thinking or unsupported native reasoning fields.
Local Linux verification cannot replace controller `build-macos` and
`build-linux-minimum` on the exact landed commit. Both remain pending prerequisites
for integrated acceptance until the controller verifies them.
