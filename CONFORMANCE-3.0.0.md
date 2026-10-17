# Swift 3.0.0 conformance baseline

Status: the part 1 recovery baseline passes all six local gates on macOS and
every GitHub Actions job (macOS, Linux Swift 6.4, Linux Swift 6.1 minimum) at
`db0354d61d334cb943e5ef8cb8a78d5951131ab4`. The API comparison against
`v2.1.0` reported no breaking changes for that recovery baseline. Part 2 is
implemented locally below, with external verification pending. Part 3 is pending.
This is not release readiness; the historical API result does not cover part 2.

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

### macOS: cause and fix

The macOS CI Test step failed on every run from October 12 to October 17. It
passes from `baed786edd18c58bfd36c50c931ac7d8efe92fa0` on. Three Darwin-only
causes were found; each was reproduced on a Mac (macOS 27.2, Swift 6.4) before
it was changed. None of them is a library defect. Library sources, recovery
semantics, dependencies and versions are unchanged.

1. **Header octets.** Apple URLSession exposes UTF-8 header octets as Latin-1;
   FoundationNetworking decodes them as UTF-8. Corrected in
   `4155430a1fe4ce1f9092b768ccdd1ee188eb4903` (the preserved Foundry commit
   `bd87dba`, cherry-picked unchanged). See the header-encoding section below.
2. **Leaked loopback fixtures.** `RecoveryLoopback.deinit` woke its accept
   thread with `shutdown(SHUT_RDWR)` on the listening socket. On Darwin that
   call fails with `ENOTCONN` and `accept()` stays blocked. Every fixture
   therefore kept its thread, listener and port for the rest of the process.
   A full parallel run creates about 2,300 fixtures. The macOS CI runner
   (`hw.ncpu: 3`, `hw.memsize: 7516192768`) allows
   `kern.num_taskthreads: 2048`. Past that ceiling a new fixture's accept
   thread cannot start, the request waits in the listen backlog, and
   URLSession times out with no response bytes (`NSURLErrorDomain -1001`,
   `_kCFStreamErrorCodeKey=-2102`). A local Mac allows 16,384 threads, so the
   same leak passes there. That is why every case after the ceiling failed
   on CI while the same tests passed locally. The fix gives the accept thread
   a wake pipe: it polls the listener and the pipe, and `deinit` closes the
   pipe's write end. The accept thread remains the only closer of the
   listener.
3. **Response delivery at headers.** Apple URLSession calls
   `didReceive(response:)` only after the first body byte or the end of the
   connection. `X-Content-Type-Options: nosniff` does not change this.
   `RecoveryCancellationTests.captureFailureIsTerminal` with phase `headers`
   held a header-only reply, so its headers observer never ran on Darwin; the
   attempt timed out, the retry waited behind the held connection, and the
   test ended `exhausted` instead of `captureFailed` (36 issues, six
   boundaries). On Apple platforms the fixture now holds after a one-byte
   body prefix. Linux keeps the header-only hold: FoundationNetworking
   delivers a byte that arrives with the headers even after the observer
   cancels, which counts as raw progress (run `39036519235` below). The
   assertions are unchanged.

The historical failing run is `39014529769` (source
`863d4ceb367981f6b808232eed2f75c346f33c0b`, before causes 1 to 3 were
corrected). Its macOS job ran 388 tests in 109 suites and failed with 11,226
issues after 1,770 seconds. It contains 226 request timeouts with the error
codes above; its header-dictionary mismatches are cause 1. The per-call trace
for cause 2 comes from the Mac reproductions below, not from that log.

Command: `gh api repos/svetzal/mojentic-sw/actions/jobs/117343759761/logs`.
Complete macOS job log SHA-256:
`0c07d890991b0d783362bb28b7037adf749d12930b48e56fcd64f9bc478f752b`.

#### Mac reproductions

Standalone probes ran on macOS 27.2 with Swift 6.4. Each was compiled with
`swiftc <probe>.swift -o <probe>` and run as `./<probe>`. Probe sources are
not committed; their SHA-256 values identify them. Log SHA-256 values cover
stdout followed by stderr.

