# Deterministic test guidance and acceptance evidence

## Scope and tested source

The revised executable set is `swift-deterministic-contracts-v1`. Its executable
manifest is `Tests/MojenticTests/Fixtures/Contracts/deterministic_contracts_v1.manifest.sha256`.
It identifies every Swift source/test, test resource and verifier script. Both
mandatory test modes verify every existing contract manifest before executing
the tests. CI uses the same gate wrapper. Manifest checks identify the tested
code; the public-API assertions establish behavior.

Tested Swift base: `a4b31b5bb10c5377539e721c2326a12943ee8eab` (preserved cycle 4),
with the uncommitted correction identified by executable-manifest SHA-256
`41b50effb0308a59c4702885fe4b1307b7dd1ebcc8059b45c3b8731a81c919b5`.
The four-case OpenAI legacy characterization is retained. The internal OpenAI
line-transport initializer now accepts an optional recovery policy, so both
policy settings exercise the same injected I/O boundary. Public constructors
still default to HTTPClient; both legacy methods still use lineTransport.
No merge, commit, ref update, publication or sibling modification is part of
this correction.

The unchanged cycle 4 probe rejected the recovery-enabled cases (exit 1):
`stream` delivered only `done(nil, nil)` and `completeStreamEvents` delivered
only an error with absent finish evidence. Its stdout SHA-256 is
`a9b5a5262e3773df90b49a119e44d1c74efeed72e8c4b31fd9b1967c7fd9052e`.
After correcting injection, the same filtered command passed all four cases
(exit 0), stdout SHA-256
`31cd5324409bdf334004bb00b15621bf47aa04336ef1867a9149ddf8e4f1be4d`:
`env XDG_CACHE_HOME="$PWD/.build/audit-cache" swift test --filter OpenAIRecoveryTests/legacyStreamingOutcomesThroughLineBoundary`.
Foundry retains both transcripts and the validated behavioral proof record.

Authoritative root contract text was read from mojentic-unify commit
`36f1cd9a2c89b8ad48384ab15a8ad25c4bb387ad`; those three working files were clean.
The local root copies match these exact hashes:

| Contract | SHA-256 |
| --- | --- |
| Transient recovery, including October 12 and revised deterministic evidence | `141d4ee5fcfbc18c940a7e7fe8d5ba9e381abc41a6d03f300f541e0fd5236f9d` |
| Native reasoning prototype | `0a40f3ad45c593bc779411021e45db569e73d3ecce86c99b201e7f8ebb656809` |
| Model metadata/request fidelity/timing | `d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c` |

The catalogs and their original reference provenance are preserved:

| Executable input version | SHA-256 |
| --- | --- |
| `native-reasoning-v1` | `be212ff011125f1d0927e3a65a0d7cd87eedbf9f5ff69e803b4112a80ae6b1f6` |
| `context-window-v1` | `9327502962112a020bafb46c6a677366df732f5a29cd44c92f17e8f632281395` |
| `request-fidelity-v1`, revision `registered-output-limits-2026-10-17` | `369a944ecbd8426a69dd8b299d9cf3718393b38b129ac854f2424dcf0d72e3d5` |
| `ex-stream-first-token-v1`, revision `swift-stream-first-token-v2-owner-anthropic-input` | `949fb9dcb237d362d6ca539ccd90d054578e0ff220090a6544e53962a22f0cc4` |

The context and request source manifests were deliberately refreshed: deleted
socket/packaged paths were replaced by current boundary support and verifiers.
The timing provenance describes the in-process replacement. No catalog behavior
was silently changed to fit a mock.

## Writing and maintaining tests

Drive public gateways, brokers and sessions with doubles at the I/O boundary.
Use `InProcessHTTPFixture` for HTTP evidence and scripted line transport behavior,
`FakeLineTransport` for isolated streaming requests, and the existing fake request
or realtime transports for their corresponding public APIs. Do not mock parsers,
recovery engines, brokers or session logic. Shared contract rows supply both wire
frames and expected public outcomes where available.

`RecoveryReply` is a shared value in its own file; recovery and reasoning support
both depend on it. `RecoveryLocked` remains in `RecoveryTestSupport.swift` and
notifies waiting continuations on state changes. Do not restore polling loops.
Held prefixes, suffix release, transport termination and consumer resumption are
separate signals. Traces use ordered sequence numbers, not wall-clock readings.

