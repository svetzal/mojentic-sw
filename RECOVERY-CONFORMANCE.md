# Swift transient recovery conformance

The historical OpenAI recovery slice started at verified clean HEAD
`11e2503130a77924527d81ea0331929bf716d15b`. Controller synchronization is
recorded in `/home/svetzal/.foundry/operations/mojentic-port-alignment-20261010/status-recovery/receipt.json`
(observed October 10, 2026 at 23:39:13 UTC), including clean status, fetch,
pull with rebase, revisions and log hashes. Its Swift revision is historical synchronization evidence, not the current worker HEAD.
Workers perform no ref mutation; changes remain uncommitted for controller integration.
The normative documents and binding October 10 supplement in that receipt were
reviewed against Rust `4ca1ed279c02eab37827a1ed07c30e961155ecf3`.

## Release-baseline reconciliation and migration

The prior reconciliation reported seven release-baseline diagnostics: generic
signature changes in `Router.subscribe` and `JSONSchemaGenerator.schema`,
`MojenticError.recovery`, and progress/metrics additions to the legacy streaming
enums. Its historical receipts are absent from this delivered trunk. This slice
preserves the reconciled named generic signatures and exhaustive legacy enum
vocabulary. The current API audit uses `v2.1.0` without exclusions, allowlists or
substituted baselines.

Mandatory standalone formatting also reconciles pre-existing whitespace in recovery
and broker wrappers. Explicitly typed local metatype aliases preserve the two named
generic APIs against formatter conversion to opaque parameters. No formatter rule,
lint threshold, security scope or dependency is changed.

Policy semantics in `TRANSIENT-RECOVERY-2026-10.md` license a separate opt-in API
where a legacy error vocabulary cannot safely grow. Recovery telemetry now uses
`RecoveryGatewayStreamEvent` and `RecoveryCompletionStreamEvent`. The latter
exposes `.recoveryFailure(RecoveryError)` directly, retaining typed final causes
and bounded history. `MojenticError` has no recovery case. CompletionEvidence's
landed safe description/debug-description conformances remain intact; provider
values remain available through explicit properties.

| Caller | Recovery entrypoint | Legacy entrypoint |
| --- | --- | --- |
| Ollama / oMLX / OpenAI / Anthropic tool stream | `streamRecovering` | `stream` |
| Ollama / oMLX / OpenAI / Anthropic single turn | `completeStreamEventsRecovering` | `completeStreamEvents` |
| Broker single turn | `generateRecoveryStreamEvents` | `generateStreamEvents` |
| Broker tool stream / ChatSession | Existing API internally routes to the opt-in gateway boundary | Existing public result vocabulary |

Legacy streaming entrypoints retain their original single-request parsers and
completion rules, even when an instance has a recovery policy. They do not convert
recovery errors into legacy errors. Buffered recovery still throws RecoveryError
directly. Gateways without recovery support are lifted without fabricated telemetry
or retries. OpenAI Chat Completions and Anthropic Messages support opt-in
per-request recovery; Anthropic evidence and limits are recorded in cycle 9 below.

Structural callers were inspected before migration: Router feeds dispatcher
subscriptions; schema generation feeds broker structured completion; stream events
cross gateway implementations/parsers, StreamingRecovery, broker relays, ChatSession,
tests and DocC. `ReleaseBaselineCompatibilityTests` imports the public module and
compiles exhaustive switches over all three legacy enums with no default arms.
It exercises generic schema generation and generic Router subscription, checking
concrete-type routing. Its six public HTTP combinations call legacy gateway,
completion and broker entrypoints on recovery-configured Ollama/oMLX instances:
the original 503/body survives, exactly one wire request occurs, and no recovery
observer event is produced. Existing dispatcher and structured broker suites remain
in the unfiltered test runs.

## Preserved recovery and cancellation contract

Create and consume recovery streams within
`withRecoveryStreamCancellation(operation:)`. The task-local scope owns producer
tasks across unrelated consumer awaits, cancels unfinished producers on exit, and
propagates through broker/session tasks. Registrations race safely with cancellation
and completion. Scoped relays use rendezvous delivery so buffered terminal metadata
cannot establish success ahead of downstream consumption. Detached tasks require
their own scope. Local cleanup never proves remote termination.

