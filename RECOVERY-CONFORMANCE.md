# Swift transient recovery conformance

The preserved c4 baseline is `59abd6b0c7aca633563f7907c0d0825c619c3774`,
including streaming recovery and scoped cancellation. This correction closes only
the cancellation-before-sender-registration gap in that slice. Foundry owns
finalization; no refs, releases, dependencies, or sibling/harness files are changed.
The initial working tree was clean. The later Foundry prohibition on ref mutation
supersedes the plan's fetch/rebase/landing steps; observed origin/main is recorded
in `.foundry/regression-revisions.json`, without asserting remote freshness.

## Verified cancellation contract and migration

Create and consume local recovery streams within
`withRecoveryStreamCancellation(operation:)`. The task-local scope owns producer
tasks across unrelated consumer awaits, cancels unfinished producers on exit, and
propagates through broker/session tasks. Registrations race safely with cancellation
and completion. Scoped broker/session relays use rendezvous delivery so buffered
terminal metadata cannot establish success ahead of downstream consumption.
Existing APIs retain their signatures and ordinary iteration/lifetime cancellation.
Bare AsyncStream APIs cannot safely observe cancellation while a consumer is paused
outside next(); callers needing that guarantee must migrate to the scope. Detached
tasks require their own scope. Local cleanup never proves remote termination.

| Adapter | Buffered recovery | Streaming recovery | Paused local cleanup | Remote cancellation/status/idempotency |
| --- | --- | --- | --- | --- |
| Ollama | Opt-in ordinary/structured | Opt-in both public paths | Supported inside scope | Unsupported |
| oMLX | Opt-in ordinary/structured | Opt-in both public paths | Supported inside scope | Unsupported |
| OpenAI / Anthropic | Legacy one request | Legacy paths | Recovery scope unsupported | Recovery not implemented |

Realtime and embeddings remain outside recovery. Swift retains whole-text embeddings.
Ollama terminal Progress/Metrics remain ordered before completed tool delivery.
oMLX's preserved decoder does not emit equivalent Progress/Metrics events; this
correction does not invent provider values or implement missing telemetry.

## Behavioral evidence

`.foundry/proof.json` retains real rejecting and corrected HTTP probes, actual
exit codes, source hashes, and complete Foundry captures. The first gateway-only
probe rejected the preserved baseline before fixture/documentation expansion.
The final identical public matrix is then run with baseline sender cancellation
and with the corrected latch. Internal task-local scheduling seams pause precisely
after the initial cancellation check, inside the installed cancellation handler,
before continuation registration. These seams exercise public Ollama/oMLX HTTP
requests rather than replacing them with an internal synchronization test.

`SenderRegistrationCancellationTests` independently retains the cancelled consumer,
the returned stream, and the held fixture response. It targets gateway senders,
broker throwing/completion relays, and the session's nested throwing relay.
Completion has no session API, so those two matrix combinations are inapplicable.
Before resuming the consumer or draining the stream, it requires all delivery
finish callbacks, the gateway cleanup report, and peer FIN. The rejected baseline
requires draining to unstick a sender and exposes forbidden delivery after cancellation.
The corrected matrix checks exact socket/captured request bytes, unmasked identities,
one actual wire attempt, original headers/body and `URLError.cancelled`, failed
history, observed content/reasoning/tool counters, and exactly
`attemptStarted`, `attemptFailed`, `cancelled`. A retained stream later delivers
only its terminal cancellation. Session history rolls back.

Gateway reports count gateway-to-relay delivery, not final consumer delivery.
The direct gateway is paused before any acknowledgment; the broker acknowledges
its first semantic event (Ollama content, oMLX reasoning), and the session's extra
relay permits two upstream acknowledgments. A dedicated acknowledgment seam
synchronizes these exact counters before cancellation, avoiding scheduler guesses.
Completed-tool delivery remains zero on every path. Lifecycle equality prohibits
retry, admission, and success. Existing terminal-frame and tool-once tests remain
applicable.