Timing suites use `DeterministicStreamTime`, which creates a clock for each test
case. `StreamMeasurement` captures the clock for asynchronous callbacks. Advance
time explicitly after boundary delivery acknowledgement, during a simulated
retry wait or during a tool. `waitForCancellation` suspends at a cancellation
rendezvous without a timer. Recovery policy defaults use injected monotonic/wall
clocks and deterministic jitter. Zero-delay sleeps yield; positive default waits
suspend until cancellation because the default clock is frozen. Individual
policy tests override these to exercise exact deadline, budget and delay rules.

Each buffered fixture creates its own URLSession with `protocolClasses` set on
that session's configuration. Recovery policies carry an internal configuration
factory so every isolated attempt uses the same in-process HTTP boundary;
production policies still create their normal ephemeral configurations.
No fixture protocol is registered globally. Each fixture has a unique
custom-scheme host and weak registry entry, which routes only its own requests.
The transport probe also installs its protocol per session. CI run 39289528643
on `2d5b2a5` showed empty fixture captures and `unsupported URL` (-1002) from
recovery sessions, rather than evidence of another fixture's response. Recovery
must explicitly receive the protocol configuration instead of relying on global
registration. A regression also verifies that an unconfigured session cannot
consume a fixture reply; it fails when global registration is restored.
The isolation regression overlaps distinct 503/504 scripts and releases them in both orders
through explicit request rendezvous, preserving exact wire assertions.

When changing executable sources, deliberately update the affected manifest
entries and include new executed support in the combined manifest. Review the
assertions as well as the digests. Run every `.hone-gates.json` command, both test
modes, and the applicable verifier scripts. Recomputed hashes alone prove no
behavior or external compatibility.

## Characterization and replacement coverage

[Release conformance](../CONFORMANCE-3.0.0.md) maps every binding part 1–3 decision
to named tests and substantive assertions. [Recovery conformance](../RECOVERY-CONFORMANCE.md)
retains the public entrypoint/lifecycle/cancellation matrix. Before migration, the
existing test names and assertions were inventoried; no test suite was deleted.

| Previous proof mechanism | Replacement and retained assertions |
| --- | --- |
| Socket request/response capture | `assertStatusWires`, recovery conformance/identity suites: entire frozen encoded bodies, unmasked logical/attempt UUIDs, wire numbers, exact headers/body/status, ordered captures and complete independently expected lifecycle fields. |
| Partial TCP close and peer FIN | `PublicRecoveryInterruptionTests`, sender-registration and paused ownership suites: explicit typed boundary interruption/cancellation, producer completion before resumption, observed/delivered prefixes, no resend or tool execution, and seeded session rollback. |
| Legacy OpenAI successful SDK streaming with/without a recovery policy | `OpenAIRecoveryTests.legacyStreamingOutcomesThroughLineBoundary` runs all four public-API/policy combinations through the injected line boundary: exactly text `ok` then done(stop, nil) for `stream`, content `ok` then typed incompleteStream(CompletionEvidence(finishReason: "stop")) for `completeStreamEvents`. Each asserts exactly one request, model gpt-4o, stream true, empty messages, Authorization Bearer credential-sentinel, and empty recovery request/lifecycle/wire captures. `ReleaseBaselineCompatibilityTests.configuredRecoveryDoesNotChangeLegacyStreams` separately drives the public recovery-configured constructors and verifies original typed status/body, one send and no recovery capture/lifecycle. Successful FoundationNetworking progressive callback wiring through URLProtocol is outside this split proof. |
| Platform header-octet decoding | `RecoveryHeaderEncodingTests`: exact Unicode boundary header values and UTF-8 body bytes on every platform. Raw TCP octet decoding belongs to Foundation and is no longer asserted. |
| Real idle timeout | `RecoveryTimeoutTests`: an injected `URLError.timedOut` leaves admission pending, permits only explicit allow, preserves exact resend/body/identity and rejects without a second request. The test proves recovery policy, not SDK timeout implementation. |
| Delayed prefixes/capture/retry/tools | `FirstToken*Tests`: injected 200 ms prefix-to-terminal and tool/capture differences, 350 ms Anthropic fragment/duration, no initial empty-input token, duration-only zero-argument tools, retry-origin and provider-unit preservation. |
| Packaged timing consumer | Public timing suites including `sameGatewayConcurrentCompletionsKeepSeparateOrigins`: same gateway, overlapping calls, content versus thinking, exact 0/200 ms independent clocks and visible outcome. No fresh-package installation claim remains. |
| Packaged fidelity and example server probes | Shared request-fidelity/context rows and recovery conformance through public APIs; exact default/explicit bodies, outcomes, warnings and retry admission. The example remains buildable reference code and no verifier starts its restricted network CLI. |
| Configured session authentication | `FirstTokenSessionTests`: original session object and Basic challenge method reach the configured delegate, which cancels in process; a separate typed HTTP rejection preserves exact body/status/Bearer header. FoundationNetworking's credential-success retry bypasses custom URLProtocol, so successful SDK credential replay is explicitly outside this replacement's proof. |
| Realtime/tool ordering sleeps | Realtime interruption awaits tool entry and cancellation; parallel tools force fast-before-slow completion and assert caller-order results and exact tracer correlation/parent identity. |

