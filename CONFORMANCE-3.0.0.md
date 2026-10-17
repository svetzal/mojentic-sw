# Swift 3.0.0 conformance baseline

Status: scoped recovery correction passes all six local gates. Parts 2 and 3
are pending; macOS recovery baseline verification remains open.
This is not release readiness or a green cross-platform baseline.

The governing authorization is
[`mojentic-unify/RELEASE-3.0.0.md`](https://github.com/svetzal/mojentic-unify/blob/main/RELEASE-3.0.0.md),
agreed October 15, 2026, SHA-256
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
The authoritative recovery contract is `mojentic-unify/TRANSIENT-RECOVERY-2026-10.md`,
including the October 12 amendment, SHA-256
`a53a3a4eb118fa4687dd703d6ce918dd40dd6cb4eda796abc6c429a6e932e7a3`.
Both files were inspected for this correction. The older local contract copy
is not the authority. [RECOVERY-CONFORMANCE.md](RECOVERY-CONFORMANCE.md) retains
the detailed part-1 assertion map and historical evidence limits; its old run
results do not establish validation of this correction.

## Part 1: transient completion recovery

These are executable tests in `Tests/MojenticTests/Gateways`, not just test
counts. Existing assertions remain intact.

| Contract decision | Named tests and boundary assertions |
| --- | --- |
| Frozen request and identity | `RecoveryConformanceTests.bothOperationsPreserveShapingAndResults`, `RecoveryMetadataIdentityTests.publicLoopbackIdentity`: exact captured request bodies, logical/attempt IDs and wire numbers, response shaping and full lifecycle sequence. |
| Header octets and response evidence | `RecoveryHeaderEncodingTests.headerOctetsAndUTF8BodyThroughRecovery`: actual loopback header bytes, exact platform header representation, UTF-8 body bytes and frozen resend identities via `assertStatusWires`. |
| Admission defaults and missing decisions | `RecoveryAdmissionContractTests.providerAdmissionRules`, `emptyAdmissionDoesNotReject`, `pendingAdmissionTerminates`: local/remote rules, distinct empty-decision reason, no unauthorized dispatch. |
| Capabilities and citations | `RecoveryCapabilityTests.ollamaCapabilities`, `oMLXCapabilities`, `openAICapabilities`, `anthropicCapabilities`: five capability values and dated sources per adapter. |
| Safe provider metadata | `RecoveryProviderFrameMetadataTests.providerFrame`, `RecoveryProviderMetadataTests.wrappedCredentialAndEscapedPayload`: allowed codes, credential/payload echoes, raw explicit evidence and identities. |
| All HTTP-date forms | `RecoveryHTTPDateTests.dateMinimumPreservesTimingAndWire`, `obsoleteDateRefusesShortenedMinimum`: exact minimum waits, immutable bytes, lifecycle and failure history. |
| Closed provider/operation vocabulary | `RecoveryVocabularyTests`, `RecoveryVocabularyCodableTests`: every provider and operation, invalid/old serialized values rejected. |
| oMLX keepalive | `OMLXRecoveryKeepAliveTests.interleavedKeepalivesPreserveGenuineFrames`, `keepaliveOnlyRequiresAdmission`: raw-only progress, genuine frame index/metadata unchanged. |
| Typed policy, capture and length errors | `TypedRecoveryErrorTests.invalidPolicy`, `captureCause`, `lengthCause`: pre-dispatch rejection and typed causes through broker/session. |
| Partial output and cancellation | `PublicRecoveryInterruptionTests.publicPartialStreamNeverReplays`, `unfinishedToolRestoresSession`; `RecoveryCancellationTests.cancellationWinsAtEveryBoundary`; `SenderRegistrationCancellationTests.publicHTTPBeforeSenderRegistration`: public broker/session delivery, exact lifecycle fields, observed/delivered progress, typed errors and zero replay, independently held cancellation boundaries. |
| Caller-selected HTTP/category eligibility | `RecoveryPolicySelectionTests.addingNonDefaultStatusChangesClassification`, `removingDefaultStatusChangesClassification`, `removingTransportChangesClassification`: HTTP 500/502 and exact eligibility, reason, acceptance, phase, operation and histories. |
| Tool non-replay | `RecoveryToolSafetyTests.completedToolSurvivesRecoveredFollowUp`, `failurePreservesTypedCauseAfterCompletedTool`, `recoveryDoesNotResetToolDepth`: original actions and session history survive follow-up recovery without repeated tools. |
| Safe reflection | `RecoveryReflectionTests.allPublicBoundaries`, `publicBoundaryProof`: sentinel privacy through public errors and events; explicit inspection preserves raw evidence. |

### macOS investigation

Inspected GitHub Actions run
[38868417395](https://github.com/svetzal/mojentic-sw/actions/runs/38868417395),
source `dd9bb07e85287c403466499db41f517e516f6541`:

| Job | Job ID | Result on that source |
| --- | --- | --- |
| macOS | 116866520159 | Failed in `swift test --parallel`: 388 tests, 109 suites, 11,162 issues. |
| Linux Swift 6.4 | 116866519786 | Success. |
| Linux Swift 6.1 minimum | 116866520286 | Success. |

Command: `gh api repos/svetzal/mojentic-sw/actions/jobs/116866520159/logs`.
Complete macOS job log SHA-256:
`4b88430e02f936e4c28f0a3cf71aa500b6e05afd15be58a061300c330c01b537`.

The first recorded mismatch is `RecoveryStatusTestSupport.swift:113`:
the fixture writes UTF-8 `raw-évidence`; Apple URLSession exposes the octets
as Latin-1 `raw-Ã©vidence`. FoundationNetworking exposes `raw-évidence`.
The correction derives the exact expected Apple representation from the
fixture octets. It does not normalize or rewrite runtime captures. Exact
header dictionary equality remains required. A loopback experiment with
Latin-1 fixture encoding failed on Linux by losing first-response headers/body;
retaining UTF-8 fixture bytes and platform-specific expectations passes the
focused probe. Body and request byte assertions remain unchanged.

The same historical run also records URLSession timeout causes and missing
header/body deliveries. Those failures are not explained by a string decoding
mismatch. `RecoveryLoopback` already suppresses Darwin SIGPIPE; the inspected
log does not establish SIGPIPE as the failure cause. CI bypasses
`scripts/with-gate-environment`, but the log does not establish descriptor
exhaustion or attribute these timeouts to that bypass. Neither is changed on
speculation. A fresh macOS run and per-call traces of remaining failures are
required before claiming the recovery baseline is green.

## API comparison and migration

Baseline tag `v2.1.0` resolves to source commit
`618eb7b42ff2b74e6ff9bb6fd9f3c65373da2262` (annotated tag object
`f105662d7f453ad6bf36b8678d412d372cb27f6d`). Comparison target is the
uncommitted correction over `dd9bb07e85287c403466499db41f517e516f6541`.

Command: `./scripts/with-gate-environment swift package --build-system native --scratch-path .build/api-native --traits full diagnose-api-breaking-changes v2.1.0 --targets Mojentic`.
Exit 0: `No breaking changes detected in Mojentic`.
Combined stdout-then-stderr log SHA-256:
`4689996735ba144934c9cffb7f78d7527281bb2cfcdabf980d47652de9b14115`.

The default Swift 6.4 build-system attempt failed before comparison because
its ABI digester tried to write the sandbox's read-only global Clang cache.
Setting module-cache environment variables did not resolve that failure.
The native-build-system comparison above completed; its deprecation warning
is recorded, not suppressed. This workaround changes no project configuration.

The compiler API comparison does not validate Codable vocabulary, reflection,
error delivery or recovery behavior. The October 12 contract authorizes those
public recovery guarantees. [CHANGELOG.md](CHANGELOG.md) documents their
migration: handle `RecoveryError`/`.recoveryFailure`, use closed provider and
operation types with the new serialized operation vocabulary, and explicitly
inspect raw evidence. Existing legacy entrypoints keep one-send behavior.
The coordinated major version also covers pending work in other ports and
parts 2 and 3; passing this Swift API comparison does not authorize publication.

| Earlier API diagnostic attempt | Result | Log SHA-256 |
| --- | --- | --- |
| Default build system, default traits | Exit 1; read-only Clang cache, comparison not reached | `bace7d443679d9b7e99309921c4e3e8693a14a80c2277575435eb39a21b9c600` |
| Default build system, full traits, module-cache environment overrides | Exit 1; read-only Clang cache, comparison not reached | `4b10117fc107812f40ec0b41b4390a593f2ed79138eb1e0bc7478cfed97f268b` |

## Part 2: native reasoning — pending

No reasoning features are implemented by this correction. Disabled, Enabled,
Low, Medium, High and XHigh parity, explicit model profiles and opt-in reasoning
retention still require implementation and executable mapping against the
coordinator's reasoning contract and Rust reference.

## Part 3: model metadata and request fidelity — pending

No metadata features are implemented by this correction. Context-window lookup,
client first-token timing, caller-only parameters and removal of `num_predict`
still require implementation, migration notes and executable conformance tests.

## Local validation of the correction

Linux Swift 6.4. Results apply to uncommitted source over
`dd9bb07e85287c403466499db41f517e516f6541`. SHA-256 values below cover
stdout bytes followed by stderr bytes, with no inserted separator.
Every gate is invoked through `foundry capture --log-dir <scratch-log-dir> --`;
the table gives its exact inner command. The passing format command is silent.

| Command | Result | Log SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0; no format diagnostics | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0; 210 files, 0 violations | `c1768609b654580f10ac21eccd10526b70c6c2c4340e50fb40ef2d588ef55bc2` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0; release build | `54642e4aa11f0ee457b887f86e37cb467601ec8a43c40003ceed2dd65e49bac9` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 389 tests, 110 suites | `6022d82e1d771f9914b1a78e50e150ad5d86c6d74a742c47d2887f0a483ce816` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 402 tests, 115 suites | `275825a86fb2a4b3d59bc6f7bb0e54594cc2217b6fea17b8347790d42d4bd09f` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0; Mojentic DocC | `19885496908bbdf75b5d5bd4901515692c596e0ef146d3e6d2e7e06c37b11d8b` |

### Focused boundary proof

Command in both runs:
`./scripts/with-gate-environment swift test --filter RecoveryHeaderEncodingTests`.
The test assertions are identical. The negative control writes Latin-1 header
octets instead of UTF-8 through the real loopback socket; it fails on the exact
header bytes and missing captured response headers. The corrected run restores
the UTF-8 fixture and passes. This establishes sensitivity to real HTTP input
and correct local delivery, not reproduction or resolution of the historical
Darwin timeouts. The original Darwin header mismatch is established by the
inspected macOS log above; the Apple expectation still needs fresh macOS CI.

| Probe | Result | Log SHA-256 (stdout then stderr) |
| --- | --- | --- |
| Rejecting fixture input | Exit 1; 1 test | `fdb6aacbadbf75f6262ebd302a251a938ca8fdfb53d5feb87f61734d1528d629` |
| Corrected fixture input | Exit 0; 1 test | `ace60399d287fafb1501f908455b30a5c4497276fabdad8d32d00a0a8b3882ef` |

The tested final Swift test-source SHA-256 values are:

| File (under `Tests/MojenticTests/Gateways`) | SHA-256 |
| --- | --- |
| `RecoveryHeaderEncodingTests.swift` | `6e64cfc855e25fd9053faa1306711064d65f5c3b224dc63cfce31d837e98be11` |
| `RecoveryLoopback.swift` | `e94e4c9bb5f6dc6f7c49b05910910cc8140620ef67a73e50ba0ee2aa95029f01` |
| `RecoveryStatusTestSupport.swift` | `161df7589b29053e3b522b8374b7c590a4ccfcb3bbcc797f2b4d056c75a1e895` |

## Verification scope and coordination

This correction changes the recovery test harness/expectations and documentation,
not an application or cross-repository runtime boundary. The tests above exercise
Swift's real HTTP transport against a scripted provider fixture. They are not a
shared versioned executable provider/consumer contract set verified in another
repository; no such two-sided verification is claimed. The contract document
hash identifies the governing requirements, not an executable contract bundle.
Any later cross-repository boundary change must coordinate the same executable
contract version, tested commits and verification results on both sides.

Foundry prohibits commits, pushes and ref changes in this worktree. Validation
here applies to the uncommitted correction over the source SHA above. New
macOS, Linux and minimum-Swift CI on a resulting main commit remains pending
Foundry finalization. Do not reuse the historical run as evidence for these
changes. No versions, dependencies, recovery semantics or release artifacts
change in this correction.
