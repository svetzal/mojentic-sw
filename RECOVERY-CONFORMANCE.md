# Buffered local-provider recovery conformance

Scope: opt-in buffered Ollama and oMLX ordinary/structured completion recovery.
Preserved Swift slice: `e09f7ef4ddd04f8616a9a141aecec2c35d76f074`. Reviewed Rust reference:
`4ca1ed279c02eab37827a1ed07c30e961155ecf3`. Working source hashes, input hashes,
reference snapshots, actual capture receipts and gate results live in `.foundry/`.
This worktree is deliberately uncommitted for Foundry finalization.

## Public entrypoints and compatibility

Both gateways preserve their original initializer signatures, including function
references. Explicit `recovery:` overloads enable `CompletionRecoveryPolicy`.
`complete`, `completeStructured` and the `completeJSON` convenience path use one
buffered recovery engine. LLMBroker and ChatSession use these same gateway paths;
there is no outer agent/session retry loop. Policy absence retains legacy
MojenticError conversion and one send, including its existing body-bearing error
strings. Recovery errors retain typed causes behind explicit inspection and have
safe default descriptions. Policy presence defaults to one wire attempt.

Successful response mapping, usage, finish reasons, model, native reasoning output,
oMLX warning metadata and ordinary requested-JSON behavior match legacy results.
Explicit structured APIs parse JSON; they do not add schema enforcement. No
ordinary generation finish validation, reasoning-mode feature, or native reasoning
history field was added. Swift's existing typed message history supports roles,
content, images and tool exchanges; recovery encodes the existing adapters once.

## Assertion-bearing loopback evidence

Tests serve scripted HTTP through real URLSession requests on ephemeral loopback
ports. A dedicated blocking server thread owns each fixture, and AsyncStream
signals/conditions synchronize active sends and admission. No live model, provider
service, benchmark, harness worker or campaign is invoked. Engine clock, wall time,
sleeper and jitter are injected where recovery timing is asserted. Timeout cases
hold the first response until the explicitly configured idle timeout fires; a
larger timeout avoids the earlier parallel-fixture contention race.

`RecoveryBoundary.all` runs Ollama/ordinary, Ollama/structured, oMLX/ordinary and
oMLX/structured. Tests below exercise these four boundaries unless stated otherwise.