The hardest seam proof is
`AnthropicLineBoundaryProbeTests.publicStreamPreservesToolIdentityArgumentsAndExactTiming`:
ordinary public streaming rejects when dispatch ignores the injected line
transport, then passes with the seam routed correctly. It asserts the unmasked
tool ID/name/Toronto argument, exact model/stream/messages, endpoint and
credential/version headers, seven output tokens, 25 ms first-token time and
50 ms duration. The recorded rejecting command exited 1 with an actual stream
failure; the corrected command exited 0. Foundry retains the behavioral proof
record and transcripts separately from repository documentation.

## Static execution-path inspection

`scripts/check-deterministic-tests` inspects all 158 Swift test/support and
verifier paths, including itself. Character-class spellings in its server and
uptime patterns avoid self-matching while preserving detection. Every invocation
checks 19 inert operation samples with the same detector; a temporary test file
containing all 19 samples was also rejected (exit 1) and removed before gates. It rejects socket/server operations, real sleeps, remote-command
launches and wall-clock measurements. A manual call-path review also covered
implicit defaults that a textual guard cannot establish:

- Buffered/recovery public requests use custom fixture schemes intercepted by
  URLProtocol. Ordinary scripted streams use injected line transports. The
  standalone probe uses its own custom scheme. None can fall back to HTTP/DNS.
- `OMLXURLSessionTests` installs its own URLProtocol in its supplied session;
  the fixture route handles every request in process, including errors.
- Configured-session challenge tests cancel authentication before any SDK
  credential retry. No final test path calls `.useCredential`.
- Model registries read bundled/static maps. Discovery and request fidelity use
  contract-derived responses, not live provider or package-registry lookups.
- Realtime requests and tool execution use fake boundary actors, explicit
  barriers and cancellation signals. No test depends on scheduler elapsed time.
- Recovery default policies that can retry receive deterministic timing;
  remaining one-attempt/healthy default-policy cases cannot reach backoff.
- Verifiers perform local hashing and invoke the repository's tests. The trace
  analyzer reads recorded evidence only; obsolete socket/syscall/descriptor
  correlation was removed. No script starts a server or a detached SwiftPM
  consumer, and no script calls a remote registry.

Bundled fixture reads, temporary file-tool tests and optional local trace writes
remain local filesystem operations. SwiftPM builds use the pinned dependencies;
there is no test-driven dependency resolution or live OSV/provider call. The
existing CI supply-chain scan remains separate from deterministic verification.
Every GitHub Actions job has a 30-minute timeout. The gate wrapper and CI contain
no loopback thread/listener or descriptor-floor assumptions.

## Required gate results

All six commands from `.hone-gates.json` passed on Linux Swift 6.4.1 against
the corrected source and manifest identified above. Gate names below refer to
those exact commands, each invoked through `foundry capture`. Transcript hashes
cover complete stdout followed by stderr; Foundry archives those run records.

| Gate | Exit | Transcript SHA-256 |
| --- | --- | --- |
| `format` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `lint` | 0 | `87d1518979ea2ef7317f730983f0cc30c8a0f4a22e2882345e44390e8f99133c` |
| `build` | 0 | `d255d1bee014d3bccfaedf3e06d9729d6d0bbd1e3e8f1f2200e016ae9f31c450` |
| `test` | 0 | `aba48f2b893d4a8a86c09e0ab8035094f584d5521fa46849e264587e0ce169c6` |
| `test-full-traits` | 0 | `a4e1c8d79ec08645c2847fd21b74ab1c46e557a266441aa3ac3b0fccb6c1160f` |
| `docs` | 0 | `8f646ea11bc5567ade6759171d5658ac376ed1e0c0c6a388502ef01588b7fdf3` |

