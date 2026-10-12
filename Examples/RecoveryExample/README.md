# Bounded completion recovery

This runnable example uses `OMLXGateway.complete` with an opt-in
`CompletionRecoveryPolicy`. It deliberately admits one eligible HTTP 503 retry
against a caller-owned scripted loopback server. It needs no oMLX installation,
model download, API account or live inference.

From the repository root, with Swift 6.1 or newer and Python 3 installed:

```sh
python3 scripts/probe-recovery-example.py
```

The probe builds `RecoveryExample` in release mode, starts a server on an ephemeral
`127.0.0.1` port, runs the actual executable, and shuts down the server. Expected
executable output:

```text
attemptFailed wire=1 status=503 eligible=true acceptance=unknown
admission next=2 decision=allow
attemptSucceeded wire=2
Recovered exactly: café 猫
```

The probe additionally requires exactly two `/v1/chat/completions` requests,
identical encoded payload bytes, the expected model and message, the synthetic
credential on both requests, and no credential or private response sentinel in
stdout or stderr. Assertion failure exits nonzero.

To build separately:

```sh
./scripts/with-gate-environment swift build -c release --product RecoveryExample
```

For your own scripted HTTP fixture (503 first, valid OpenAI-compatible buffered
completion second), use its loopback port:

```sh
RECOVERY_EXAMPLE_API_KEY=synthetic-key ./scripts/with-gate-environment swift run -c release RecoveryExample http://127.0.0.1:PORT --admit-scripted-retry
```

Replace `PORT` with the fixture's numeric port. The executable accepts only an
HTTP `127.0.0.1` root URL with a port and the explicit admission flag. It uses
`scripted-model` and the user message `Demonstrate bounded recovery.` It makes no
model-list, load, unload, or health requests. The flag acknowledges duplicate
work on a synthetic server; do not use this admission rule for production.

The policy allows two total attempts, zero base delay, a one-second delay ceiling
and five-second recovery budget. Retry-After can still delay or refuse admission.
The budget governs admission/backoff, not healthy generation; the HTTP timeout is
ten seconds. Eligibility is separate from permission. A 503, timeout, socket
closure or keepalive does not prove remote termination. Dispatched acceptance
remains unknown. Production controllers must independently decide whether to
allow duplicate work and must leave unresolved admission pending or reject it.

The example prints safe lifecycle fields and `RecoveryError.description` only.
Other errors use a fixed diagnostic and failures exit 1; invalid command lines
exit 2. Invalid policy limits can throw `MojenticError.invalidArgument` before
dispatch. Raw wire capture and `inspectEvidence()` are sensitive and are not
logged. Recovery never replays a broker loop or tool, and failed semantic output
cannot be retried. Cancellation remains authoritative.

See [buffered recovery](../../Sources/Mojentic/Mojentic.docc/BufferedCompletionRecovery.md),
[entrypoint error rules](../../RECOVERY-CONFORMANCE.md#public-entrypoints),
[cited capabilities](../../Sources/Mojentic/Mojentic.docc/RecoveryCapabilities.md),
and [oMLX keepalive behavior](../../Sources/Mojentic/Mojentic.docc/LocalModelsWithOMLX.md).