| Probe (source SHA-256) | Result | Log SHA-256 |
| --- | --- | --- |
| Listener wake (`27d76b6013befa4765e9cff36b8838f8c9860db318187a08d02dd0ea30da1d3d`) | Exit 0. `shutdown(SHUT_RDWR)` on a listening socket returns -1, errno 57 (`ENOTCONN`); `accept()` is still blocked after 2 s. `close()` returns 0; `accept()` returns -1, errno 53. | `b5fa124532f4df130a0c3258f4f0585aeb71fa231c3b7b310ec2d30e404c6ab8` |
| Response timing (`169123b985560db7e5faf7346cf02d598381c765647b248e25db9800ab7c8a85`) | Exit 0. Headers with 0 body bytes, held 2 s: response delivered only at close (2.02 s), with or without `nosniff`. Headers with 1 body byte: response and byte delivered at once (0.00 s). | `2cf0f5b79d2fe3618d8a39fb3ed989b43496021c5a61e6532853771995be2ffc` |

The fixture leak was measured with one bounded sampling script (SHA-256
`44432c3e9fc6c82c623ef692a9e1d8b606cfaf25bbfb3ef3714402646a91915f`). It runs
`swift test --parallel --skip-build` once (default traits) and samples the
test process every 0.5 s with `ps -M` (threads) and
`lsof -a -p <pid> -iTCP -sTCP:LISTEN` (listeners).

| Tested commit | Result | Log SHA-256 |
| --- | --- | --- |
| `4155430a1fe4ce1f9092b768ccdd1ee188eb4903` (before the fix) | 389 tests, 110 suites, 36 issues (`captureFailureIsTerminal`, phase `headers`). Peak 2,378 threads and 2,325 listeners; last sample 2,336 threads and 2,325 listeners. | `ff15bb7ac35ac4e0a04f3f0471a601ab27cdb589a0b2732bf431b1620193507d` |
| `db0354d61d334cb943e5ef8cb8a78d5951131ab4` (after the fix) | 389 tests, 110 suites, 0 issues. Peak 1,391 threads and 1,295 listeners; last sample 33 threads and 1 listener. | `b4d217d356986d469e9cd7057c32376bff7d4da9301acdcbfee4754c56a3359a` |

The remaining peak is the fixtures that are alive at the same time early in a
parallel run. It is below the CI runner's 2,048-thread ceiling, but the margin
is about 650 threads. A suite that adds many concurrent loopback fixtures can
reach the ceiling again; the macOS job prints the runner's limits on each run.

## API comparison and migration

Baseline tag `v2.1.0` resolves to source commit
`618eb7b42ff2b74e6ff9bb6fd9f3c65373da2262` (annotated tag object
`f105662d7f453ad6bf36b8678d412d372cb27f6d`). The comparison target is
`Sources/` at `db0354d61d334cb943e5ef8cb8a78d5951131ab4`; `Sources/`,
`Package.swift` and `Package.resolved` are identical at
`4155430a1fe4ce1f9092b768ccdd1ee188eb4903`, `baed786` and `db0354d`.

Command (macOS 27.2, Swift 6.4):
`./scripts/with-gate-environment swift package --traits full diagnose-api-breaking-changes v2.1.0 --targets Mojentic`.
Exit 0: `No breaking changes detected in Mojentic`.
Combined stdout-then-stderr log SHA-256:
`179134af8edf25f8da6b4764b0f3121977a2d6f7365bd983a2614e4fbb942a62`.

On macOS the default build system completes the comparison. The Linux
attempts in the Foundry sandbox failed before comparison on a read-only global
Clang cache and used the native build system instead (table below); that
workaround is not needed here and changes no project configuration.

The compiler API comparison does not validate Codable vocabulary, reflection,
error delivery or recovery behavior. The October 12 contract authorizes those
public recovery guarantees. [CHANGELOG.md](CHANGELOG.md) documents their
migration: handle `RecoveryError`/`.recoveryFailure`, use closed provider and
operation types with the new serialized operation vocabulary, and explicitly
inspect raw evidence. Existing legacy entrypoints keep one-send behavior.
The coordinated major version also covers pending work in other ports and
parts 2 and 3; passing this Swift API comparison does not authorize publication.