Immutable requests are encoded once per logical operation. Retries preserve exact
request bytes and completed tool results; they do not reset tool depth or execute
a completed tool again. Admission safety, observed/delivered semantic accounting,
cancellation precedence, lifecycle order, typed causes and history are unchanged.
Ollama progress/metrics retain reported values and their order before completed
tool delivery. oMLX's decoder still does not fabricate equivalent telemetry.
Single-turn reasoning remains observed-only. Realtime and embeddings are outside
recovery; Swift retains whole-text embeddings.

`StreamingRecoveryProofTests` passed through real public Ollama/oMLX loopback
HTTP, asserting exact payload/capture bytes, unmasked logical/attempt identities,
typed HTTP causes and history, UTF-8 progress, lifecycle order and actual wire counts.
The migrated recovery matrices continue to exercise both explicit gateway APIs,
broker recovery completion, broker tool streams and applicable session paths.
`StreamingRecoveryTests`, `StreamingRecoveryProtocolTests`, and
`RecoveryToolSafetyTests` preserve terminal telemetry and completed-tool-once checks.

`SenderRegistrationCancellationTests` retains cancelled consumers, streams and
held fixture responses across gateway, broker throwing/completion and session
throwing relays. Completion has no session API. Before resuming or draining, it
requires delivery finish callbacks, cleanup reports and peer FIN. Assertions cover
exact request/capture bytes, original headers/body, typed URLError.cancelled,
failed history, observed/delivered counters, wire count, and exactly
attemptStarted/attemptFailed/cancelled. Paused ownership/delivery and scoped relay
suites preserve cleanup and session rollback checks. Fixtures are scripted local
HTTP; no live inference or benchmark restart is performed.

## Provider capabilities

| Completion adapter | Recovery | Reasoning delivery | Recovery telemetry | Remote status / cancellation / idempotency |
| --- | --- | --- | --- | --- |
| Ollama | Buffered, tools, single turn | Tool stream thinking; single turn observed-only | Validated progress and reported metrics | Unsupported; local HTTP cancellation only |
| oMLX | Buffered, tools, single turn | Buffered/tool thinking; single turn observed-only | Existing evidence; no invented Ollama events | Unsupported; local HTTP cancellation only |
| OpenAI Chat Completions | Buffered, tools, single turn | Observed-only; registry-supported effort request unchanged | Validated provider usage metrics and completion evidence | Unsupported; local HTTP cancellation only |
| Anthropic Messages | Buffered ordinary/JSON/structured, tools, recovery single turn | Buffered/tool thinking; single turn observed-only; signed history unsupported | Actual message usage/model/ID and finish evidence | Unsupported; local HTTP cancellation only |

## Current OpenAI acceptance evidence

The restored `.foundry/preserved-c7/proof.json` records the original public buffered
HTTP rejection and correction:
a received response contains UTF-8 content, reasoning and a tool call, then the
capture hook throws. The corrected boundary retains exact body bytes, typed capture
cause, observed byte/fragment counts, zero delivered progress, one failed attempt
and one wire request. The rejecting boundary ignored the opt-in policy. Both full
captures and actual exits are retained; the intermediate reasoning-accounting
failure is retained separately. A second rejecting/corrected public probe in
`.foundry/preserved-c7/combined-proof.json` verifies single-turn content + reasoning + tool
fragments survive unsupported-tool rejection, with or without a failing capture
hook, while delivery stays zero and one wire request is made.

The retained cycle-7 expanded acceptance run passed 67 tests in 25 suites. These assertions include
OpenAI as well as the existing Ollama/oMLX cases:

