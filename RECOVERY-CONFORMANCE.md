# Local-provider completion recovery conformance

This slice extends the preserved buffered implementation with opt-in streaming
recovery through OllamaGateway and OMLXGateway `stream` and
`completeStreamEvents`, including existing LLMBroker and ChatSession consumers.
The audited input is Swift `b1822c1975cf6da9213e88e008a3399c07b7f1d8`; comparison
reference is Rust `4ca1ed279c02eab37827a1ed07c30e961155ecf3`.
No six-port parity, live-provider efficacy or completed release is claimed.
Foundry owns finalization; these changes remain uncommitted in its task worktree.

The contract is `TRANSIENT-RECOVERY-2026-10.md`, with the original request in
`RECOVERY-REQUEST-2026-10.txt`. A standalone October 10 supplement was absent;
the binding task requirements are retained in `.foundry/october-10-input.md` and
compared with the pinned Rust conformance report. Source/reference hashes,
full capture logs, failures and review artifacts are retained under `.foundry/`.
The original buffered conformance report is retained as historical source evidence.

## Sequencing and scope

Initial dirty-state inspection was clean. The earlier missed fetch/pull-before-coding
requirement remains a recorded sequencing deficiency; this run does not claim to
have repaired history. Foundry explicitly forbids ref mutation, overriding fetch,
pull/rebase, main integration and release guidance. No fetch, pull, rebase, branch
switch, commit, push or release was performed. Read-only remote inspection later
confirmed origin main had the same SHA as the input. See `.foundry/sequencing.md`.

Buffered ordinary and structured paths retain their request/decode/project loop.
Only internal helper visibility, optional streaming transport integration and a
stream-specific phase were added. Legacy streaming parsers retain their original
behavior, including ignored malformed legacy Ollama frames and existing finish
mapping. Shared wire types were extracted without changing their mapping. Existing
retry-disabled tests remain in the full suites; the initial HTTP rejection probe
also demonstrates the prior streaming path bypassed configured recovery.

## Recovery boundaries

A request is encoded once. Each actual HTTP send has a distinct attempt ID and
one-based wire number under a stable logical ID. Proposed capture identities,
admission waits and backoff are not actual sends. No idempotency header is invented.
Retries reuse the buffered engine's policy validation, classification, timing,
Retry-After parsing, limits and explicit caller admission. Healthy admitted requests
have no new total generation cutoff. Existing idle timeouts remain in effect.

Observed UTF-8 reasoning/content, tool fragments and completed tool records are
tracked separately from delivery. Any observed semantic evidence prevents retry,
including evidence preceding a failing capture callback. Single-turn reasoning is
observed but never falsely counted as delivered through a content-only interface.
Permanent numeric 400/401/403 statuses remain ineligible even with truncated bodies
and caller-selected transport/status eligibility. Socket closure or keepalive-only
bytes never establish remote termination. Malformed frames cannot grant retry.

Ollama streaming success requires a validated `done: true`, `done_reason: "stop"`
frame. oMLX requires a valid finish reason and `[DONE]`; tool streams also accept
`tool_calls`. Failed final validation preserves its original typed MojenticError
behind recovery inspection. Tool requests are delivered only after completion proof.
A valid Ollama length frame retains observed semantic evidence and reported usage
and numeric durations, emits Progress then Metrics when present, then fails. Its
semantic fields and completed tools are withheld; no retry occurs. Malformed fields
produce no fabricated telemetry. Numeric counters are nonnegative and Ollama sums
are checked for overflow before existing helpers are called.

Ollama adds validated progress and provider-reported numeric metrics. Swift's already
exposed completion model/timestamp/metadata fields remain explicitly inspectable;
safe formatting and numeric metrics exclude echoed strings. No equivalent Ollama
telemetry is invented for oMLX. No native reasoning-history field is added.

The gateway relay uses a rendezvous, so terminal metadata cannot establish success
or release tools while gateway consumption is paused. Cancellation records the
failed actual attempt before exactly one terminal cancellation and closes locally
owned resources. An already cancelled Swift stream iterator may return nil rather
than delivering an error; lifecycle/report observers retain cleanup. Dropping an
iterator releases its producer. Neither local cancellation nor closure proves
remote termination. Higher-level broker/session stream buffering retains its existing
semantics; this slice does not introduce a whole-session recovery loop.

## Public consumers, privacy and migration

Gateway tool streams throw RecoveryError directly. CompletionStreamEvent.error
retains the typed MojenticError boundary through `.recovery(RecoveryError)`.
LLMBroker.generateStreamEvents forwards nonterminal telemetry and retains typed
terminal failures. Broker tool recursion ignores telemetry for interaction/depth
accounting. ChatSession keeps its existing success/history and failed-turn rollback.
A completed tool followed by a failed or recovered follow-up completion executes
once; recovery neither replays the broker loop nor resets depth.

