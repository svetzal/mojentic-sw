# Recovery conformance

Local verification passed all six required gates, including both test modes and
DocC, against executable manifest `010a425e8d3d44ca8a484bbcbbd3f90fd6377357443670a4a977632644ed76eb`.
The [verification record](docs/DETERMINISTIC-TESTS.md) gives elapsed runtimes,
complete transcript hashes, unmasked trace evidence and the external verification gap.

Current evidence uses public APIs with in-process HTTP transports and injected
clock/sleeper behavior. The binding recovery contract is the synchronized local
`TRANSIENT-RECOVERY-2026-10.md`, including the October 12 amendment and revised
October 18 deterministic-evidence rule. See [the release conformance map](CONFORMANCE-3.0.0.md)
for all twelve binding decisions, capabilities, provider metadata, dates,
vocabulary, keepalive, privacy and admission semantics.

The socket fixture is deleted. All existing recovery and reasoning suites remain,
using `InProcessHTTPFixture`. `RecoveryReply` is separately shared with reasoning
support; `RecoveryLocked` provides notification-based state waits. Exact request
bodies and unmasked identities anchor independently constructed lifecycle fields;
expected errors never derive from production classification output.

## Public entrypoints

| Scenario | Public acceptance evidence |
| --- | --- |
| Success and retry-to-success | `RecoveryLifecycleCompletionTests`, `RecoveryLifecycleBufferedCallerTests`: ordinary, structured and JSON buffered calls, broker projections and session/image callers; gateway/broker/session tool streams and gateway/broker single-turn recovery streams; exact HTTP boundary bytes, identities, Unicode content and terminal delivery |
| Partial content, reasoning and tools | `PublicRecoveryInterruptionTests`: `LLMBroker.stream`, `ChatSession.stream`, `generateRecoveryStreamEvents`; hidden reasoning and withheld tools remain observed-only; exact prefixes, raw bytes, typed causes, no admission/replay/tool execution and seeded rollback |
| Cancellation before dispatch | `RecoveryCancellationTests` before encoding; `RecoveryLifecycleFailureTests` at request capture on all typed public paths; no wire attempt consumed, nil identity, acceptance no and zero boundary requests |
| Active request, admission and backoff cancellation | `RecoveryCancellationTests`, `StreamingRecoveryCancellationTests`, `RecoveryLifecycleBufferedCancellationTests`, `RecoveryLifecycleScopedCancellationTests`: original attempt retained, exactly one request, observed/delivered progress, ordered terminal events, acknowledged active transport cancellation and completed relay before session history assertion |
| Capture before/after dispatch | `TypedRecoveryErrorTests.captureCause`: all applicable gateway, broker, session, image, projected, tool-stream and single-turn paths, scoped/unscoped; `RecoveryCancellationTests` separates request/header/body capture; exact synthetic causes and zero delivered progress |
| Malformed and length responses | `RecoveryLifecycleFailureTests.malformedAtEveryPublicPath`, `TypedRecoveryErrorTests.lengthCause`: all typed public paths; original length evidence, exact observed versus delivered bytes, HTTP bodies, no tool execution and session rollback |
| Budget/deadline refusal | `RecoveryLifecycleLimitTests`: all typed public paths, pre-admission and prospective backoff refusal; HTTP classification stays selected/eligible, original typed cause/attempt retained, no resend |
| Status exhaustion, permanent errors, policy and bounded delays | Existing `assertSelectionLifecycle`, `RecoveryPolicySelectionTests`, `RecoveryBoundedTimingTests` remain intact, including HTTP 500/502/418 selection, category selection, saturation, non-finite jitter and exponent cap |


All provider matrices include Anthropic under full traits. Tool fragments do not
apply to single-turn APIs. `assertStatusWires` compares frozen request bodies,
distinct attempt IDs, one logical ID, consecutive wire numbers, exact status and
header values, ordered request/header/body events and the full received body.
`RecoveryLifecycleEvidence` constructs every expected event field from the
scripted case and captured public identity. These are substantive assertions,
not event counts or schema-only checks.

## Cancellation and ownership

`SenderRegistrationCancellationTests`, `PausedRecoveryOwnershipTests`,
`PausedRecoveryDeliveryTests`, `ScopedRecoveryRelayTests` and
`TerminalRecoveryDeliveryTests` hold consumers and producers independently.
State changes wake continuations directly. Active transport termination and
producer completion precede caller resumption; no polling, timer or listener is
needed. Broker/session interruption still asserts delivered versus observed
prefixes, typed causes, no replay or tool execution, and seeded history rollback.
`RealtimeSessionTests.interruptCancelsBatch` now awaits tool entry and actual
cancellation; `ParallelToolRunnerTests.preservesOrder` forces fast-before-slow
completion and verifies input-order outcomes without sleeps.

## Verification scope

See [current deterministic verification](docs/DETERMINISTIC-TESTS.md) for source
and contract hashes, all mandatory gate results/runtimes and static inspection.
The deleted packaged/server example probes are not current evidence.
Cross-repository verification of this executable set remains unperformed; no
provider or dependent repository was modified. Prior evidence is available from
git history and does not establish the revised source's results.