| Public boundary | Actual acceptance assertions |
| --- | --- |
| Ordinary / structured buffered gateway | Admitted 503-success preserves received request bytes, logical ID, distinct attempt IDs, usage, model-dependent parameters, typed HTTP history and lifecycle order; numeric/date Retry-After use injected timing; bounded 504 has actual wire counts |
| completeJSON / completeStructured | Model registry schema selection is preserved; malformed structured content retains original decoding cause and received semantics with zero delivery |
| Buffered and streaming failures | Selected 400/401/403 plus truncated bodies remain permanent despite transport eligibility; partial headers/body and original URLError are privately inspectable; malformed data never resends |
| Admission / backoff / active HTTP | Pending and rejected hooks cannot authorize sends; cancellation wins at requests, admission, sleeping, limits and capture; healthy active generation outlives recovery budgets |
| Tool and single-turn recovery streams | Content, reasoning and tool fragments block replay after partial output; reasoning remains observed-only for OpenAI; keepalive-only failures need explicit admission; received capture-hook evidence survives zero delivery |
| Terminal OpenAI usage | Validated usage-only metrics precede stop success or original length-finish failure; malformed multiple choices and negative counts produce no telemetry; identifiers and metadata echoes stay out of metric values and safe lifecycle serialization |
| Gateway / broker / applicable session cancellation | Terminal usage is buffered while consumers and streams are held; cleanup, failed history, exact captures and cancellation order are asserted before resume/drain; sender-registration tests require peer FIN with held replies |
| Broker / session tools | A completed tool followed by recovered or rejected completion runs exactly once; follow-up retries preserve exact tool-result bytes and tool depth |
| Disabled recovery and legacy APIs | One-send HTTP errors, legacy enum cases, malformed/missing-DONE legacy handling, OpenAI reasoning omission and successful results are preserved; gpt-4o/o3 request fields match disabled calls |

OpenAI has its own `openai` identity and SSE selection. Shared message/response types
and `responseFormatPayload` retain their existing oMLX and legacy behavior. Its
recovery decoder emits only provider-reported usage metrics, without inventing local
frame telemetry, durations, remote termination, status querying or idempotency.

## Durable evidence and validation limits

The starting trunk lacks the referenced historical `.foundry` artifacts from earlier
runs. Historical source-compatibility rejection/passing evidence is not reconstructed
or claimed as current. This run retains fresh evidence:

- `.foundry/logs/` records capture summaries and actual exit files, including failures.
- `.foundry/capture-manifest.json` links full durable stdout/stderr captures and hashes
  under `/home/svetzal/.foundry/tool-logs`.
- `.foundry/gates.json` records current commands, actual exits and full-capture hashes.
- `.foundry/source-revisions.json` records the verified source and release/Rust revisions,
  controller receipt and hash, toolchain versions and pending platform validation.
- `.foundry/independent-review.md` records independent source and assertion review.

The API audit uses SwiftPM's native build system with XDG_CACHE_HOME inside this
worktree, without changing the baseline or audit scope. The prior report described
a read-only global clang-cache failure, but its historical captures are unavailable.
Current command exits, environment warnings and complete captures are recorded.
No source warning suppression, formatter/linter threshold change, advisory exclusion
or dependency change is used.

The project gates are strict Swift format, strict SwiftLint, release builds,
unfiltered parallel/default and full-trait tests, and DocC with warnings as errors.
The unfiltered OSV scan uses tracked Package.resolved. The retained nine gates passed after the combined-frame correction. Default parallel
Swift Testing ran 321 tests in 81 suites; full traits ran 322 tests in 82 suites.
Standalone SwiftFormat 0.63.1, native format, strict SwiftLint, release build,
DocC, unfiltered tracked-lockfile OSV and the native `v2.1.0` API audit all exited
zero. OSV found no issues; the API audit found no breaking changes. Complete
commands, hashes and exits are restored in `.foundry/preserved-c7/gates.json`; earlier failures
remain in separate logs. The expanded loopback matrix required raising the process
open-file soft limit from 1,024 to 8,192, preserving suite concurrency and scope.
The first descriptor-exhaustion failure is retained, not treated as a passing run.

The retained cycle-7 independent review found no blocking findings and verified capture hashes,
public entrypoints, shared-provider preservation, private evidence, observed-only
reasoning and completed-tool accounting. The review and final source snapshot are
retained in `.foundry/preserved-c7/independent-review.md` and the durable source archive,
with a durable copy under `/home/svetzal/.foundry/tool-logs/mojentic-sw-openai-recovery-c7-0179ac`.
The current `.foundry/durable-evidence.json` identifies the reconciliation evidence copy.

## Foreground gate reconciliation (cycle 8)

The preserved branch resolves to `1ab4471e372ccdb25f87eb1249fcec764f044171`,
not the non-resolving `1ab4471ed` abbreviation in the correction plan. All 184
runtime/test/package members of the retained reviewed source archive matched this
starting worktree. The runtime implementation and dependency lockfile remain intact;
the only Swift edits add exact ordered equality between observer-captured request
payloads and actual loopback socket-received payloads in buffered, streaming and
broker/session completed-tool acceptance tests.