Safe lifecycle events are Codable and contain identities, numeric status, phase,
classification, counts and delays without headers, payloads, tool arguments or
cause text. Default error/report/evidence formatting excludes echoed metadata.
Recovery errors intentionally do not automatically serialize sensitive evidence.
Original typed causes, normalized headers and partial bytes require explicit
`inspectEvidence()`. `wireObserver` captures exact encoded request bodies and
received body chunks; this is not HTTP framing, duplicate-header order or TLS
capture. Storage belongs to the caller. Throwing capture is terminal without resend.

See `Sources/Mojentic/Mojentic.docc/StreamingCompletionRecovery.md` for tool/session
and single-turn migration examples. Exhaustive client switches must handle the new
Progress/Metrics and recovery error cases. The unfiltered API audit reports these
five additions as source-breaking enum changes; no allowlist suppresses that result.

| Completion adapter | Buffered recovery | Streaming recovery | Local HTTP cancellation | Remote cancellation / exact status / idempotency |
| --- | --- | --- | --- | --- |
| Ollama | Opt-in ordinary/structured | Opt-in both public paths | Supported | Unsupported |
| oMLX | Opt-in ordinary/structured | Opt-in both public paths | Supported | Unsupported |
| OpenAI | Legacy one request | Legacy paths | Existing transport behavior | Recovery not implemented in this slice |
| Anthropic | Legacy one request | Legacy paths | Existing transport behavior | Recovery not implemented in this slice |

Realtime voice and embeddings remain outside completion recovery. Swift retains
whole-text embeddings. No dependencies, release metadata or harness files changed.

## Assertion-bearing HTTP evidence

The early proof in `.foundry/proof.json` records real public HTTP 503 rejection
against the preserved implementation (exit 1) and corrected recovery (exit 0),
before broad fixture/documentation expansion or the full suite. Both adapters assert
immutable request bytes, unmasked IDs, numeric status, lifecycle order, exact UTF-8
delivery and actual wire counts. The strengthened final probe additionally checks
private original causes, response bytes and per-attempt wire capture.

| Acceptance | Public assertion-bearing coverage |
| --- | --- |
| 503 recovery | StreamingRecoveryProofTests; two actual requests, identity/bytes/history/capture |
| Retry-After | StreamingRecoveryTimingTests; seconds, date, invalid, ceiling/budget refusal |
| Bounded 504 and permanent truncated HTTP | StreamingRecoveryTests; all four entrypoints, typed causes, private partial bodies |
| Pending/allowed/rejected ambiguous admission | StreamingRecoveryTimingTests; keepalive-only transport failure, no resend while pending |
| Keepalive without termination | StreamingRecoveryProtocolTests; socket completion remains a typed protocol failure |
| Reasoning/content/tool interruption | StreamingRecoveryTests; independent observed/delivered UTF-8 counts, no retry or completed tool |
| Capture after observation | StreamingRecoveryTests; observed semantic values, zero delivery, original capture cause |
| Active/admission/backoff cancellation | StreamingRecoveryCancellationTests; one failed actual attempt, one cancellation, no later wire |
| Terminal-only paused consumer | StreamingRecoveryCancellationTests; producer cleanup synchronization, no success or tool delivery |
| Valid rejected length telemetry | StreamingRecoveryTests; Progress/Metrics before original finish failure, observed-only semantic fields |
| Malformed text/tools/done/reason and counts | StreamingRecoveryProtocolTests; no fabricated telemetry or retry |
| Privacy and retry-disabled compatibility | StreamingRecoveryProtocolTests/StreamingRecoveryTests plus existing legacy suites |
| Broker/session completed tool once | StreamingRecoveryConsumerTests; successful recovery and rejected follow-up, exact tool history |
| Tool depth and typed broker terminal | StreamingRecoveryConsumerTests; recovery preserves depth and causes |

All fixtures use scripted loopback HTTP and synthetic values. Timing hooks and
cancellation synchronization are deterministic; no sleeps substitute for admission
or cleanup evidence. The independent reviewer ran the public streaming matrix
separately. Its logs and findings are retained in `.foundry/review.md` and capture logs.
The reviewer-found malformed counter overflow has an additional actual failing and
corrected public probe in `.foundry/invalid-metrics-proof.json`.

## Validation limits

Actual commands/exit codes are in `.foundry/gates.json`; full stdout/stderr are retained
beside receipts under `.foundry/logs/`. Linux Swift 6.4 is the exercised toolchain.
Apple and minimum Swift 6.1 checks are explicitly pending because neither is available
in this isolated environment. The OSV audit is unfiltered, with no suppression or
dependency changes. The unfiltered API audit retains its five expected enum additions
as a nonzero result, with no lowered threshold or breakage allowlist.

Upstream SwiftFormat 0.63.1 was provisioned separately and the actual
`swiftformat --lint .` command ran. Its default rules conflict with the established
native style across existing source files, and its result remains nonzero. Native
`swift format` is not substituted for this missing passing result. No lenient mode,
source exclusions or rule-disabling project configuration was applied. A concrete
draft and the pending user policy choice are documented in
`.foundry/formatter-conflicts.md`. This mandatory formatter requirement is unresolved;
this report does not claim every requested gate passed or the whole plan is complete.