`PausedRecoveryOwnershipTests` exercises applicable Ollama/oMLX public gateway,
broker, and session paths against active keepalives and buffered terminal frames.
It retains the public stream, verifies peer FIN for active replies, exact captured
request bytes at the loopback boundary, unmasked logical/attempt identities and
wire number, actual wire count, original headers/body, observed UTF-8/tool counters,
failed-attempt history, and exactly attemptStarted/attemptFailed/cancelled.
`PausedRecoveryDeliveryTests` separately consumes exact content/reasoning values
before pausing, verifies each provider's order and exact observed/delivered counts,
and requires local cleanup and FIN before resumption. Single-turn reasoning remains
observed-only. `ScopedRecoveryRelayTests` retains the returned broker/session stream
past cancellation and checks retained typed RecoveryError cancellation (or
MojenticError.cancelled for a cancelled relay) and session rollback. The strengthened
Ollama terminal telemetry test holds an independent pause until cleanup; no completed
tool, retry, or success is delivered.

Existing recovery refusal, capture, admission, protocol, retry timing, broker tool
history, and compatibility suites remain applicable. Fixtures are scripted HTTP;
no live inference or benchmark restart is used. Bounded polling is a failure timeout;
consumer/server pause synchronization is independent of cancellation.

## Rust safety comparison and independent review

Exact Rust source at `4ca1ed279c02eab37827a1ed07c30e961155ecf3` is retained under
`.foundry/rust-reference/`, with hashes in `.foundry/rust-reference.json`. Its worker
reserves delivery capacity before advancing the source and selects cancellation
independently of source polling. Failed dispatches are recorded before terminal
cancellation. Swift's scoped producer cancellation and relay backpressure address
these same local safety obligations. Rust uses an explicit token/drop guard; Swift
needs the scoped caller handler. This is a source comparison, not a Rust rerun or
a claim of whole-port equivalence.

The independent review is `.foundry/review-current.md`, with exact reviewed hashes
and its own evidence inspection. Historical artifact references are not counted as current evidence; this worktree
did not contain the previous `.foundry` artifacts. Current receipts are retained
afresh without writing to sibling checkouts.

## Formatting and validation limits

All existing formatter/linter configurations remain unchanged; no exclusions,
allowlists, advisory suppressions, or threshold changes are added. Complete logs
and exit receipts are retained under `.foundry/logs/`; `.foundry/gates.json`
records current checks. Nonzero attempts are retained as failures.

Linux Swift 6.4 is available here. Apple URLSession/Darwin sockets/strict concurrency/
DocC and the declared Swift 6.1 minimum remain pending unless separately verified.
The unfiltered OSV scan uses the tracked `Package.resolved` without suppressions.
An unfiltered API audit against the preserved c4 commit checks this repair for
public API changes. The separate release-baseline audit remains an audit of the
whole preserved slice: historical diagnostics must not be hidden by changing
unrelated APIs, removing streaming features, or using a breakage allowlist.
The current preserved-baseline audit exits 0 with no breaking changes. The
unfiltered `v2.1.0` audit exits 1 with seven diagnostics: five enum-case additions
(`MojenticError.recovery`, progress/metrics on both stream event enums), and two
prior generic-to-opaque metatype signature changes (`Router.subscribe` and
`JSONSchemaGenerator.schema`). These are already in c4 and are not introduced by
this repair. They remain whole-slice landing blockers; this task does not remove
preserved features, change unrelated APIs, or allowlist them. Both audits use the
native build system and writable caches; the native-system deprecation diagnostic
is retained. Receipts are recorded in `.foundry/proof.json`.

Current Linux gates pass: strict native format, strict SwiftLint, whole-repository
SwiftFormat lint, release build, 311 default tests, 312 full-trait tests, DocC with
warnings-as-errors, and unfiltered OSV (three resolved packages, no issues).
The final sender-registration HTTP matrix passes all ten applicable combinations.
SwiftPM's cache/sandbox diagnostics are retained separately from source warnings.
Exact tool versions are in `.foundry/toolchain.json`.

Whole-mission gaps remain OpenAI/Anthropic recovery, oMLX telemetry parity,
remote termination/status/idempotency, and Apple/minimum-toolchain validation.
This local cancellation proof makes no coordinated-parity or whole-mission claim.
Foundry must reconcile and finalize the uncommitted slice on main after review
and applicable landing gates; no landing is performed in this task worktree.