Controller cycle-7 verification is distinct from the retained worker passes. The
controller trace `3973d907dd293c62b6efa601c55260f4` records format/lint/build
success and three 300-second timeouts (default tests, full traits, DocC), each
with exit `-1`. `.foundry/controller-cycle7.json` preserves these results and the
trace hash. Those timeout records contain no child output or process inventory;
there is no basis for claiming a separate DocC defect or that every timeout had
the same cause. Historical pre-cycle-7 evidence remains missing.

The retained worker runner used a descriptor limit of 8,192 and worktree-local
`XDG_CACHE_HOME`; foreground shells started at 1,024 and read-only global caches.
The real HTTP matrix in `.foundry/proof.json` rejects the original foreground
settings with socket allocation failures (`descriptor == -1`) and a test-runner
signal-4 crash, then passes all 65 tests in 24 suites with the corrected setup.
`.foundry/descriptor-isolation.json` separately raises only the descriptor soft
limit, keeps the original cache settings and passes the same matrix despite the
cache warnings. This demonstrates the descriptor-capacity cause for that rejection;
cache relocation separately removes manifest-cache database warnings.

`scripts/with-gate-environment` makes those previously hidden prerequisites explicit
in every existing `.hone-gates.json` command: raise only the soft descriptor limit
to at least 8,192, preserve higher host limits and the hard limit, use
`.build/audit-cache`, and `exec` the unchanged gate command. Insufficient host
capacity fails the gate. No assertion, suite concurrency, timeout, provider trait,
formatting rule, advisory scope or API baseline is reduced. Invoke any standalone
gate or audit through that wrapper as well. The wrapper executes foreground and
preserves signals and exits rather than introducing a detached worker.

Foreground default tests passed 321 tests in 81 suites in 8.50 seconds including
SwiftPM setup; full traits passed 322 tests in 82 suites in 25.69 seconds; the exact
warnings-as-errors DocC command passed in 12.71 seconds. These initial foreground
runs are in `.foundry/foreground-*.json`. The final complete gate results after the
three additional payload assertions are recorded separately in `.foundry/gates.json`.
Current cache/configuration accessibility warnings are retained in full captures;
they are environment diagnostics, with no source warning suppression. Process
inventories are retained with the environment and final cleanup evidence; the
historical timed-out processes cannot be inspected after worktree cleanup.

Complete failure and success stdout/stderr, actual exits, command durations,
per-run source hashes, source revision and toolchain/cache/limit details are copied
to `/home/svetzal/.foundry/tool-logs/mojentic-sw-reconcile-c8` before disposal.
`.foundry/historical-validation.json` verifies all 90 retained capture hashes.
The binding controller synchronization receipt and its verified log hashes are
restored locally; this worker performs no fetch, rebase, commit or other ref mutation.
Independent correction review checks the gate wrapper and the public payload,
identity, typed-cause, progress, lifecycle and completed-tool assertions; its findings
are retained in `.foundry/independent-review.md`. Controller review and integration
onto main remain Foundry’s responsibility.

Validation here is Linux Swift 6.4. Apple URLSession/Darwin sockets, strict
concurrency and DocC checks remain pending. The declared Swift 6.1 minimum remains
pending. Standalone SwiftFormat 0.63.1 is installed by the controller and its unfiltered
`swiftformat --lint .` check is required alongside strict `swift format`. Current
results are retained separately; historical formatting evidence remains missing.

At the end of cycle 8, whole-mission gaps included Anthropic recovery, oMLX telemetry parity, remote
termination/status/idempotency and Apple/minimum-toolchain validation. This task
makes no whole-port parity claim. Foundry owns final review and finalization; no
release, tag, PR, push, sibling write or ref mutation is performed.


## Anthropic Messages acceptance (cycle 9)

This additive slice starts at clean delivered trunk
`3835622f2fded38d9c98290ab5a77f7f129e0cb0`. HEAD was verified read-only.
The controller synchronization receipt named above and every Swift check log hash
were verified read-only; that historical receipt records `11e2503130a77924527d81ea0331929bf716d15b`,
not this later delivered HEAD. Its binding October 10 supplement was reviewed
against exact Rust `4ca1ed279c02eab37827a1ed07c30e961155ecf3` (recovery engine,
adapter, public tests and migration/conformance notes). Rust's missing Anthropic
coverage is not copied. Prior missing-evidence disclosures remain historical.