| Requirement | Actual assertions / test names |
| --- | --- |
| Proof-first public-boundary rejection and correction | `expiryDuringRetryCapturePreventsResend`: the preserved engine incorrectly sends an expired retry and returns success; corrected engine refuses without another wire request, preserving exact body bytes, actual identity, typed cause, history, progress and ordered lifecycle. `.foundry/proof.json` records actual exits 1/0 and complete logs. The final probe also covers expiry during transport setup. |
| Successful request/result preservation | `bothOperationsPreserveShapingAndResults`, `successfulLegacyAndRecoveryResultsMatch`: real body bytes remain equal on retry, legacy/recovery decoded requests and entire results agree; model, stream, temperature, token cap, reasoning hint, tools, schema/format, usage, model evidence and warning metadata are checked. |
| Ordinary JSON controls retain legacy behavior | `ordinaryJSONFormatKeepsLegacySuccessfulResult`: both providers retain the legacy successful ordinary result even when JSON mode was requested and content is plain text. These assertions pass in the current captured parallel and full-traits suites; no separate historical rejection artifact is claimed. |
| Retry-After seconds/date/invalid | `retryAfterUsesInjectedTiming`: numeric 2, an IMF-fixdate resolving to 2 seconds, invalid and negative values assert typed parsing and exact sleeper values. `pastDateDoesNotReplaceJitterDelay` asserts 0.5-second jitter when the date is past. |
| Ceiling/budget/deadline refusals | `retryAfterLimitRefusesResend`, `expiresWhileAdmissionIsPending`, `expiredAbsoluteDeadlinePreventsAdmission`: typed original failure/history survive, no scheduled delay when refused, pending admission expires without approval, and only one actual request exists. |
| Bounded exponential backoff and persistent 504 | `persistent504IsBounded`, `exponentialCeilingsAndBoundedHistory`: exact histories 1/2/3 or 1/2/3/4, distinct IDs, stable logical ID, absent Retry-After, exact delays 1/2/3 with a ceiling of 3, failure after exhaustion, and exact server request counts. |
| Eligibility versus permission | `ambiguousFailureWithoutHookRequiresAdmission`, `pendingAdmissionRequiresExplicitDecision`, `timeoutRemainsPendingUntilExplicitAllowOrReject`: transient typed URLError and unknown acceptance remain inspectable; one request exists while pending; explicit allow sends an unchanged request; reject and missing hook send none later. A keepalive-only/truncated blank response records raw bytes without semantic progress. |
| Authoritative cancellation | `cancellationBeforeDispatchMakesZeroRequests`, `cancellationWinsAtEveryBoundary`: active body, pending admission, backoff and successful received body cancellation; actual failure is recorded before one terminal cancellation; no retry/success event afterward, zero delivered progress, retained received headers/bytes/semantic evidence, and zero wire requests before dispatch. |
| No recovery generation cutoff | `healthyActiveGenerationOutlivesRecoveryBudget`: the fixture holds an incomplete successful body, advances the injected clock beyond both budget/deadline, then completes successfully with one request. |
| Permanent truncated 400/401/403 | `permanentTruncatedStatusWins`: all three statuses across all four entrypoints retain numeric status, exact partial bytes, headers and typed URLError despite status selection and an allow-capable hook; no admission/resend, one failure in history, exact lifecycle and private evidence absent from default formatting. |
| Capture failure terminal at every boundary | `captureFailureIsTerminal`, `failedSecondRequestCaptureDoesNotInventAnotherAttempt`: request/header/body hook errors retain their typed sentinel cause; pre-dispatch failure has no actual identity/history/progress/request; a failed proposed second capture retains the first actual identity, raw progress and history without another attempt. |
| Successful capture failure retains semantic evidence | `successfulCaptureFailureRetainsObservedAndTypedCause`: content/reasoning byte counts, complete tool record counts, zero delivered progress, original typed capture cause, exactly one actual request and ordered failure/terminal transitions. |
| Malformed envelopes and structured JSON | `malformedResponseNeverResends`, `structuredJSONFailureRetainsReceivedSemanticEvidence`, `receivedSemanticProgressSurvivesMalformedTail`: typed DecodingError survives, malformed output is terminal; structured content parsing retains observed reasoning/content while delivering none through public `completeJSON`. A later malformed body chunk cannot erase previously observed reasoning or complete tools. The current `.foundry/proof.json` preserves rejection/correction at the retry-capture boundary; all semantic assertions are rerun in the full suites. |
| Redirects and legacy one-send default | `redirectsAreNotFollowed`, `disabledRecoveryRetainsLegacyOneSend`: real 307 remains a structured status error without following Location; legacy 503 is unchanged and sends once. |
| Credential/payload echoes | `bothOperationsPreserveShapingAndResults`, `permanentTruncatedStatusWins`, capture-failure tests: synthetic credential/payload sentinels in headers, IDs, warnings, body and typed causes remain available only through explicit inspection/capture; encoded safe events and default error formatting exclude them. |
| Tool side effects and history through broker/session | `completedToolSurvivesRecoveredFollowUp`: both providers through LLMBroker.complete and ChatSession.send execute the completed tool once, retain its original result/history and oMLX tool-call ID, resend equal follow-up bytes, distinguish logical requests and preserve one-based wire IDs 1/1/2. |
| Tool depth and typed failure propagation | `recoveryDoesNotResetToolDepth`, `failurePreservesTypedCauseAfterCompletedTool`: a recovered completion does not replenish tool depth; typed transport causes reach both public broker/session boundaries after one completed tool, without re-executing it on terminal refusal. |

## Safety and capability boundaries

