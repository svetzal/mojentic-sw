# Bounded completion recovery

This runnable example uses `OMLXGateway.complete` with an opt-in
`CompletionRecoveryPolicy`. It deliberately admits one eligible HTTP 503 retry
against a caller-provided endpoint. The example itself performs HTTP I/O;
repository acceptance runs entirely in process:

```sh
swift test --traits full --filter RecoveryConformanceTests
```

These public-API tests use a scripted HTTP boundary and verify retry admission,
unchanged request bytes, exact response content, identities, lifecycle and privacy.
The former server-launching example probe has been removed.

Build the reference product without starting a provider:

```sh
./scripts/with-gate-environment swift build -c release --product RecoveryExample
```

The executable's CLI still accepts only a caller-owned HTTP `127.0.0.1` root
URL with a port and `--admit-scripted-retry`. Repository tests and verification
scripts never invoke that network path. The flag acknowledges possible duplicate
work on a synthetic provider; it is not a production admission rule.

The reference policy allows two total attempts with zero base delay, a
one-second delay ceiling and a five-second recovery budget. Retry-After can
still delay or refuse admission. The budget governs admission/backoff, not
healthy generation. Eligibility is separate from permission: a status, timeout,
closure or keepalive cannot establish that inference ended. Production admission
needs independent resource and exact-attempt evidence.

The example prints safe lifecycle fields and safe error descriptions. Raw capture
and `inspectEvidence()` are sensitive and are not logged. Recovery does not replay
brokers or tools; cancellation remains authoritative.

See [buffered recovery](../../Sources/Mojentic/Mojentic.docc/BufferedCompletionRecovery.md),
[public entrypoints](../../RECOVERY-CONFORMANCE.md#public-entrypoints), and
[provider capabilities](../../Sources/Mojentic/Mojentic.docc/RecoveryCapabilities.md).