Characterization found the trait-gated Anthropic gateway used `HTTPClient.postJSON`
for buffered calls, delegated `completeJSON` to `completeStructured`, and used a
legacy SSE accumulator for `stream`. Broker buffered paths already called the
gateway; broker tool streams already dispatched through `streamRecovering`.
Those caller paths and legacy parsers remain intact. A new policy initializer,
`RecoveryStreamingGateway` conformance and Messages decoder connect Anthropic to
the existing isolated request engines. Package traits, dependencies, tools,
reasoning configuration, enum vocabulary and ordinary legacy finish handling are
unchanged. No feature flag, marker or private retry test substitutes for HTTP proof.

The initial `AnthropicRecoveryProofTests.captureFailureRetainsReceivedSemanticsWithoutResend`
run rejected the disconnected policy path: public `complete` returned success
instead of invoking capture. After connecting buffered recovery and Anthropic
semantic observation, the same loopback probe passed. It checks exact body Data,
2 content UTF-8 bytes, 3 thinking bytes, one fragment/completed tool, zero delivered
semantics, the typed capture cause, one real request and the exact failed lifecycle.
Actual nonzero/zero exits and complete logs are retained in the execution evidence.

| Acceptance | Public entrypoints and assertion evidence |
| --- | --- |
| 503 then success, immutable payload and identity | `RecoveryConformanceTests.bothOperationsPreserveShapingAndResults` (ordinary/structured), `AnthropicRecoveryTests.completeJSONRetriesFrozenSchemaAndSupportedThinking` (JSON): ordered captured Data equals socket bodies, same payload across attempts, distinct unmasked attempt IDs, one logical ID, exact usage/history/lifecycle, schema/system/thinking/sampling fields and actual authentication/version headers |
| Retry-After and bounded history | `RecoveryTimingTests`, `StreamingRecoveryTimingTests`, conformance `persistent504IsBounded`: numeric/date/invalid/past values, injected delays, ceiling/budget refusal, pending allow/reject, exact captured/socket requests, bounded attempts and typed status causes |
| Permanent truncated status | `RecoveryConformanceTests.permanentTruncatedStatusWins`, `StreamingRecoveryTests.numericFailuresAndPrivateEvidence`: selected 400/401/403 stay HTTP/ineligible despite configured status/transport eligibility; original URLError, numeric status, headers and private partial bytes survive |
| Ambiguous admission and cancellation | `RecoveryTimingTests`, `RecoveryCancellationTests`, `RecoveryAdmissionSafetyTests`, `StreamingRecoveryCancellationTests`: request, pending admission, backoff, terminal cancellation and refusal precedence; one failed actual attempt before one cancellation, no later send or success; healthy generation outlives recovery budget |
| Observe before failing capture | `AnthropicRecoveryProofTests`, `AnthropicRecoveryCaptureTests.captureAndCancellationRetainExactObservedEvidence`: ordinary/structured/tool/single APIs, exact UTF-8 counters, completed tools, typed capture causes, byte-for-byte private body, zero delivery, exact lifecycle/IDs, no resend; cancellation wins even when capture throws |
| Semantic interruption and keepalives | `StreamingRecoveryTests.semanticInterruptionNeverRetries`, `AnthropicRecoveryCaptureTests.partialToolArgumentsInterruptWithoutDelivery`, `StreamingRecoveryTimingTests.keepaliveAdmissionRemainsPending`: thinking/text/tool channels block replay; incomplete JSON arguments count as observed fragments, not completed/delivered tools; raw keepalive evidence requires explicit admission |
| Malformed/provider and terminal finish failures | `AnthropicRecoveryTests.malformedAndProviderErrorsAreTerminal`, `.terminalUsageAndToolsRespectFinish`: typed failures, exact original bytes, no malformed metrics, provider usage/evidence order, no tools from rejected `max_tokens`, no success, exact input/output totals without invented durations |
| Paused ownership cleanup | `PausedRecoveryOwnershipTests.pausedConsumerClosesActiveHTTPBeforeResuming`: gateway tool/single, broker tool/single, session tool; keepalive and terminal response; retained stream/consumer, local socket closure before resume, exact cleanup history, observed counters, zero completed-tool delivery and cancellation event order |
| Completed tools execute once | `RecoveryToolSafetyTests`, `StreamingRecoveryConsumerTests.completedToolRunsOnceAcrossFollowUp`: public broker/session buffered/streaming follow-ups succeed or fail without tool replay; native `tool_use`/`tool_result` IDs and tool result survive; retries reuse follow-up bytes exactly; tool depth stays bounded |
| Defaults and privacy | `.legacyLengthFinishAndUnsupportedSingleTurnStayUnchanged`, shared conformance, Anthropic capture/terminal tests: disabled policy retains legacy length handling and one send; legacy single turn remains unsupported without HTTP; credential/payload echoes stay out of descriptions, reflection and lifecycle JSON; explicit inspection/capture retains original sensitive values |

