# Swift transient recovery conformance

This reconciliation starts at `ce5ae889539ae86316cbad32bac145904406f5da` and
closes the release-baseline API compatibility gap while preserving the landed
recovery implementation, including sender-registration cancellation. The initial
working tree was clean. Read-only `git ls-remote origin refs/heads/main` reported
the same commit; `.foundry/remote-main.txt` retains that observation. Foundry's
explicit prohibition on ref mutation supersedes fetch, pull, rebase, commit and
landing instructions. All work remains uncommitted in this worktree.

## Release-baseline reconciliation and migration

The original, unfiltered `v2.1.0` audit rejected the starting source with exactly
seven diagnostics: generic signature changes in `Router.subscribe` and
`JSONSchemaGenerator.schema`, `MojenticError.recovery`, and progress/metrics
additions to `GatewayStreamEvent` and `CompletionStreamEvent`. The generic
signatures and legacy enum cases now match the release baseline. The final audit
uses the same v2.1.0 tag with no exclusions, allowlists, or substituted baseline.

Policy semantics in `TRANSIENT-RECOVERY-2026-10.md` license a separate opt-in API
where a legacy error vocabulary cannot safely grow. Recovery telemetry now uses
`RecoveryGatewayStreamEvent` and `RecoveryCompletionStreamEvent`. The latter
exposes `.recoveryFailure(RecoveryError)` directly, retaining typed final causes
and bounded history. `MojenticError` has no recovery case. CompletionEvidence's
landed safe description/debug-description conformances remain intact; provider
values remain available through explicit properties.

| Caller | Recovery entrypoint | Legacy entrypoint |
| --- | --- | --- |
| Ollama / oMLX tool stream | `streamRecovering` | `stream` |
| Ollama / oMLX single turn | `completeStreamEventsRecovering` | `completeStreamEvents` |
| Broker single turn | `generateRecoveryStreamEvents` | `generateStreamEvents` |
| Broker tool stream / ChatSession | Existing API internally routes to the opt-in gateway boundary | Existing public result vocabulary |

Legacy streaming entrypoints retain their original single-request parsers and
completion rules, even when an instance has a recovery policy. They do not convert
recovery errors into legacy errors. Buffered recovery still throws RecoveryError
directly. Gateways without recovery support are lifted without fabricated telemetry
or retries; OpenAI/Anthropic provider recovery is not expanded.

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

## Durable evidence and validation limits

The delivered trunk lacked referenced prior .foundry artifacts. This run retains
fresh evidence rather than claiming those historical receipts exist:

- `.foundry/rejecting-sources.tar` retains starting Sources from the exact commit.
- `.foundry/logs/rejecting-native/` retains the seven rejecting API diagnostics and
  `.foundry/logs/rejecting-native.exit` records the actual nonzero exit.
- `.foundry/logs/corrected-api/` retains the initial corrected passing audit;
  `.foundry/logs/final-api/` retains the final-source audit.
- `.foundry/logs/probe/` and `.foundry/logs/compatibility-tests/` retain the first
  passing public recovery boundary and legacy compatibility probes.
- `.foundry/logs/final-*/`, `.foundry/gates.json` and `.foundry/source-revisions.json`
  retain complete captures, actual exit codes, commands and source hashes.
- `.foundry/proof.json` records the direct source-compatibility acceptance probe;
  `.foundry/compatibility-audit.json` links rejecting/passing evidence separately.
- `.foundry/independent-review.md` records scoped independent source/evidence review,
  concerns and their reconciliation. Historical conformance text is retained in
  `.foundry/previous-conformance.md` solely as history.

The API audit uses SwiftPM's native build system because the default system's
baseline digester attempted to write a read-only global clang cache. XDG_CACHE_HOME
points into this worktree; this changes neither audit scope nor source baseline.
The failed environmental invocations, native-system deprecation and SwiftPM
user-cache warnings are retained. No source warning suppression, formatter/linter
threshold change, advisory exclusion or dependency change is used.

The project gates are strict Swift format, strict SwiftLint, release/debug builds,
unfiltered parallel/default and full-trait tests, and DocC with warnings as errors.
The unfiltered OSV scan uses tracked Package.resolved. Actual current results and
counts are recorded in `.foundry/gates.json`; failures remain in the logs.

Validation here is Linux Swift 6.4. Apple URLSession/Darwin sockets, strict
concurrency and DocC checks remain pending. The declared Swift 6.1 minimum remains
pending. The separate `swiftformat` executable is unavailable here; the repository
and required gates use `swift format`, whose strict check is executed. No historical
whole-repository SwiftFormat result is claimed as current evidence.

Whole-mission gaps remain OpenAI/Anthropic recovery, oMLX telemetry parity, remote
termination/status/idempotency and Apple/minimum-toolchain validation. This task
makes no whole-port parity claim. Foundry owns final review and finalization; no
release, tag, PR, push, sibling write or ref mutation is performed.