Both test modes verified the same executable manifest before running their
public-API assertions. The default suite passed 441 tests; the full-provider
suite passed 461. Counts supplement the named assertion maps, not replace them.

Earlier correction evidence is retained below; these supplemental commands
and traces were not rerun for cycle 5. The context, request-fidelity and timing
verifier entrypoints passed in that earlier correction. Their `--skip-build`
invocations reused its then-current full-provider binary with unchanged
executable sources/manifests. The sender-registration
trace run and the trace analyzer both exited 0.

| Additional check | Exit | Elapsed seconds | Transcript SHA-256 |
| --- | --- | --- | --- |
| `scripts/verify-context-window-contract --traits full --skip-build` | 0 | 3.020 | `ef3227e74cea87d235b8c4e3e9db9ec3f9a611cab1730cd6d24f0b773ed6fa58` |
| `scripts/verify-request-fidelity-contract --skip-build` | 0 | 2.236 | `487cd81ea3b01a93254141bfc5562c73e32a5dc534fa3b6132cca97a8b9c59f9` |
| `scripts/verify-stream-timing-contract --skip-build` | 0 | 1.147 | `f827d08becd1c9c63044892e1a864f52c848f40dec12dcb48a1494ef6ad29a9b` |
| `swift test --traits full --skip-build --filter SenderRegistrationCancellationTests` | 0 | 2.684 | `84aa53fdc4f63e0d3342ad8cb03611f8ce75d21476bacd03ce653c71db1aeb5d` |
| `scripts/characterize-recovery-traces.py` | 0 | 0.100 | `13ef07fe1ac3bbab3469ade72c7aa0929c56026220687099ded82c7e67652156` |

## Retained public-boundary trace

In the earlier correction, the trace analyzer verified 42 named calls with no byte/ordering violations.
The archived aggregate trace SHA-256 is
`7e94f735ed51b3abad3fdff51e0c5176cc6bc74a18c581421ef4fa40c6af9e54`. This supplements the complete event equality assertions in tests.
One concrete capture is `sender/ollama/tools/gateway/incomplete`:

- Logical ID: `DD640AF0-A7BD-472B-A024-476D45231852`.
- Attempt ID: `8BA8E546-C77E-4EF7-9174-D6534BD04A6C`; wire number 1.
- Exact encoded request body:

```json
{"stream":true,"model":"fixture","options":{},"messages":[]}
```

Every event below carries those same unmasked identities, provider `ollama`,
operation `streaming`, and acceptance `unknown`. Delay and progress identity/frame
index are nil throughout; every observed/delivered semantic field is zero.

| Ordered transition | Headers received | Raw bytes | Category/status/phase/eligible/reason |
| --- | --- | --- | --- |
| `attemptStarted` | false | 0 | nil/nil/nil/nil/nil |
| `attemptFailed` | true | 194 | transport/200/streaming/true/transientTransport |
| `exhausted` | true | 194 | transport/200/streaming/true/transientTransport |

The public terminal is typed `RecoveryError.exhausted` with an inspectable
`URLError.networkConnectionLost`, exact 194-byte unterminated prefix, no semantic
sender, no tool execution or resend, and transport/producer completion before
consumer resumption. Framed controls release the delimiter separately and prove
cancellation/ownership rather than treating incomplete bytes as a decoded frame.

The earlier isolated Anthropic seam probe exited 0 against its then-current manifest;
transcript SHA-256 `2dc83265cf77cd3e5902b7da631322f702301f950496f72e1a1dfce8f3312925`. The initial rejecting probe exited 1 with an
actual streaming failure; transcript SHA-256 `2de65dd3872d0d4de7aaabd03ec9e3a342cce68b3e724d1e63dee4533f1ae689`. That earlier behavioral proof's
JSON shape, integer exit codes, command strings and both existing log paths were
validated after these runs.

## Verification limits and coordination

Only Swift's provider adapters and public consumers were exercised locally.
Reference commits embedded in the catalogs establish provenance, not current
verification of another implementation. No provider/dependent repository ran
this revised executable version/hash at a tested commit in this task. Paired
cross-repository compatibility remains a coordination gap; no sibling was
modified. Current macOS/Swift 6.1 CI and detached-package verification are not
claimed by this Linux Swift 6.4 run.