Anthropic acceptance variants run only under `anthropic`/`full`; the default suite
continues testing the existing providers without altering trait defaults. Both
migration guides contain Anthropic examples and the same policy/admission semantics.

### Supported limits and validation

Messages recovery supports buffered ordinary, schema-instructed JSON/structured,
named SSE tool streams and recovery single-turn streams. It retains text/thinking,
validated tools, message model/ID, input/output usage and raw finish reasons.
Only `end_turn` and `tool_use` are accepted recovery finishes; other finishes fail
with provider evidence. Legacy finish handling is preserved. Streaming requires
one JSON object per SSE data line, valid block ordering and a message-stop marker.
There is no replay/continuation mode, total generation deadline, remote status,
termination proof, remote cancellation or claimed inference idempotency. Native
signed and redacted thinking history cannot round-trip through the existing
universal message adapter; cache-token breakdowns have no typed Usage fields.
These limits are not implemented as unrelated reasoning features.

Current Linux Swift 6.4 gate and audit results, complete logs, per-run source hashes,
starting revision and proof are retained outside the disposable worktree under
`/home/svetzal/.foundry/tool-logs/mojentic-sw-anthropic-c9`. Apple/Darwin and Swift
6.1 validation remain explicitly pending until executed. Independent controller
review and direct-main integration remain pending; this slice makes no whole-port
alignment, coordinated parity or remote termination claim. Foundry owns Git
finalization; no worker ref mutations, release, live inference or harness writes occur.

The fresh unfiltered full-trait run passed **330 tests in 85 suites** after a
clean rebuild. An earlier broader focused run failed with private fixture bytes
containing Swift source fragments while formatting overlapped an incremental
build. That run remains a failure in retained evidence. With edits stopped, a
focused recheck passed 20 tests in 5 suites, followed by the clean unfiltered pass.
This confirms the final frozen source passes; stale source-offset artifacts remain
the diagnosis for the earlier run rather than an inferred provider failure.

Final Linux Swift 6.4 validation passed all six required wrapper gates: strict
native formatting, strict SwiftLint, release build, default parallel tests
(321 tests in 81 suites), full-trait tests (330 tests in 85 suites) and DocC with
warnings as errors. Standalone SwiftFormat, the additional full-trait release
build and DocC build, the unfiltered OSV scan of `Package.resolved` (no issues),
and the native full-trait API audit against `v2.1.0` also passed. Final runs record
unchanged source hashes across each execution; no baseline or audit exclusions
were introduced. These Linux results do not substitute for pending Apple and
Swift 6.1 checks.

Independent review found no blocking Anthropic-specific defect and verified the
actual rejecting/passing HTTP proof, payload/identity assertions, private causes,
tool boundaries and cancellation cleanup. Its source hashes and report remain in
the durable evidence directory. It also records an inherited observer edge: a
caller cancelling from inside the already-delivered `attemptSucceeded` callback
can subsequently receive cancellation. The tested guarantee here is cancellation
before terminal capture/reporting, including paused consumers; no shared landed
engine behavior was changed to erase an event already delivered to an observer.


## Anthropic stop-sequence correction (cycle 10)

