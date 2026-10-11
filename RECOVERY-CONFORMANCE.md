# Swift transient recovery conformance

This OpenAI recovery slice starts at verified clean HEAD
`11e2503130a77924527d81ea0331929bf716d15b`. Controller synchronization is
recorded in `/home/svetzal/.foundry/operations/mojentic-port-alignment-20261010/status-recovery/receipt.json`
(observed October 10, 2026 at 23:39:13 UTC), including clean status, fetch,
pull with rebase, revisions and log hashes. Its Swift revision matches the preserved slice’s parent revision.
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
| Ollama / oMLX / OpenAI tool stream | `streamRecovering` | `stream` |
| Ollama / oMLX / OpenAI single turn | `completeStreamEventsRecovering` | `completeStreamEvents` |
| Broker single turn | `generateRecoveryStreamEvents` | `generateStreamEvents` |
| Broker tool stream / ChatSession | Existing API internally routes to the opt-in gateway boundary | Existing public result vocabulary |

Legacy streaming entrypoints retain their original single-request parsers and
completion rules, even when an instance has a recovery policy. They do not convert
recovery errors into legacy errors. Buffered recovery still throws RecoveryError
directly. Gateways without recovery support are lifted without fabricated telemetry
or retries. OpenAI Chat Completions now supports opt-in per-request recovery;
Anthropic remains outstanding.

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
| Anthropic | Outstanding | Existing legacy behavior | Existing legacy behavior | No new recovery claims |

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

Whole-mission gaps remain Anthropic recovery, oMLX telemetry parity, remote
termination/status/idempotency and Apple/minimum-toolchain validation. This task
makes no whole-port parity claim. Foundry owns final review and finalization; no
release, tag, PR, push, sibling write or ref mutation is performed.