| Earlier API diagnostic attempt (Linux, over `dd9bb07`) | Result | Log SHA-256 |
| --- | --- | --- |
| Default build system, default traits | Exit 1; read-only Clang cache, comparison not reached | `bace7d443679d9b7e99309921c4e3e8693a14a80c2277575435eb39a21b9c600` |
| Default build system, full traits, module-cache environment overrides | Exit 1; read-only Clang cache, comparison not reached | `4b10117fc107812f40ec0b41b4390a593f2ed79138eb1e0bc7478cfed97f268b` |
| `./scripts/with-gate-environment swift package --build-system native --scratch-path .build/api-native --traits full diagnose-api-breaking-changes v2.1.0 --targets Mojentic` | Exit 0; `No breaking changes detected in Mojentic` | `4689996735ba144934c9cffb7f78d7527281bb2cfcdabf980d47652de9b14115` |

## Part 2: native reasoning — local verification; external verification pending

Tested base: `37bfac0e478b3860c284ed1c70d7b5da7fba5436` plus this uncommitted
correction. No refs, dependencies, package versions, toolchain declaration or
publication state changed. The completed Darwin/API baseline was not repeated.
Rust's explicit profile validation and broker retention were inspected read-only
at `8ac38ea134af7816c6fdd02e07a420ed3be1a2f4`; the prototype is `67791b7`.
The authoritative reasoning source SHA-256 is
`0a40f3ad45c593bc779411021e45db569e73d3ecce86c99b201e7f8ebb656809`.
The initiative brief matches the recorded authorization hash above.

### Shared executable contract

[Native reasoning v1](Tests/MojenticTests/Fixtures/Contracts/native_reasoning_v1.json)
is an unchanged copy of `mojentic-ex/test/contracts/native_reasoning_v1.json`,
version **native-reasoning-v1**, SHA-256
`be212ff011125f1d0927e3a65a0d7cd87eedbf9f5ff69e803b4112a80ae6b1f6`.
Its control rows, reasoning, visible content, answer, call identity/arguments and
result drive `NativeReasoningContract` and the captured loopback HTTP responses.
The second simultaneous call derives from the contract call with a distinct ID.
No independent mock is used as provider compatibility evidence. Existing
`ReasoningHistory` and `LLMMessage` coverage is extended, not replaced.

Execute `./scripts/with-gate-environment swift test --traits full --skip-build --filter 'NativeReasoning|ReasoningHistory'` after the full-trait build. The same tests run in both
required test gates, including all provider traits. Tests inspect captured request
bodies, returned reasoning/content, tool results and session history, not counts
or schemas alone. The initial `NativeReasoningTests` HTTP probe failed because
the continuation lost reasoning and visible content (exit 1); with opt-in
retention and the broker correction it passed (exit 0). Expanded tests followed. A second real-HTTP probe, `cancelledBufferedResponseCannotReturnRetainedHistory`, failed on both providers (exit 1) when cancellation arrived during response tracing; the opt-in cancellation check corrected it (exit 0).

### Named-test map

| Binding behavior | Executable evidence |
| --- | --- |
| Six distinct controls; exact boolean/string types; omitted effort stays unknown; ordinary, structured, JSON, streamed tools and single-turn events, including retry | `NativeReasoningControlTests.exactContractControlsAcrossPublicBoundaries`: every shared control row across both local providers; actual first/retry HTTP bodies and separated response fields |
| Explicit caller-selected profiles and exact Qwen3.8 capabilities; no model-name inference | `explicitProfileAcceptsUnknownDefaultAndExactQwenEfforts`, `rejectsUnsupportedControlsBeforeDispatch`: arbitrary names accept selected supported controls; Qwen-like names cannot bypass rejection |
| Unsupported effort, retention and provider extensions fail before dispatch; shared-enum regression audit | `rejectsUnsupportedControlsBeforeDispatch`: ordinary, structured and both recovery stream APIs leave HTTP request capture empty for rejected controls; full-trait Anthropic cases; existing OpenAI/Anthropic legacy high/medium/low tests remain in full suite |
| Native history capability validation | `ReasoningHistoryConformanceTests.explicitProfileRejectsUnsupportedNativeHistoryBeforeHTTP`: existing populated reasoning history is rejected without HTTP |
| Completed ordinary and streamed multiple-tool continuity; outer-turn session retention; identities, order and separated results | `NativeReasoningContinuityTests.completedMultipleToolCallsAndSessionHistory`: both providers, ordinary and streams; entire role order, two calls and results, native fields in second and third HTTP requests; oMLX original call IDs and result linkage |
| Opt-in retention and oMLX preserve request | `retentionIsOptIn`, `completedMultipleToolCallsAndSessionHistory`, `NativeReasoningTests.completedToolHistoryCrossesHTTPBoundary`, `booleanControlAndRetentionPreserveOtherTemplateOptions`; exact `chat_template_kwargs.preserve_thinking`; forced server settings are outside this client guarantee |
| Cancellation after native delta excludes history and dispatch | `NativeReasoningExclusionTests.cancellationAfterNativeDeltaDoesNotRetainOrDispatch`: held real HTTP stream, observed native delta, cancellation, empty session history and unexecuted tool; `cancelledBufferedResponseCannotReturnRetainedHistory` pauses the I/O tracer after a real buffered response and excludes cancellation races before retained history returns |
| Errors and incomplete streams cannot manufacture native history | `incompleteStreamCannotBecomeRetainedHistory`, `failedContinuationNeverCommitsNativeHistory`: both providers; no final retained turn after EOF without completion or failed next request |
| Optional native history and legacy Codable records | Existing `legacyAndNilHistoryStayCompatible`, `defaultPolicyKeepsOneAttemptWithNilHistory`, `ReasoningHistoryTests`; added `legacyCodableRecordsLeaveReasoningUnknown` defaults absent retention to false without inventing effort or exchanges |
| Recovery accounting and existing iteration limits | Existing recovery/broker tests remain mandatory in both test gates; reasoning controls are validated before recovery creates a wire attempt and frozen bodies preserve controls/history across retry |

