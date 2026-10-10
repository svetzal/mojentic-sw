# Swift transient recovery conformance

The preserved streaming slice is `0b06cc90e1cf51235001ad702d80f4ff2ab997c0`.
This correction adds cancellation ownership across consumer pauses and reconciles
SwiftFormat with native formatting. Foundry owns finalization; no refs, releases,
dependencies, or sibling/harness files are changed.

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

`.foundry/proof.json` contains the real rejecting and corrected HTTP probe with
actual exit codes and complete logs. The rejection keeps the consumer paused on a
cancellation-independent continuation: no cleanup report arrives, and lifecycle
stops at attemptStarted. The corrected scope produces cleanup before resuming the
consumer, releasing the stream, or releasing the held fixture response.

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
and its own evidence inspection. Available historical captures are copied into
`.foundry/prior-evidence/`; the inventory records originals and hashes. The original
historical review.md and formatter-conflicts.md were not located. Prior report
references are not counted as evidence of current approval.

## Formatting and validation limits

All default SwiftFormat rules remain enabled, with no exclusions, lint allowlists,
or disabled rules. Native formatting keeps its 110-column limit and all prior rules.
Import grouping is aligned through style configuration while import ordering stays
mandatory. Multiline layout, equivalent condition expressions, and fixture literals
were reconciled across the full repository; escaped multiline fixture strings retain
their original bytes. Complete captures and actual exits are retained under
`.foundry/logs/`; final gate receipts are in `.foundry/gates.json`. Nonzero attempts
remain evidence and are never presented as passing audits.

Linux Swift 6.4 is available here. Apple URLSession/Darwin sockets/strict-concurrency/
DocC and the declared Swift 6.1 minimum require controller validation and remain
explicitly pending. The unfiltered OSV scan has no suppressions or dependency changes.
The default unfiltered API comparison fails during baseline generation on a read-only
Clang cache. The native-build-system rerun with writable caches completes against
`v2.1.0` and exits 1 with seven diagnostics: five enum-case additions in the preserved
streaming slice and two generic-to-opaque metatype signature changes produced by the
mandatory default formatter rule (Router.subscribe and JSONSchemaGenerator.schema).
That audit is not passing; no breakage allowlist or threshold change is used.
Whole-mission gaps remain OpenAI/Anthropic recovery, oMLX telemetry parity, remote
termination/status/idempotency, and cross-port controller validation. No claim of
whole-mission completion follows from the local cancellation proof.

Final Linux receipts: native strict format, whole-repository SwiftFormat lint, strict
SwiftLint, release/debug builds, both full test suites (310 default / 311 full-trait
tests), DocC with warnings-as-errors, and unfiltered OSV all exit 0. The independent
paused-consumer probe exits 0. Source hashes are in `.foundry/source-hashes.json`;
`.foundry/validate-evidence.py` checks proof shape, exits, log existence, hashes, and
retained mutations. SwiftPM emits sandbox cache diagnostics; these are retained,
not source compiler/DocC warnings or suppressed diagnostics.