The clean worker HEAD was verified read-only as
`63211f58ba4992b4a4423a545d6e782f1cd9caf7`, the preserved cycle-9 slice from
`foundry-task/mojentic-sw-mojentic-sw-transient-recovery-v2-c9-a341c5`.
The controller receipt named above records the earlier canonical Swift
`11e2503130a77924527d81ea0331929bf716d15b` fetch/pull, not synchronization of
this corrected worktree or integration of this slice. No worker fetch, rebase,
commit, push, release or ref mutation occurred. Controller integration remains pending.

The cycle-9 claim of no blocking Anthropic defect was incomplete: recovery
rejected successful `stop_sequence` finishes in both buffered and SSE decoding.
The recovery tool-stream mapper would also classify the newly accepted reason
as `toolCalls`. Cycle-9 passing gates and review remain historical evidence;
they did not characterize this terminal reason. Their earlier failing captures,
missing-evidence disclosures and inherited cancellation-observer limitation are
preserved above and are not converted into success claims.

`AnthropicStopSequenceTests.successfulStopSequencePreservesEvidence` first failed
through real scripted loopback HTTP at all five public entrypoints: `complete`,
`completeJSON`, `completeStructured`, `streamRecovering` and
`completeStreamEventsRecovering`. The command
`./scripts/with-gate-environment swift test --traits full --filter AnthropicStopSequenceTests`
exited 1 before the fix and 0 after the three recovery-only changes. The rejected
responses carried exact UTF-8 JSON text `{"answer":"é思"}` and a successful
provider `stop_sequence` reason; they were incorrectly reported as protocol failures.
The initial rejecting build also recorded an unnecessary `try` warning in the new
probe, removed before the corrected build. Later preflight lint failed on probe
length and grouped arguments; those were refactored without rule changes.

Buffered recovery now accepts the provider terminal reason while preserving
exact content/JSON, raw reason, input/output usage, served model and message ID.
Its existing typed finish mapping stays `.other`. Recovery SSE accepts
`stop_sequence` only after the existing valid block/message ordering checks and
maps tool-stream completion to `.stop`; metrics and single-turn completion retain
raw `stop_sequence`. Assertions require ordered start metrics, exact content,
terminal metrics and exactly one final done/completed event. No tool event is
allowed in this fixture. `legacyStopSequenceMappingRemainsOther` checks buffered
and streaming legacy public APIs retain `.other` and one HTTP request.

The probe compares every captured request body to actual socket-received bytes,
validates the Messages endpoint, request model/messages/stream mode and HTTP 200,
and compares concatenated captured response chunks to the complete scripted body.
Every wire event and lifecycle event must carry the same full logical UUID,
attempt UUID and wire number 1. The UUIDs must be distinct and exactly one request
must reach the socket. `completeJSON` exposes JSON only; original response evidence
is asserted through `completeStructured` and captured at the HTTP boundary for
all entrypoints. Optional test-only capture persists socket request headers/bodies,
wire identities/headers/chunks and lifecycle events when
`STOP_SEQUENCE_EVIDENCE_DIR` is set by the foreground evidence harness.

The unfiltered suites retain rejecting `max_tokens`, malformed/foreign terminal,
invalid usage and completed-tool withholding cases, cancellation precedence,
paused cleanup, broker/session dispatch and completed-tool execution-once tests.
No dependency, legacy runtime, broker/session or recovery admission change is included.
Provider limits and signed/redacted thinking-history exclusions remain unchanged.

Current evidence is retained outside the disposable worktree under
`/home/svetzal/.foundry/tool-logs/mojentic-sw-stop-sequence-c10`: behavioral proof
and actual exit receipts, complete captures, HTTP artifacts, rejecting/frozen source
snapshots and SHA-256 manifests, read-only revision/status records and the copied
controller receipt. `gates.json` records each current foreground gate command,
actual exit and unchanged source hashes; `independent-review.md` records the
independent review of this correction and its assertion strength. The validation
sequence includes all six configured required gates, standalone SwiftFormat,
full-trait release build/DocC, unfiltered tracked-lockfile OSV and the native
full-trait API audit against `v2.1.0`, without scope reductions or suppressions.
Current results must be read from these cycle-10 receipts, not inferred from
historical cycle-9 successes. Apple/Darwin and declared Swift 6.1 validation
remain pending until executed; Linux validation does not establish those targets
or whole-port parity. Foundry/controller owns Git finalization.