Retention adds one completed assistant turn with all tool calls and its native
reasoning, followed by ordered tool results; default legacy exchange construction
is preserved. `LLMResponse.retainedMessages` carries the completed exchanges to
ChatSession, which commits them only after success. With retention enabled,
oMLX's legacy parser requires a terminal marker and finish reason instead of
manufacturing completion at EOF. Recovery semantics are unchanged.

### Boundary sides and coordination finding

| Side | Tested revision and command | Verification result |
| --- | --- | --- |
| Swift gateway/provider adapters | `37bfac0e478b3860c284ed1c70d7b5da7fba5436` plus this uncommitted patch; targeted command above, same native-reasoning-v1 rows | Exit 0; captured HTTP controls, native response fields, errors and rejected dispatch |
| Swift broker/ChatSession consumers | Same base/patch, same command and artifact | Exit 0; contract-derived responses exercise completed ordinary/stream continuations and next user turn, plus exclusion cases |
| Elixir recorded adapter/consumer verification | Read-only `CONFORMANCE-3.0.0.md` at `df29a1c36f6b4b172b3ff352d40201d6583a9890` records tested base `ddb2217c8245b041a20fd25f34f5aa6fbfaee2ce` plus its part-2 patch; `scripts/verify-native-reasoning-contract` | Recorded exit 0, 182 named cases against the same contract; not rerun or claimed as a current paired verification in this task |
| Actual Ollama/oMLX server producers and external repository consumers | No tested server version/commit or paired verification command available | Missing; compatibility across those external boundaries remains unfinished |

Initiative finding `fnd_sw_native_reasoning_v1_external_verification` was recorded
with `foundry finding add` (exit 0). It requests separately authorized paired
verification of this exact set; no other repository was changed. Local fixture
verification cannot certify live server behavior or benchmark efficacy. The
publication hold remains and part 3 remains explicitly pending.

### Part-2 validation

Linux Swift 6.4, base `37bfac0e478b3860c284ed1c70d7b5da7fba5436` plus this
uncommitted patch. Every discovered `.hone-gates.json` gate ran through
`foundry capture --log-dir <scratch logs> -- <gate command>`. Hashes below cover
stdout bytes followed by stderr bytes. No evidence files or archives are added
to the repository; this record makes no evidence-retention claim.

The final process environment used `ulimit -S -n 65536`. The first full-trait
attempt at the wrapper's 8,192-descriptor minimum failed with `errno 24` opening
concurrent loopback sockets/pipes (415 tests, 182 issues). Raising the process
limit corrected the environment; no test was skipped and no recovery or fixture
semantics were changed. The earlier default-trait assertion expecting three
effort cases was updated to the authorized six values.

| Required command | Result | Log SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0; no violations | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0; zero violations in 218 files | `95ed5764d065b89ca116640282876dd99d16d10eb726ab8f9aa7300895d7d460` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0; release build | `5590d7a6b8a974856b1e2f200c3c5e45a1034ad1dd58e0301e03f4f2e7f59468` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 402 tests in 114 suites | `a54d22b4073a3e103bbcdeddbc315f325ebabfc150fac9eb77b1532c51edf60c` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 415 tests in 119 suites | `52f1042279c6ea93b0ea0fbc6bc514e0cf3e5b82fe14447d386c842f4a3528f0` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0; DocC archive generated with warnings as errors | `db4917625d89fc13473a8f44c4fffa31e89afd7aa525cc5889e1548c97204745` |