Every retry of an ambiguous local request requires caller admission; no generic
HTTP status, socket closure, idle timeout, residency list, or model activity proves
termination. The adapters expose local task cancellation as supported, and remote
request cancellation, exact-attempt status and idempotency as unsupported. These
are adapter capability limits, not a claim about undocumented provider internals.
No model unload, process termination, invented idempotency header or tool replay
is performed. Current sources inspected for endpoint/capability claims:
[Ollama chat API](https://docs.ollama.com/api/chat) and
[oMLX project](https://github.com/jundot/omlx), October 10, 2026.

New sends use independent ephemeral URLSessions, disable credential/cookie
storage, refuse redirects and body-stream replay, and preserve configured idle
timeouts. Custom legacy URLSession transport/TLS/proxy configuration is not
inherited. This is an explicit migration limitation, not a verified custom-session
recovery capability. URLSession exposes normalized header values rather than raw
HTTP framing, duplicate-header order or TLS traffic. Exact capture means encoded
request body and received body chunks; the hook includes caller request headers
and normalized response headers. Capture is synchronous, sensitive, optional and
caller-owned. The library supplies no default capture persistence. Inspection
retains partial bytes, headers and original typed causes; syntactically validated
provider codes/IDs are excluded from safe formatting and events. Incomplete JSON
retains bytes rather than guessing semantic text. All buffered failures deliver
zero semantic progress.

The reviewed Rust revision is frozen under `.foundry/reference/`; its
`engine.rs` classifier rejects observed or delivered semantic output before
retry admission (lines 128–132 and 227–229). This correction closes Swift's
previous allowance for caller-admitted replay after observed reasoning, content
or tools. Zero buffered delivery does not restore eligibility. Rust also rejects
nonempty partial successful buffered bodies; Swift still distinguishes decoded
semantic evidence from undecodable bytes and whitespace keepalives. That broader
Rust safeguard is not claimed as Swift parity. Streaming/finish behavior is outside
this correction.

The original contract is `TRANSIENT-RECOVERY-2026-10.md`. The binding October 10
correction requirements came from this task's user instructions; a verbatim
standalone supplement was not present. Their applied acceptance requirements are
retained in `.foundry/october-10-input.md`. No sibling or harness files were edited.

### Corrected retry admission boundaries

`expiryDuringRetryCapturePreventsResend` is the proof-first public loopback probe.
The preserved implementation returned success after sending an expired proposed
retry at all four entrypoints (exit 1); the correction retains the original HTTP
failure and refuses another send (exit 0). The final probe also scripts expiry
during URLSession setup after the engine check; transport admission rechecks
limits immediately before resume. It checks exact request/response bytes,
unmasked correlation IDs, typed cause, history, progress and complete lifecycle.
`slowInitialFailureStartsBudgetAndAdmittedRequestMayOutliveLimits` holds the first
request, advances the clock past a full duration budget, then verifies recovery
starts its duration at that failure. The admitted response succeeds beyond both
limits. `expiryFromActualStartObserverDoesNotAbortAdmittedRequest` verifies limits
do not retroactively invalidate a launched task.

`cancellationWinsOverRefusal` covers exhaustion, ineligibility, missing admission,
zero budget, jitter/refusal and proposed request capture. Every case retains the
failed actual HTTP attempt before exactly one terminal cancellation. A proposed
capture identity is not an actual history entry. `cancellationFromActualStartObserverCancelsLaunchedRequest`
waits for the second exact HTTP payload at loopback before cancelling from the
start observer; this also exercises the launch/cancellation lock boundary without
inventing a send. `observedSemanticEvidenceRefusesReplay` separately proves
reasoning, content and tool evidence forbid replay despite zero delivery and an
allow-capable caller hook across all four public entrypoints. Existing retries-off,
broker and session completed-tool-once assertions remain in the full suites.

## Validation and review

Actual gate receipts are in `.foundry/gates.json`; complete stdout/stderr captures
are in `.foundry/captures/`, source revisions in `.foundry/source-revisions.json`,
and artifact/source SHA-256 hashes in `.foundry/hashes.json`. These artifacts are
regenerated for this correction: the preserved Git tree contained none of its
previously referenced `.foundry` receipts. The durable artifact root is
`/home/svetzal/.foundry/tool-logs/mojentic-sw-transient-recovery-v2-c2-9cf308/`;
its `hashes.json` authenticates retained sources, reference snapshots and evidence.
Only source/evidence within this worktree and its permitted tool-log root is written.

Independent review is recorded in `.foundry/review.md`. Its first review rejected
a gap between lifecycle observers and actual launch; the correction moves start
notifications after launch, serializes response callbacks behind them, and never
resumes a pre-cancelled task. Re-review found no blocking issue. No Git finalization
is performed; refs remain unchanged for Foundry.

Linux uses Swift 6.4 and SwiftLint 0.65.1. Original rules, thresholds, exclusions,
runtime pins, Package.swift and Package.resolved are unchanged. The unfiltered OSV
lockfile scan is captured in `.foundry/logs/security.log`. The unfiltered API audit
compares every library module against `v2.1.0` without a breakage allowlist. Final
suite results: parallel passes 289 tests in 68 suites; full traits passes 290 tests
in 69 suites. Strict Linux format, release build, DocC with warnings as errors and
lint with a writable cache pass. OSV scans all three resolved packages and finds
no issues. The first API invocation used relative module-cache flags; its compiler
working directory resolved them outside the writable worktree and failed. Its
complete failure is preserved in `.foundry/logs/api.log`; rerun uses absolute
module-cache paths only, with no library filtering or allowlist. That rerun passes:
“No breaking changes detected in Mojentic” (`.foundry/logs/api-absolute-cache.log`).

The exact `swiftlint --strict` invocation reports no source violations but cannot
write `/var/tmp/SwiftLint` in this sandbox. Its original failure is retained. A
rerun changes only `--cache-path` to `.build/swiftlint-cache`, retaining every rule
and source file. Controller execution of the exact default-cache command remains
pending. The generic `swiftformat --lint .` tool is not installed; this project's
mandatory formatter is `swift format lint --strict --recursive Sources Tests`,
which is run on Linux with the existing configuration.

Apple/Darwin socket, URLSession, strict concurrency and DocC validation remain
pending. The Swift 6.1 minimum compiler is unavailable and remains pending.
Streaming, other providers and whole-mission/six-port alignment are outside scope.
No release, dependency upgrade, live inference or benchmark restart occurred.
