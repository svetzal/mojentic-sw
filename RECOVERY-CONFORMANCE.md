# Buffered local-provider recovery conformance

Scope: opt-in buffered Ollama and oMLX ordinary/structured completion recovery.
Swift base: `0035c10e4816eee90e937ee0d474447fb5c18f76`. Reviewed Rust reference:
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
| Early public-boundary rejection and correction | `admitted503PreservesBytesAndIdentity`: 503 rejects the legacy path; corrected opt-in path returns decoded content/reasoning, equal exact body bytes, matching logical IDs, unequal UUID attempt IDs, wire numbers 1/2 and the entire ordered lifecycle. `.foundry/proof.json` records actual exits 1/0 and existing complete probe logs before expansion. |
| Successful request/result preservation | `bothOperationsPreserveShapingAndResults`, `successfulLegacyAndRecoveryResultsMatch`: real body bytes remain equal on retry, legacy/recovery decoded requests and entire results agree; model, stream, temperature, token cap, reasoning hint, tools, schema/format, usage, model evidence and warning metadata are checked. |
| Ordinary JSON controls retain legacy behavior | `ordinaryJSONFormatKeepsLegacySuccessfulResult`: both providers retain the legacy successful ordinary result even when JSON mode was requested and content is plain text. The initial oMLX rejection and corrected passing fixture captures are retained. |
| Retry-After seconds/date/invalid | `retryAfterUsesInjectedTiming`: numeric 2, an IMF-fixdate resolving to 2 seconds, invalid and negative values assert typed parsing and exact sleeper values. `pastDateDoesNotReplaceJitterDelay` asserts 0.5-second jitter when the date is past. |
| Ceiling/budget/deadline refusals | `retryAfterLimitRefusesResend`, `expiresWhileAdmissionIsPending`, `expiredAbsoluteDeadlinePreventsAdmission`: typed original failure/history survive, no scheduled delay when refused, pending admission expires without approval, and only one actual request exists. |
| Bounded exponential backoff and persistent 504 | `persistent504IsBounded`, `exponentialCeilingsAndBoundedHistory`: exact histories 1/2/3 or 1/2/3/4, distinct IDs, stable logical ID, absent Retry-After, exact delays 1/2/3 with a ceiling of 3, failure after exhaustion, and exact server request counts. |
| Eligibility versus permission | `ambiguousFailureWithoutHookRequiresAdmission`, `pendingAdmissionRequiresExplicitDecision`, `timeoutRemainsPendingUntilExplicitAllowOrReject`: transient typed URLError and unknown acceptance remain inspectable; one request exists while pending; explicit allow sends an unchanged request; reject and missing hook send none later. A keepalive-only/truncated blank response records raw bytes without semantic progress. |
| Authoritative cancellation | `cancellationBeforeDispatchMakesZeroRequests`, `cancellationWinsAtEveryBoundary`: active body, pending admission, backoff and successful received body cancellation; actual failure is recorded before one terminal cancellation; no retry/success event afterward, zero delivered progress, retained received headers/bytes/semantic evidence, and zero wire requests before dispatch. |
| No recovery generation cutoff | `healthyActiveGenerationOutlivesRecoveryBudget`: the fixture holds an incomplete successful body, advances the injected clock beyond both budget/deadline, then completes successfully with one request. |
| Permanent truncated 400/401/403 | `permanentTruncatedStatusWins`: all three statuses across all four entrypoints retain numeric status, exact partial bytes, headers and typed URLError despite status selection and an allow-capable hook; no admission/resend, one failure in history, exact lifecycle and private evidence absent from default formatting. |
| Capture failure terminal at every boundary | `captureFailureIsTerminal`, `failedSecondRequestCaptureDoesNotInventAnotherAttempt`: request/header/body hook errors retain their typed sentinel cause; pre-dispatch failure has no actual identity/history/progress/request; a failed proposed second capture leaves one actual attempt and stable logical identity. |
| Successful capture failure retains semantic evidence | `successfulCaptureFailureRetainsObservedAndTypedCause`: content/reasoning byte counts, complete tool record counts, zero delivered progress, original typed capture cause, exactly one actual request and ordered failure/terminal transitions. |
| Malformed envelopes and structured JSON | `malformedResponseNeverResends`, `structuredJSONFailureRetainsReceivedSemanticEvidence`, `receivedSemanticProgressSurvivesMalformedTail`: typed DecodingError survives, malformed output is terminal; structured content parsing retains observed reasoning/content while delivering none through public `completeJSON`. A later malformed body chunk cannot erase previously observed reasoning or complete tools. The separate `.foundry/semantic-proof.json` preserves its actual rejection/correction. |
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

The Rust revision was inspected directly; its recovery policy, engine, adapter,
frames and types are frozen under `.foundry/reference/`. Swift retains the same
separation of classification and admission, bounded attempts, privacy boundaries,
HTTP permanent-status precedence and pre-capture semantic accounting. Its
buffered slice allows caller-admitted transport recovery before delivery, including
keepalive-only bytes; the reviewed Rust classifier additionally fails closed on
nonempty partial successful buffered bodies/observed output. This is a documented
capability difference, not an alignment or six-port parity claim. Swift does not
inherit or change Rust streaming/finish handling. The task's binding October 10
requirements are recorded in source evidence; the locally available related
harness integration document is retained read-only, and no standalone supplement
file was present in this worktree.

## Validation and review

Actual final gate receipts are in `.foundry/gates.json`; complete capture logs and
SHA-256 hashes are in `.foundry/captures/` and `.foundry/hashes.json`. Linux uses
Swift 6.4 and SwiftLint 0.65.1. The original formatter/linter rules, thresholds,
exclusions, runtime pins, Package.swift and Package.resolved remain unchanged.
OSV scans the entire tracked lockfile without advisory filtering or suppressions.
API comparison targets the last release tag `v2.1.0` (commit
`618eb7b42ff2b74e6ff9bb6fd9f3c65373da2262`) without a breakage allowlist.
The final Linux parallel and full-traits suites each pass 284 tests in 67 suites;
release build, strict format, DocC with warnings as errors, OSV and API audit pass.
The API digester's first invocation attempted a read-only Clang cache; its rerun
passes with only explicit module-cache flags, without target/product filtering.
The result is “No breaking changes detected in Mojentic.”

The exact `swiftlint --strict` invocation reports zero source violations but exits
nonzero because its default `/var/tmp/SwiftLint` cache is outside the writable
sandbox. A recorded rerun changes only `--cache-path` to a writable temporary
location and passes with the same rules and scope. Swift compiler caches are also
redirected through environment variables, without changing gate commands or pins.
The exact lint invocation remains pending controller execution with a writable
cache. Original cache failures, compile failures and the timeout fixture failure
are preserved rather than suppressed or discarded.

Apple validation of Darwin socket/URLSession behavior, strict concurrency and
DocC remains explicitly pending controller validation. The Swift 6.1 minimum
compiler is not installed in this Linux environment and remains pending. Linux
uses FoundationNetworking; no new platform exclusions or gate exclusions were
added. Streaming, OpenAI, Anthropic, whole-mission recovery and cross-port review
coverage remain pending and outside this slice. Embeddings, realtime, model
management, dependencies, harness pins, campaigns and frozen benchmarks were not
changed. Foundry owns finalization; no commit, push, rebase, tag or release occurred.