Final targeted contract verification: the command above passed (exit 0),
19 tests in 6 suites; log SHA-256
`7f70018d8c3cd76cbe521126aaf86c5a28165d9d71212bbd4fd61f90c52bddbc`.
The original rejecting/passing HTTP proof log SHA-256 values are respectively
`87ae8782c2f2cd14b58b3f2237c47c03970decbf3e6be1608fe206428dcd2994`
and `be0fd661cb7cc5a989a8037e6ccc1001233a00fb77df92e4f74a86069ef93bc1`.

CI on the tested base is green: [Validate, Test, and Publish run 39037846218](https://github.com/svetzal/mojentic-sw/actions/runs/39037846218)
and [Supply Chain run 39037846153](https://github.com/svetzal/mojentic-sw/actions/runs/39037846153).
Checked with `gh run list --repo svetzal/mojentic-sw --commit
37bfac0e478b3860c284ed1c70d7b5da7fba5436 --json
databaseId,name,conclusion,status,headSha --limit 10`. Both completed successfully;
the existing OSV CI scan covers the unchanged lockfile. These uncommitted changes
have no CI run yet. Local results do not claim macOS or Swift 6.1 execution for
this patch; those remain CI validation after Foundry finalization.


## Part 3: model metadata and request fidelity — pending

No metadata features are implemented by this correction. Context-window lookup,
client first-token timing, caller-only parameters and removal of `num_predict`
still require implementation, migration notes and executable conformance tests.

## Validation on main

### Local gates (macOS)

macOS 27.2, Swift 6.4. Tested commit
`db0354d61d334cb943e5ef8cb8a78d5951131ab4`: the gates ran on the working tree
that was committed unchanged as `db0354d`. Each command is a gate from
`.hone-gates.json`, run directly. SHA-256 values cover stdout bytes followed
by stderr bytes, with no inserted separator. The passing format command is
silent.

| Command | Result | Log SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0; no format diagnostics | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0; 210 files, 0 violations | `20f86aca7900ac958f1320390ab61b37ad3f1acf399637a08654aea4aaf5e56d` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0; release build | `9ca2385e9853e1df90a8dc7b719698c80f8d2a0d7161151b90909c5b337dbd79` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 389 tests, 110 suites, 0 issues | `f9fa21d57bc66f682a7d57ae0c3ff385d75d6e032881498c33a565fefcd75c77` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 402 tests, 115 suites, 0 issues | `cb43bae19c483eecb57f6a48b625d24939c465ee77fd3d46e51df1b4f138e4ae` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0; Mojentic DocC | `4cbf4c51025b33c1f0218eebe78688bd7633850e56d2536270a4bf2ae80ee6c9` |

### GitHub Actions

Each job log was fetched with
`gh api repos/svetzal/mojentic-sw/actions/jobs/<job ID>/logs`; the SHA-256
covers the complete downloaded log.

Run `39036822881`, tested commit `db0354d61d334cb943e5ef8cb8a78d5951131ab4`,
conclusion success:

| Job (job ID) | Result | Log SHA-256 |
| --- | --- | --- |
| macOS, Swift 6.4 (`117408256894`) | Success. Runner `hw.ncpu: 3`, `hw.memsize: 7516192768`, `kern.num_taskthreads: 2048`. Test: 389 tests, 110 suites. Test (all provider traits): 402 tests, 115 suites. Debug and release builds. | `31960e3568d5ef78b74ab4b2bc20e828cd2e8462ef7f7da3076bb2387c49eb1e` |
| Linux, Swift 6.4.1 (`117408256900`) | Success. 389 tests, 110 suites; 402 tests, 115 suites; DocC. | `472b89c53acaaa12ca815f6a42bd3c1d3d6f828dac392b80461dd993fed26620` |
| Linux minimum, Swift 6.1.3 (`117408257096`) | Success. 402 tests (all provider traits). | `13dec0e58ef18fc0b793d000d1a097b477ffffa860edb94613d4e51917964ab3` |
| swift-format on Linux (`117408256967`) | Success. | `a9a456f959a4041fb43588917fde5fedcf7680ed5fabf0f326b089945a393885` |
| SwiftLint 0.65.1 (`117408256798`) | Success. 210 files, 0 violations. | `5151d96332fdabb38bc0df6619998f5946989b754b6bcbec4225037ab68112bc` |

Run `39036519235`, tested commit `baed786edd18c58bfd36c50c931ac7d8efe92fa0`,
conclusion failure. It is the first run with the fixture fix and the one
that found the Linux prefix-byte behavior:

| Job (job ID) | Result | Log SHA-256 |
| --- | --- | --- |
| macOS, Swift 6.4 (`117407395763`) | Success. 389 tests, 110 suites; 402 tests, 115 suites. | `b05afecb8e874dfe35327f8abe53c0c235c2616670a3d37ed0a943ab47ddf668` |
| Linux, Swift 6.4.1 (`117407395920`) | Failure. 389 tests, 110 suites, 6 issues: `captureFailureIsTerminal` phase `headers`, lifecycle `rawBytes` 1 where 0 is expected, one per boundary. Corrected in `db0354d`. | `e3a6398e9d5ffb4b5ac16ce6b99b74526b8a0836993a9f6bd303ee10719ce713` |

## Header-encoding correction (Linux, Foundry)

Linux Swift 6.4, run by Foundry before this correction landed on `main` as
`4155430a1fe4ce1f9092b768ccdd1ee188eb4903`. Results apply to uncommitted
source over `dd9bb07e85287c403466499db41f517e516f6541`. SHA-256 values below cover
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

### Focused header-encoding proof

Command in both runs:
`./scripts/with-gate-environment swift test --filter RecoveryHeaderEncodingTests`.
The test assertions are identical. The negative control writes Latin-1 header
octets instead of UTF-8 through the real loopback socket; it fails on the exact
header bytes and missing captured response headers. The corrected run restores
the UTF-8 fixture and passes. This establishes sensitivity to real HTTP input
and correct local delivery, not reproduction or resolution of the historical
Darwin timeouts. The original Darwin header mismatch is established by the
inspected macOS log above. The Apple expectation passes on macOS CI in run
`39036822881` (see Validation on main).

| Probe | Result | Log SHA-256 (stdout then stderr) |
| --- | --- | --- |
| Rejecting fixture input | Exit 1; 1 test | `fdb6aacbadbf75f6262ebd302a251a938ca8fdfb53d5feb87f61734d1528d629` |
| Corrected fixture input | Exit 0; 1 test | `ace60399d287fafb1501f908455b30a5c4497276fabdad8d32d00a0a8b3882ef` |

The Swift test-source SHA-256 values Foundry tested are below.
`RecoveryLoopback.swift` changed afterwards in `baed786` (the listener wake).

| File (under `Tests/MojenticTests/Gateways`) | SHA-256 |
| --- | --- |
| `RecoveryHeaderEncodingTests.swift` | `6e64cfc855e25fd9053faa1306711064d65f5c3b224dc63cfce31d837e98be11` |
| `RecoveryLoopback.swift` | `e94e4c9bb5f6dc6f7c49b05910910cc8140620ef67a73e50ba0ee2aa95029f01` |
| `RecoveryStatusTestSupport.swift` | `161df7589b29053e3b522b8374b7c590a4ccfcb3bbcc797f2b4d056c75a1e895` |

## Verification scope and coordination

These corrections change the recovery test harness, its expectations, one
read-only CI diagnostic step and documentation. They do not change an
application or cross-repository runtime boundary. The tests exercise Swift's
real HTTP transport against a scripted provider fixture. They are not a shared
versioned executable provider/consumer contract set verified in another
repository; no such two-sided verification is claimed. The contract document
hashes identify the governing requirements, not an executable contract bundle.

Two platform transport behaviors are observations for the initiative, not
contract changes:

- On Apple platforms, a recovery attempt reports `headersReceived` and the
  `headers` wire event only when the first body byte arrives or the
  connection ends. A provider that sends headers and then stalls stays at
  phase `nil` until its first byte or the idle timeout.
- On FoundationNetworking, a body byte that arrives with the headers is
  delivered and counted as raw progress even after a headers capture failure
  cancels the attempt. The outcome stays `captureFailed`.

No versions, dependencies, recovery semantics or release artifacts change in
these corrections.
