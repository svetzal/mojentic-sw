# Swift 3.0.0 conformance baseline

Status: the preserved cycle-8 implementation at `0895693a826e07c69a85e4d9543f6a0f8b5f7ee3`
is retained. The owner has resolved Anthropic initial-input classification.
The final readiness assessment below supersedes earlier open-decision and
external-counterpart requirements. Historical gate and CI results remain scoped
to their recorded source; the API comparison against `v2.1.0` covered only the
recovery baseline. Final landed-source CI remains a separate release condition.

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

## Part 2: native reasoning — local library verification

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
| Actual Ollama/oMLX server producers and external repository consumers | No tested server version/commit or paired verification command available | Historical external verification was not performed; it is not a library distribution gate under the owner rule below |

The earlier finding `fnd_sw_native_reasoning_v1_external_verification` is
superseded as a library readiness requirement by the owner's self-validation
rule. Swift validates its public API and packaged artifact locally; dependents
verify adoption after publication. Local fixtures do not certify live server
deployments. No other repository was changed; the publication hold remains.

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


## Part 3 section 1: context-window discovery — historical local verification

The original section-1 correction described here predates the request-fidelity
correction recorded below. That later record supersedes the original scope and
verification gaps.

This correction starts at Swift `a4738d7c87cc7608e5f7e3ddf9638a76148c65d0`.
The binding owner brief SHA-256 is
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
The inspected coordinating `MODEL-METADATA-2026-10.md` SHA-256 is
`d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c`;
only section 1 is implemented here. Recovery, native reasoning, request defaults,
dependencies, toolchain minimum, versions, refs and publication state are preserved.

The unchanged executable [context-window-v1](Tests/MojenticTests/Fixtures/Contracts/context_window_v1.json)
was copied from Elixir `df29a1c36f6b4b172b3ff352d40201d6583a9890`.
Its SHA-256 is `9327502962112a020bafb46c6a677366df732f5a29cd44c92f17e8f632281395`.
The contract's embedded `source_sha256` identifies its original specification
snapshot, not the current coordinating document above. No contract row was edited.
The Swift [verification manifest](Tests/MojenticTests/Fixtures/Contracts/context_window_v1.manifest.sha256)
identifies the runtime, package, transport, fixture and test sources for this
uncommitted candidate. Its SHA-256 is
`6aa597d308356ef7f57ce78b79947161317bd2ef51934d8316c37c051e86d699`.

### Executable assertions and supported versions

`ContextWindowContractTests.sharedProviderAndConsumerRows` runs every provider row
below twice: direct metadata consumption and consumption through the pure
`effectiveContextWindow` helper. The scripted TCP responses and expectations both
come from that row. Production `HTTPClient` and `URLSession` execute every request;
no independently authored gateway mock stands in for the provider. Each invocation
asserts the exact model body (Ollama), HTTP method, path, configured host/port,
configured headers, bearer key or absence, empty GET body, capacity, field provenance,
optional model parameter, and typed error outcome. HTTP errors also assert exact
status and raw body. The exact requested identity is `exact-model` in every row;
`exact-selection` additionally distinguishes `exact-model-extra` and `different`.
Positive integer validation rejects booleans, fractions, strings, null and
nonpositive values. Malformed JSON and top-level nonobjects are errors, including
the encoded JSON-object string regression. No second JSON decode is permitted.

| Provider | Contract case identity | Asserted outcome |
| --- | --- | --- |
| ollama | `qwen3_5` | 262144; `model_info.qwen3_5.context_length`; model_num_ctx=absent |
| ollama | `qwen4_exp` | 262144; `model_info.qwen4_exp.context_length`; model_num_ctx=absent |
| ollama | `model-num-ctx` | 262144; `model_info.qwen4_exp.context_length`; model_num_ctx=32768 |
| ollama | `whitespace-num-ctx` | 8192; `model_info.qwen3_5.context_length`; model_num_ctx=16384 |
| ollama | `missing-info` | not advertised |
| ollama | `no-matching-key` | not advertised |
| ollama | `no-architecture-from-num-ctx` | not advertised |
| ollama | `invalid-window-0` | decoding error |
| ollama | `invalid-window--1` | decoding error |
| ollama | `invalid-window-1.5` | decoding error |
| ollama | `invalid-window-8192` | decoding error |
| ollama | `invalid-window-True` | decoding error |
| ollama | `invalid-window-None` | decoding error |
| ollama | `invalid-num-ctx-0` | decoding error |
| ollama | `invalid-num-ctx--1` | decoding error |
| ollama | `invalid-num-ctx-1.5` | decoding error |
| ollama | `invalid-num-ctx-8192junk` | decoding error |
| ollama | `invalid-num-ctx-` | decoding error |
| ollama | `invalid-num-ctx-8192 extra` | decoding error |
| ollama | `info-list` | decoding error |
| ollama | `parameters-list` | decoding error |
| omlx | `exact-selection` | 262144; `max_model_len`; model_num_ctx=absent |
| omlx | `no-model` | not advertised |
| omlx | `no-field` | not advertised |
| omlx | `invalid-window-0` | decoding error |
| omlx | `invalid-window--1` | decoding error |
| omlx | `invalid-window-1.5` | decoding error |
| omlx | `invalid-window-8192` | decoding error |
| omlx | `invalid-window-True` | decoding error |
| omlx | `invalid-window-None` | decoding error |
| omlx | `missing-data` | decoding error |
| omlx | `data-object` | decoding error |
| omlx | `bad-entry` | decoding error |
| omlx | `missing-id` | decoding error |
| ollama | `malformed-{` | decoding error |
| ollama | `malformed-[]` | decoding error |
| ollama | `malformed-null` | decoding error |
| ollama | `malformed-42` | decoding error |
| ollama | `malformed-"text"` | decoding error |
| ollama | `http-401` | HTTP 401 with exact response body |
| ollama | `http-404` | HTTP 404 with exact response body |
| ollama | `http-418` | HTTP 418 with exact response body |
| ollama | `non-200-success` | 8192; `model_info.qwen3_5.context_length`; model_num_ctx=absent |
| omlx | `malformed-{` | decoding error |
| omlx | `malformed-[]` | decoding error |
| omlx | `malformed-null` | decoding error |
| omlx | `malformed-42` | decoding error |
| omlx | `malformed-"text"` | decoding error |
| omlx | `http-401` | HTTP 401 with exact response body |
| omlx | `http-404` | HTTP 404 with exact response body |
| omlx | `http-418` | HTTP 418 with exact response body |
| omlx | `non-200-success` | 8192; `max_model_len`; model_num_ctx=absent |
| omlx | `exact-selection-without-api-key` | 262144; `max_model_len`; model_num_ctx=absent |
| ollama | `reject-json-string-object` | decoding error |

`transportFailureIsAnError` additionally exercises a real truncated response for
Ollama and oMLX and requires a transport error. `exactSelectionThroughHTTP` is the
initial behavioral failure/pass probe: the legacy nil default failed the capacity,
GET path and authentication assertions; the implemented production boundary passed.

`registryRowsNeverRequestHTTP` verifies exact identities `gpt-5.4` (1,050,000 tokens,
`registry` provenance), `gpt-5.4-unknown`, `o1-custom`, and `completely-unknown`
(all unadvertised) against the same `registry_cases`. It asserts zero HTTP requests.
Pattern inference in existing completion shaping remains available and unchanged.
`legacyGatewayHasNoWindow` uses an unchanged pre-metadata protocol conformance and
requires nil, covering the contract's supported legacy callback version alongside
the new optional 3.0 metadata API.

`effectiveRows` executes the unchanged `effective_cases` in order:

| Advertised | Model num_ctx | Caller num_ctx | Expected |
| --- | --- | --- | --- |
| unknown | absent | absent | unknown |
| unknown | absent | 8192 | unknown |
| 262144 | absent | absent | 262144 |
| 262144 | 32768 | absent | 32768 |
| 262144 | 32768 | 8192 | 8192 |
| 262144 | 32768 | 65536 | 65536 |
| 262144 | 32768 | 524288 | 262144 |
| 8192 | 16384 | absent | 8192 |

### Completion invariance and incompatible lookup row

`ContextWindowJourneyTests.discoveryPreservesCompletion` executes all combinations
of exact same-model `exact-model` (Ollama/oMLX) or `gpt-4o` (OpenAI) with `ordinary`,
`json`, `structured`, `stream`, and `events`. Production HTTP captures assert exact
JSON values before/after discovery, identical header lines irrespective of order,
model identity, response content/decoded value, stream flag, temperature 1,
max_tokens/num_predict 16,384 and Ollama num_ctx 32,768. OpenAI discovery adds no
HTTP request; Ollama/oMLX insert only their metadata request. No completion limit
is updated from advertised capacity.

The original cycle proved only semantic equivalence. This correction closes
that gap: `ContextWindowJourneyTests.discoveryPreservesCompletion` directly
compares complete, unmodified captured HTTP body `Data`, with the exact same
model identifier before and after discovery. Production HTTPClient and
URLSession serve all three providers, five entry points and both default and
explicit configurations (30 journeys). Only the headers' line order is ignored.
The rejecting probe failed all 15 original journeys; sorted-key HTTP encoding
passed the same assertions. No normalized JSON substitutes for the byte check.

`configuredLookupKeepsExistingSwiftOrder` executes all three unchanged
`lookup_cases` through configured HTTP, asserting paths, headers and empty GET
bodies. oMLX and OpenAI match the contract's `[a, b]`. **The Ollama lookup row is
incompatible:** it specifies `[b, a]`, while Swift's established implementation
sorts `[a, b]`. The test explicitly asserts both the contract's expectation and
the differing Swift result. Neither contract nor existing ordering is changed;
no shared conformance is claimed for that row. This is a coordination gap.

### Gate resource capacity

The new metadata suites use Swift Testing's `.serialized` trait to bound their
own socket usage without dropping any row. The full-traits matrix still exhausted
the existing 8,192-descriptor minimum (`socket`/`pipe` errno 24), producing downstream
recovery assertion failures. `scripts/with-gate-environment` now provisions 16,384
instead. All gate commands are unchanged; no recovery implementation, recovery
fixture or recovery assertion was modified. The complete gate set was restarted
after this environment correction.

### Counterpart evidence and remaining initiative work

| Side | Tested identity and command | Result and limits |
| --- | --- | --- |
| Swift production adapters and local metadata consumers | Base `a4738d7` plus the Swift manifest above; `scripts/verify-context-window-contract` | Runs the shared rows, registry, pure helper, legacy conformer, configured lookup and completion journeys. See current gate results below. |
| Elixir recorded production adapter/consumer verification | Read-only conformance record at `df29a1c36f6b4b172b3ff352d40201d6583a9890`, cycle 12: base `35013e921793710e344a708fdfea209248d4fd8e` plus manifest `407e4a0e7acec1c04dfe8d22b7e55a9722dc4e59182ce56c69f0cb81db070434`; `scripts/verify-context-window-contract` | Recorded exit 0, 233 tests, same contract hash. The current checkout is clean and `sha256sum --check test/contracts/context_window_v1.manifest.sha256` was rerun read-only here: exit 0, all entries match. Elixir tests were not rerun in this Swift-only task. |
| Actual Ollama/oMLX server producers | No tested server revision/version or shared verification command available | No live-server certification claimed; not a library distribution prerequisite. |
| External application consumers | No tested application revision or paired command available | Dependents verify when adopting the published package; not required against unreleased Swift. |

The counterpart record is historical provenance for reused fixtures. Under
the owner's library self-validation rule, Swift does not require Elixir's
executable snapshot or a dependent to validate an unreleased Swift package.
The existing Ollama list-order discrepancy remains a coordination item;
this correction preserves that unrelated API behavior. Request fidelity and
raw-byte discovery acceptance are complete locally; first-token timing and
whole-release readiness remain pending. The publication hold remains.


### Current correction validation (Linux Swift 6.4)

Tested revision is `a4738d7c87cc7608e5f7e3ddf9638a76148c65d0` plus the
uncommitted runtime/test candidate identified by manifest
`6aa597d308356ef7f57ce78b79947161317bd2ef51934d8316c37c051e86d699`.
All commands below ran through Foundry capture after the resource correction;
all six required gates in the only repository `.hone-gates.json` passed. The
contract tests run automatically in both test gates. Logs remain execution
evidence, not package sources. Digests cover stdout bytes followed by stderr bytes.

| Command | Result | Log SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | strict format, exit 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | strict lint, zero violations, exit 0 | `be556036d70e63f996fe83139c4f3a70d693c1e3691ee8dfca34d517bc73bc71` |
| `./scripts/with-gate-environment swift build -c release` | release build, exit 0 | `7fe471575fa4f63e4e78fcd865ab0627c6d1a520c766da175319658879305858` |
| `scripts/verify-context-window-contract` | 12 tests; every named shared row and journey, exit 0 | `8bc43976bb88dfa0a2eed07085638fad7e58d67e2831c3ee5b77f797280c5885` |
| `./scripts/with-gate-environment swift test --parallel` | 410 tests, 116 suites, exit 0 | `e03fd3a9735a9b79402837baf3f0c1d74949a006a7b8571a11bfdb6865640389` |
| `./scripts/with-gate-environment swift test --traits full` | 423 tests, 121 suites, exit 0 | `21948cb36eded09720f2b4fb1557d2aec8d08bd83d7080038bedb12c4f355182` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Mojentic DocC, warnings as errors, exit 0 | `d4d85b9ed82d1139ba0a97d9e34c0a3f9d786bc0f462c77296444bd9b89a2ba4` |

The initial behavioral probe ran
`./scripts/with-gate-environment swift test --filter ContextWindowContractTests`
with unchanged assertions: the legacy metadata default rejected exact capacity,
GET route and authentication (exit 1); the implemented production HTTP boundary
passed (exit 0). Rejecting log SHA-256:
`fd94bb3e43aecce967ba64480ae81b4270e07d60ba1441b5be1ef2d6b9fe8ad8`;
corrected log SHA-256:
`3ad15d257f5511a3fe1a6fadb8b38f91d68ebe38f56a09216a12ff8d7e28b893`.
JSON field types, observed exit codes and nonempty log files were validated.
The historical raw-byte probe failed; the request-fidelity correction below closes that gap.

Initiative finding `mojentic-sw-context-window-v1-final-evidence-a4738d7`
supersedes the earlier candidate identity in
`mojentic-sw-context-window-v1-gaps-a4738d7`, preserving the historical coordination findings. The correction below supersedes
the raw-byte and external-verification requirements; no release readiness is claimed. Changes remain
uncommitted for Foundry finalization.

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


## Part 3 request fidelity correction — 2026-10-17

Tested revision: `aa1a7c18e69db4586b5fdac562d9421d049915d5` plus the
uncommitted worktree correction. No refs, dependencies, toolchain declarations,
version or publication state changed. This objective implements sections 3.2–3.6
and closes discovery's outstanding raw-byte criterion; timing is excluded.

### Characterization and migration

At the base revision, public temperature/maxTokens were numeric defaults
1.0/16384, numCtx defaulted to 32768, and legacy Codable required numeric fields.
ChatSession passed maxTokens directly as its reservation. Gateways injected
these defaults; OpenAI omitted fixed temperature and silently dropped unsupported
effort, while Anthropic clamped the output limit and derived thinking from it.
The initial real-HTTP byte probe exposed varying encoder key order before
migration. Existing populated-field and native-reasoning tests are retained.

Now unset fields stay omitted; legacy numeric records retain their values,
absent/null request fields decode as nil, and sessions reserve explicit output
limits or zero. Anthropic resolves an unset limit once from exact output metadata
or 4096 and derives the existing thinking budget from that result. Its output
registry deliberately distinguishes documented limits from coarse capability
patterns. Sources for exact limits:
[Sonnet 4.5](https://platform.claude.com/docs/en/models/sonnet-4-5/overview),
[Haiku 4.5](https://platform.claude.com/docs/en/models/haiku-4-5/overview),
[Opus 4.7](https://platform.claude.com/docs/en/models/opus-4-7/overview).
Unregistered output metadata, including a capability pattern match, uses 4096.

### Executable coverage and distribution rule

The owner rule makes this library self-validating through public APIs, fixtures
and a detached SwiftPM source archive consumed by a fresh package. It does not
require dependents to adopt an unreleased library or another port to verify a
Swift executable snapshot. Publication still requires a fresh registry install.
No running application boundary in another authorized repository changed here.

| Decision | Executable evidence |
| --- | --- |
| Default and explicit fields; exact model and relevant headers; raw bytes across ordinary/JSON/structured/stream/events | `ContextWindowJourneyTests.discoveryPreservesCompletion`: 30 production HTTP journeys, no substituted HTTPClient |
| Optional defaults and explicit Codable round trips | `CompletionConfigTests` |
| Legacy numeric, missing and null Codable fields | `RequestFidelityTests.legacyAndSparseCodableConfigurations` |
| Fixed temperature, omitted temperature, dropped effort and provider-specific token-limit names | `fixedTemperatureUsesOnlyAllowedValue`, `forbiddenTemperatureIsOmitted`, `unsupportedReasoningIsDropped`; versioned request rows, captured HTTP |
| Anthropic required default/explicit limits, exact metadata versus capability patterns and derived thinking | `anthropicRequiredLimitAndThinking`; versioned Anthropic rows |
| ChatSession reservation and request coupling | `sessionReservesOnlyExplicitOutputLimit`: actual history trimming and subsequent HTTP payload with unset/explicit limit |
| Packaged public API and provider verification | `scripts/verify-packaged-request-fidelity`: detached source archive, fresh SwiftPM consumer, production URLSession and a fixture-verifying HTTP provider using the same request-fidelity-v1 rows |

Responses for the HTTP test doubles and packaged provider come directly from
the versioned contract, rather than independently authored mocks.
The scripted provider verifies declared contract cases, optional-field semantics
and exact model identities; it does not claim verification of a live vendor
deployment. Existing context-window-v1 and native-reasoning-v1 suites retain
their versioned errors, legacy compatibility and request/response behavior.
All Swift tests, including contract tests, execute in the required test gates.
The packaged probe is an additional distribution check, without publication.

### Contract and implementation identities

Coordinating document read at `mojentic-unify@ef9339c6a9682ed5f060bd690b738f6b8eea1d2d`.
Executable sets are retained inside this repository; request-fidelity-v1 adds Swift
wire examples without changing the governing contract. Hashes cover exact file bytes.

| Identity | SHA-256 |
| --- | --- |
| MODEL-METADATA-2026-10.md | `d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c` |
| context-window-v1 | `9327502962112a020bafb46c6a677366df732f5a29cd44c92f17e8f632281395` |
| native-reasoning-v1 | `be212ff011125f1d0927e3a65a0d7cd87eedbf9f5ff69e803b4112a80ae6b1f6` |
| request-fidelity-v1 | `39166b8c852d66f496ff63794b72b8a8bc111e80b1f73cdd620c3c0c036c93f5` |
| Swift source/test/verification manifest | `4727fef7d5ff53585c888f5ca2c7665b64f51a49189739b9f00b61d59d934b53` |

The source manifest at `Tests/MojenticTests/Fixtures/Contracts/request_fidelity_v1.swift.sha256`
identifies the uncommitted Swift implementation and verification programs.

### Final correction verification

All commands below ran on Linux Swift 6.4 through Foundry capture, against the
base revision plus the source manifest above. Every exit code is zero. Log
digests cover complete stdout followed by stderr; logs are execution evidence,
not package files. No current macOS CI or live vendor deployment is claimed.

The first complete pass passed all six gates, then the context verifier rejected
nine stale source checksums in its provenance manifest. Only those checksums
were refreshed; the context-window-v1 executable fixture and its hash are
unchanged. A complete gate and contract rerun then passed. The refreshed context
source manifest SHA-256 is
`8307f3fe645183e6709c3c979cd26228f10f6bf75b57132c5c7992760c9f1dd7`.

| Command | Result | Log SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0 | `58c7b6a6dd8c3f703cb3f29f2b9ad70d74fcacb35fa4cc763a4e8550e5d40601` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0 | `341eddfb003252fb09e471a5a1ceff9e40bd52924e1009382ba5afb143b81bcc` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 415 tests in 117 suites | `633a7b7ea6dd3907ce274eeaee2c012ada87b688548eebab908a5d3a6f706e31` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 429 tests in 122 suites | `d2370437a1196b3e859b7bc68ca0bbc7ab6cda9e960225f70977a281ae2f272c` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0; DocC, warnings as errors | `1de4ddf25cd22f11049ea7d8ea701d9b1dac10bca0e4f3dde2bb3c9ba29afe0c` |
| `scripts/verify-context-window-contract --traits full` | Exit 0; 12 tests in 4 suites | `cc7dff4e3391fa0fc298a3efbe238bb823caa263404f11765d5fb174ec1f6157` |
| `scripts/verify-request-fidelity-contract` | Exit 0; 12 tests in 3 suites | `d7394e8e005be2121c8bd9b839550e0835b5b5549ab5f6cc5f2e4e2283343857` |
| `./scripts/with-gate-environment swift test --traits full --filter 'NativeReasoning\|ReasoningHistory'` | Exit 0; 19 tests in 6 suites | `871d9648872f80707e3ae11bf68605a6efdc339844200f874118af5aeee949a6` |
| `scripts/verify-packaged-request-fidelity` | Exit 0; fresh consumer and scripted provider, same 6 request-fidelity-v1 rows | `f1934d8034264619221ebcaf625e2eea4a2953e11f8ef9a37c16656b8a58f486` |
| `osv-scanner scan source --lockfile=Package.resolved` | Exit 0; no issues found | `ab6a34c64255a37fac7c6d9bb4349803a48b64f8802efc24d8b1105dcab85b72` |

The packaged consumer and its fixture-verifying HTTP provider execute the same
request-fidelity-v1 rows from the tested worktree. Both sides pass in the same
command above; these are library self-validation, not another repository's
running application. Published-registry installation remains a release-stage
check under the existing publication hold.

### Retained behavioral byte proof

The same command ran in both probes:
`./scripts/with-gate-environment swift test --filter ContextWindowJourneyTests.discoveryPreservesCompletion`.
The rejecting run exercised production HTTP with the unsorted encoder and failed
all 15 same-model raw-body comparisons. Sorted-key production encoding passed
the unchanged test. The final suite additionally runs both default and explicit
configs for all routes (30 journeys). Body bytes are never normalized or masked.

| Probe | Observed exit | Complete log SHA-256 |
| --- | --- | --- |
| rejecting | 1 | `69a77a10d8556bb5b3dc8202bbaceec76b8f37b4a53d78bdddba478efc86d27a` |
| corrected | 0 | `6d8d39477837af8a80fdfecd246d42c7387b6079dec17594deeca3b214011a76` |

The behavioral proof JSON's required field types, observed exit codes and
nonempty log files were checked. Source and fixture manifests match the final
worktree. The existing Ollama lookup-order discrepancy remains recorded for
coordination; no ordering or contract changes were made locally. First-token
timing remains pending. Changes are uncommitted for Foundry; publication remains
on hold.

## Residual request-fidelity acceptance correction — October 17, 2026

This record supersedes the request-fidelity evidence above for the final source
in this correction. Tested base: `9139e35aacff64e5e11c846e19236c13978b5a2d`, plus
the uncommitted source identified below. The initiative brief was read and its
SHA-256 verified as
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
Only Swift's exact Anthropic output metadata and its acceptance verification
changed. Recovery, other reasoning behavior, dependencies, tools version 6.1,
package versions, refs and publication state are preserved. No Darwin work or
first-token timing is claimed; publication remains on hold.

### Contract and authoritative limit provenance

The existing `request-fidelity-v1` mechanism is extended additively as revision
`registered-output-limits-2026-10-17`. Existing cases and expectations remain;
new named rows cover all registered Anthropic IDs, supported exact dated aliases,
and unknown lookalikes. Both local URLSession tests and the fresh packaged
consumer/provider use this identical executable fixture. Its OpenAI rows also
name the required warning text. The verifier checks fixture and implementation
manifests before execution. No dependent or external counterpart verification
is required by the owner's library-distribution rule.

Limits follow Anthropic's historical
[model comparison](https://docs.anthropic.com/en/docs/about-claude/models/all-models):
Claude 3 Haiku/Opus 4096, Claude 3.5 Haiku/Sonnet 8192, Claude 3.7 Sonnet 64000.
That primary URL now redirects to the current overview; this correction retains
legacy-model limits, rather than substituting replacement-model limits. The
newer exact entries retain the base's authoritative specifications:
[Sonnet 4.5](https://platform.claude.com/docs/en/models/sonnet-4-5/overview),
[Haiku 4.5](https://platform.claude.com/docs/en/models/haiku-4-5/overview), and
[Opus 4.7](https://platform.claude.com/docs/en/models/opus-4-7/overview).
Limits are standard synchronous API maxima, without beta opt-ins. These local
checks verify request behavior against the pinned expectations; they do not
claim live access to retired Anthropic endpoints.

### Named acceptance behavior

- `RequestFidelityTests.documentedLegacyOutputLimit`: exact model identifier,
  omitted and explicit limits for `claude-3-7-sonnet-latest` and
  `claude-3-5-sonnet-20241022`, including the 3.7 thinking budget.
- `RequestFidelityTests.anthropicRequiredLimitAndThinking`: every row below,
  production URLSession, exact requested model, documented omitted maximum,
  explicit 2048 (distinct from every default), and thinking budget
  `max(1024, resolvedLimit / 4)` or omitted `thinking` for unsupported models.
- `RequestFidelityTests.anthropicContractCoversRegisteredModels`: fails if any
  registry-listed model lacks an executable contract row.
- `RequestFidelityTests.unsupportedReasoningIsDropped`: both `gpt-4o` default
  and explicit requests omit `reasoning_effort` and emit the contract's exact
  diagnostic with level `warning` and label `mojentic.gateway.openai`.
  A task-scoped capture observes the production swift-log handler.
- `scripts/verify-packaged-request-fidelity`: detached source archive, fresh
  SwiftPM consumer with full provider traits, and real HTTP provider. The
  provider verifies every model and request field against the same fixture;
  the consumer verifies the public response and actual warning output. Both
  print identifiable per-case results. Existing six OpenAI cases still pass:
  `openai/{gpt-4o,o3,gpt-4o-search-preview}/{default,explicit}`.

Each Anthropic row below passed `/default` and `/explicit` on both the local
URLSession side and packaged consumer/provider side. The explicit output limit
is 2048 throughout; its thinking budget is 1024 when supported.

| Case ID (prefix `anthropic/`) | Default output limit | Default thinking budget | Local URLSession | Packaged consumer + provider |
| --- | --- | --- | --- | --- |
| `claude-sonnet-4-5` | 64000 | 16000 | Pass, both cases | Pass, both cases |
| `claude-sonnet-4-5-20250929` | 64000 | 16000 | Pass, both cases | Pass, both cases |
| `claude-haiku-4-5` | 64000 | omitted | Pass, both cases | Pass, both cases |
| `claude-opus-4-7` | 128000 | 32000 | Pass, both cases | Pass, both cases |
| `unknown-sonnet-4` | 4096 | 1024 | Pass, both cases | Pass, both cases |
| `unregistered` | 4096 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-haiku-20240307` | 4096 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-5-haiku-20241022` | 8192 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-5-haiku-latest` | 8192 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-5-sonnet-20240620` | 8192 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-5-sonnet-20241022` | 8192 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-5-sonnet-latest` | 8192 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-opus-20240229` | 4096 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-opus-latest` | 4096 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-7-sonnet-latest` | 64000 | 16000 | Pass, both cases | Pass, both cases |
| `claude-haiku-4-5-20251001` | 64000 | omitted | Pass, both cases | Pass, both cases |
| `claude-3-7-sonnet-unregistered` | 4096 | 1024 | Pass, both cases | Pass, both cases |
| `claude-3-7-sonnet-20250219` | 64000 | 16000 | Pass, both cases | Pass, both cases |

### Final source and contract identities

All following commands ran against the tested base plus the source identified
by these manifests. The source manifest includes the changed registry, public
API tests, warning capture, verifier programs, DocC page and unchanged package
manifest/lockfile. The context manifest refresh changes only source provenance;
its executable fixture is unchanged. Native reasoning and recovery expectations
are unchanged.

| Artifact | SHA-256 |
| --- | --- |
| `Tests/MojenticTests/Fixtures/Contracts/request_fidelity_v1.json` | `369a944ecbd8426a69dd8b299d9cf3718393b38b129ac854f2424dcf0d72e3d5` |
| `Tests/MojenticTests/Fixtures/Contracts/request_fidelity_v1.manifest.sha256` | `49b59bb55db8c1414fa9f821ab16782162a8659a5343dfb72bdabca8de12f1d1` |
| `Tests/MojenticTests/Fixtures/Contracts/request_fidelity_v1.swift.sha256` | `d51be4ff634bea73518b64f3e30791e44c29412da0fd977a03374b7226c2dc77` |
| `Tests/MojenticTests/Fixtures/Contracts/context_window_v1.json` | `9327502962112a020bafb46c6a677366df732f5a29cd44c92f17e8f632281395` |
| `Tests/MojenticTests/Fixtures/Contracts/context_window_v1.manifest.sha256` | `9052f2da98f7edf5e30db1935a661a9c95f81ae4a3b1660d91a14cc06c9f94d9` |
| `Tests/MojenticTests/Fixtures/Contracts/native_reasoning_v1.json` | `be212ff011125f1d0927e3a65a0d7cd87eedbf9f5ff69e803b4112a80ae6b1f6` |
| `Sources/Mojentic/LLM/Gateways/AnthropicModelRegistry.swift` | `c68a653e4cfefe81f908f679ce5d197121c30acc9c5dcbdcb6e71f2001784a4f` |
| `Tests/MojenticTests/Gateways/RequestFidelityTests.swift` | `c03416478ad8a776ff7d9562993aa34a7e34df4a5799c8a36de603158fb014b8` |
| `Tests/MojenticTests/Gateways/RequestFidelityLogCapture.swift` | `9f540acc93a063d174e75ff16a362689b4cf7c6ee3f05ccb470e99afb1264e5b` |

The inspected governing `MODEL-METADATA-2026-10.md` SHA-256 is
`d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c`.

### Commands and observed results

All six `.hone-gates.json` commands and the additional contract, distribution
and security checks passed on Linux Swift 6.4. Combined log hashes cover complete
stdout followed by stderr. The packaged verifier's consumer and provider each
passed every case listed above and both unsupported-model warning checks. This
is fresh archive consumption; published-registry installation remains a release
step under the existing hold.

| Command | Result | Complete log SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0 | `f89412292a7613b69b40784596bd99d61b3c8ba768d4595c970934b4340301bd` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0 | `4fcb28b0793662a682bfcba0e3dbde95782676d864502348350a72e9511051fd` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 415 tests in 117 suites | `a331dfd58a3a2f5287993f476720fcb11e8691ab78c352f1aa559029c9ddc1ce` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 431 tests in 122 suites | `6e8fa63e90f182c280ad65d464e5f49e004114ead73531fb6fee0393b36ac5db` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0 | `8d2f3f945900202c49dbefd649c1753678a05ac4f3eab349ca662755c8776570` |
| `scripts/verify-request-fidelity-contract` | Exit 0; 14 tests in 3 suites | `d88944a6eade27dae508ed8ff51b43241230a19051ed7bd02789c2f2cb778f2c` |
| `scripts/verify-context-window-contract --traits full` | Exit 0; 12 tests in 4 suites | `c92306be4044a681f0d2b3bfa2a535fb0953711c24eca673b5e633c574f7ec73` |
| `./scripts/with-gate-environment swift test --traits full --filter 'Recovery\|NativeReasoning\|ReasoningHistory'` | Exit 0; 154 tests in 59 suites | `d5d5a6f6eeb66980657df58d9b27f6ae4256584c055e14d52b449a8efd188d1f` |
| `scripts/verify-packaged-request-fidelity` | Exit 0; all 42 named cases, both sides, plus warnings | `3b60859fafe867c187ad35d7fbf17415260447cad0a5d39d70effb3d4ebf7b8d` |
| `osv-scanner scan source --lockfile=Package.resolved` | Exit 0; no issues found | `c61b17d749709ceda784f22942aac9d1d2899879fa7f23c3f4dd0b83949211e6` |

### Rejecting and corrected boundary probes

Before expanding fixtures or documentation, the same production URLSession
command ran against the missing metadata and then the correction:
`./scripts/with-gate-environment swift test --traits full --filter RequestFidelityTests.documentedLegacyOutputLimit`.
The rejecting result was exit 1: Claude 3.7 sent 4096 instead of 64000 and
budget 1024 instead of 16000; Claude 3.5 sent 4096 instead of 8192. Explicit
limits already passed. The corrected run exited 0 for the unchanged four
request cases. Later full contract runs cover the final source manifest above.

| Probe | Exit code | Complete log SHA-256 |
| --- | --- | --- |
| Missing metadata | 1 | `9f441ae296be7cd89cef6aedfb814fe5ffd71e67fd0c792bbd83339dd2198bc0` |
| Corrected metadata | 0 | `8e31bcdc451922072db4b5156378e9c1bfe4153903cc2c02ce2102b7cb1eba0e` |
| Warning suppressed in production | 1 | `9bfcac05d59c9e23df81b2363f82841c16f857f83c39a32a3ef2f73962d8fb34` |
| Production warning restored | 0 | `3c89aac0165bf96b0b41fd11e3ad5614a5e36760241a6cd9cd9cd12fbfe6e233` |

The warning mutation used
`./scripts/with-gate-environment swift test --traits full --filter RequestFidelityTests.unsupportedReasoningIsDropped`.
Suppressing only the actual gateway warning yielded zero captured warnings and
one failed warning assertion; payload assertions still passed. Restoring the
warning passed the same test. The mutation was removed; `OpenAIGateway.swift`
is unchanged from the tested base. The retained behavioral proof JSON was
validated for exact field types, observed nonzero/zero exit codes, and existing
nonempty logs. No marker toggle substitutes for the HTTP behavior.

The final worktree is uncommitted for Foundry. No refs, versions, dependencies,
publication state or first-token timing implementation were changed.

## Part 3 section 2: client first-token timing correction — October 17–18, 2026

Status: defined timing cases are implemented and locally verified. **Full section-2
conformance is held for a coordinator decision on Anthropic initial tool input.**
This section supersedes earlier current-status statements that first-token timing
is wholly pending; historical runs above retain their original scope. Publication
remains on hold. Changes remain uncommitted for Foundry. No dependencies, tools
minimum, versions, tags, project refs or publication state were changed, and no
sibling repository was edited.

The starting Swift commit is `63cf0645930dadd7731a240f8a1029e8d51f1007`.
The initiative brief matched the required SHA-256
`ea6a0efa56bfb3cd74b5ce728f80cc33c6fbd853114bec94b8aabe79f5d28e6e`.
The inspected and rechecked governing `MODEL-METADATA-2026-10.md`, including its
October 17 decisions, has SHA-256
`d9945dca45ce09e2163843263a75b5e93028b00ee1baf191fc3ff13396830e9c`.

### Contract and source identity

The local executable set is **`swift-stream-first-token-v2-owner-anthropic-input`**, comprising the
`FirstToken*Tests.swift` public-API HTTP cases and
`scripts/verify-packaged-stream-timing`. The original generic delta catalog was copied from
`ex-stream-first-token-v1` at `mojentic-ex@f42c5c8d7e9fa9070fe7d86d6d4874dff07ff3b4`,
original SHA-256 `fddd71c8e0062c489588b2e15df749e934cf9d9412d05b4ee08eb52673425a6c`.
The current owner extension and catalog hash are recorded in the final assessment.
The binding **`ts-stream-first-token-v1`** reference was inspected at
`mojentic-ts@b8db5d59c02297e39335ba1deed83fa04e1b8f11`, source SHA-256
`e94d4f53928b3ea519eceedcb0f7e7a41ae2eb5da52076369d92374108b3d2a8`.
Provenance is retained in
`Tests/MojenticTests/Fixtures/Contracts/stream_first_token_v1.provenance.md`;
the adjacent manifest checks the catalog bytes. Named content/thinking responses
in the packaged consumer derive from that same catalog.

Swift self-validates the distributed library using its public API and a fresh
source-package consumer. This does not require an unreleased dependent adoption,
another port's executable runner, or vendor live-service certification. The
loopback peer supplies declared provider responses, and tests verify actual Swift
HTTP requests, semantic events, typed errors and measurements. Contract tests run
inside both required Swift test gates. The artifact consumer imports `Mojentic`
without `@testable` and builds in a new temporary SwiftPM package from an extracted
source archive, with fresh build products and dependency resolution.

### Public streaming-route characterization

| Public route | Supported providers | Terminal evidence and behavior |
| --- | --- | --- |
| `LLMGateway.stream` | Ollama, OpenAI, oMLX, Anthropic trait | `done(..., evidence:)`; failures are `MojenticError.streamFailure`, retaining the original cause and evidence. Legacy finish conventions stay intact; timing does not strengthen their completion proof. |
| `completeStreamEvents` | Ollama, OpenAI, oMLX | `completed(evidence)` or a timed `error`; existing strict stop/marker/no-tool rules remain. Anthropic/custom unsupported defaults send no request. |
| `streamRecovering` with a policy | All four providers | `done(..., evidence:)` or typed `RecoveryError.evidence`; admission, progress, identity, attempt history and cancellation ownership remain intact. |
| `completeStreamEventsRecovering` with a policy | All four providers | `completed(evidence)`, `recoveryFailure(error)` with evidence, or original setup errors before dispatch. |
| Recovery entrypoints without a policy | Legacy-supported routes above | Existing bridges retain the same evidence and one-send behavior. Anthropic single-turn remains unsupported without a policy. |
| Broker `generateStreamEvents` / `generateRecoveryStreamEvents` | Respective single-turn gateway routes | Terminal evidence passes through to callers and response tracing; no tool recursion. |
| Broker `stream` and `ChatSession.stream` | Respective tool-capable gateway routes | `metrics(evidence)` for each accepted provider turn; final `done(LLMResponse)` exposes final-turn metadata. Each tool-result continuation starts a fresh measurement; failure retains that continuation's evidence. |
| Recovery report observer | Policy-enabled gateway/broker/session routes | `CompletionRecoveryReport.evidence` retains terminal timing even when cancellation ends an `AsyncStream` iterator before terminal delivery. No terminal delivery is promised to an iterator that has stopped. |

`HTTPClient.streamLines` alone is a raw transport utility, and realtime audio
sessions are outside this completion contract. Custom gateways may omit the new
optional `done` evidence. Old event constructors still compile with that default;
exhaustive patterns/switches must account for the documented major-version API
additions. Older Codable responses decode without metadata.

### Named executable assertions

| Contract decision / acceptance case | Actual boundary assertions |
| --- | --- |
| Monotonic origin at dispatch, excluding delayed capture | `FirstTokenLifecycleTests.delayedCaptureIsOutsideFirstDispatch`: real HTTP for every recovery boundary; a 200 ms pre-send capture delay stays outside duration, with wall time minus duration at least 180 ms. Native legacy SDK dispatch follows serialization and cancellation checks. |
| Content, thinking and absent-token cases on supported legacy/recovery routes | `FirstTokenRouteTests.contentThinkingEmptyAndProviderMetrics`, `FirstTokenAnthropicTests.nativeLegacyAndRecoveryKinds`: exact kind, visible content, success terminal, provider usage, duration at least first-token time, and absent first-token fields for empty output. |
| Same-frame precedence and irrelevant/empty fields | `FirstTokenRouteTests.executableContractThroughHTTP`: named catalog cases include thinking/content/tool precedence, content/tool precedence, empty content, tool name only, empty arguments, and legacy function-call arguments. Each asserts the exact kind or absence and the declared completed/error outcome. |
| Tool arguments on every established wire shape and terminal route | `FirstTokenToolRouteTests.argumentsCountAcrossToolCapableAndRejectingSingleTurnRoutes` covers Ollama/OpenAI/oMLX with and without recovery, both tools and strict single-turn APIs. It asserts `tool_call` timing, exact done/error/interrupted outcomes, original `unexpectedToolCalls` causes on rejection, and exact normalized tool name/arguments/available ID on success. Anthropic initial inputs and zero-argument calls are covered by `FirstTokenAnthropicTests.initialObjectWaitsForFragment`, using the owner rule below. |
| Partial arguments before assembly and before failure | `FirstTokenLifecycleTests.firstArgumentFragmentPrecedesTerminalAssembly`, `FirstTokenCancellationTests.argumentFragmentSurvivesFailureBeforeToolAssembly`: held HTTP suffix/close, `tool_call` first, exact `done` versus `interrupted`/throw outcome, duration minus first-token time at least 150 ms. `FirstTokenAnthropicTests.firstPartialJSONCountsBeforeToolAssembly` covers native `input_json_delta` on both legacy and recovering tool-capable routes. |
| Keepalives and empty frames are not tokens | `FirstTokenRouteTests.omlxKeepaliveNeverCounts`: a keepalive containing apparent content still yields no visible content or first-token fields, completes normally, and never becomes the provider model. Catalog empty/name-only cases verify absence on errors too. |
| One clock through admitted retries | `FirstTokenRetryTests.allRecoveryRoutesKeepOneClockAcrossAdmittedRetry` and `FirstTokenHTTPTests.retryMixedFrameUsesFirstDispatchAndThinkingPrecedence`: actual HTTP 503 then success, exact thinking kind and visible content, first-token time includes the real 150/80 ms retry delay, and duration is at least first-token time. |
| New clocks for completed and failed tool continuations | `FirstTokenLifecycleTests.brokerAndSessionToolContinuationsUseFreshClocks`, `failedToolContinuationHasFreshTimingAndNoReplay`: first turn `tool_call`, next turn `content`, exact success or typed `interrupted` outcome, one tool result, two real requests, no false final answer, and total elapsed minus both request durations at least 150 ms of tool time. Session success history and failed-history rollback remain asserted. |
| Failure before/after content and HTTP rejection | `FirstTokenProviderErrorTests.providerErrorEndsObservationBeforeTrailingFrames` sends a real provider-error frame followed by stray content in the same HTTP body: exact provider cause/detail, exact error/interrupted/malformed terminal, retained earlier content when present, and absent first-token fields when no token preceded the provider terminal.  `FirstTokenRouteTests.failuresBeforeAndAfterContent`: exact `exhausted`/`interrupted` versus legacy error/throw terminals, exact partial content, kind or absence, and duration relationships. `FirstTokenBrokerTests.httpRejectionRetainsStatusAndNoFirstToken` asserts original HTTP/provider status 503, original body/detail/cause, bounded attempt history and no first-token fields. |
| Cancellation with/without observed content | `FirstTokenCancellationTests.cancellationRetainsObservedTimingAndTypedRecovery`: actual scoped cancellation, exact typed `cancelled` outcome, observed kind or absence, terminal duration and one actual send. `cancellationReportRetainsTimingAfterIterationStops` verifies the cancellation failure category and retained report evidence across tool-capable and single-turn routes. |
| Provider metrics and existing recovery evidence | `FirstTokenBrokerTests.providerDurationsKeepOriginalUnits` tests both policy states: oMLX provider seconds remain 0.25/1.5/2/3.5 while client keys use milliseconds. `OMLXStreamEventsTests.completes` retains captured 0.73/0.73/1.97/2.7 provider values. Existing provider-frame identity, index, order, progress, raw-body, history and reflection suites remain in the full gates; provider-only projections exclude only the three new client keys. |
| Configured session and setup errors | `FirstTokenSessionTests.measuredStreamingPreservesConfiguredSessionAuthentication`: real HTTP 401 Basic challenge then success, the original session identity, actual Basic authorization, unchanged body bytes and content timing. `encodingFailureRetainsOriginalErrorBeforeDispatch`: invalid JSON number yields the original typed encoding transport error, no stream events and no HTTP dispatch. |
| Broker public APIs and supported older records | `FirstTokenBrokerTests.brokerSingleTurnPreservesTimingAndProviderMetrics` checks exact thinking precedence, final content, completed terminal and usage through both broker APIs. `olderResponseRecordsDecodeWithoutTiming` and exhaustive baseline consumers verify absent older metadata and the new enum shapes. |
| Independent concurrent completions | `FirstTokenLifecycleTests.concurrentCompletionsNeverShareOriginsOrKinds` checks concurrent held thinking and fast content completions with distinct elapsed relationships. The fresh packaged consumer additionally runs concurrent calls through the **same gateway**, asserting thinking versus content, slow first-token time at least 150 ms and at least 100 ms beyond fast duration. |

### Binding owner decision — Anthropic initial input

The owner decision supplied for this correction is binding: `content_block_start`
with `tool_use.input: {}` does not start timing. The first nonempty
`input_json_delta.partial_json` starts `tool_call` timing. Successful zero-argument
calls without fragments retain duration with both first-token fields absent.
This replaces the former coordinator blocker; no external counterpart verification
is required for this library readiness assessment.

`FirstTokenAnthropicTests.initialObjectWaitsForFragment` exercises all four
legacy/recovery × fragment/no-fragment combinations over production HTTP. It delays
the initial object by 100 ms, then independently holds the fragment/terminal suffix
for 250 ms. It asserts successful done, no failure, exact tool ID/name/arguments,
duration at least 300 ms, fragment first-token time at least 300 ms, and absence
of both token fields without fragments. The fresh packaged consumer exercises the
same contract records and four outcomes. The existing partial-fragment test
separately proves timing precedes terminal tool assembly.

### Preserved cycle-8 evidence (historical source and artifact)

### Final working-source and artifact fingerprints

All commands below tested the uncommitted source based on `63cf0645930dadd7731a240f8a1029e8d51f1007`,
source/contract tree SHA-256 **`2418b995d133c3bf65da23a8cd65d94b06f7823d4e0e3ce5d52c7fba775fb1ef`** (326 files).
The tree comprises tracked and nonignored new files under `Sources`, `Tests`,
`Examples`, and `scripts`, plus `Package.swift`, `Package.resolved`, `.swift-format`,
`.swiftlint.yml`, and `.hone-gates.json`. Root status/changelog/conformance prose
is excluded to avoid a self-referential digest. Reproduce the fingerprint by
sorting relative paths, then hashing each UTF-8 path plus NUL followed by the
binary SHA-256 of that file, concatenated in path order. The tree was rechecked
after the final gates and remained unchanged.

The fresh consumer extracted and built source artifact SHA-256
`5fb6d9413d8dd13209fb6e3561c36ce9628856863a51962c9e0d2095a8fa6686`. It passed six named public-API checks: single-turn timing and
provider usage; throwing terminal evidence; typed throwing HTTP rejection with
original status and duration; event failure duration with absent token fields;
broker response metadata; and independent same-gateway concurrent thinking/content
completions. This is a pre-publication source artifact, not a registry release.

### Commands and final results

Host: Linux x86-64, Swift 6.4, SwiftLint 0.65.1; package tools minimum remains 6.1.
All six required commands are exactly those in `.hone-gates.json`. Transcript
digests below hash stdout followed by stderr; complete logs are archived by Foundry.

| Gate / executable command | Result | Transcript SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0 | `02a3a472e115e7eeb95b64865d954780af6565c99359360d9e8666a5edb92a03` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0 | `55fc17c0d47496add55c42a22c3ca1785607524c820f0bb261fa299089f8e181` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 437 tests, 126 suites | `81662ccfd50b9d2507d60c7ae71a3afa84ff153f1e5c635b3c46dc8cb29b4c7f` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 455 tests, 132 suites | `20d07e1fbd3dd685df0ac4d72a7e91ec939bd963dd6b91a6d542e35254e3a95c` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0 | `6df08431acb1eb4c65073f2035b17086cde45a0f303465c95720e2b731ffb7be` |
| `./scripts/with-gate-environment scripts/verify-packaged-stream-timing` | Exit 0; six named consumer checks | `8ee0958b644483a1646870ab3fb11fc1186f1b6620f5b441b273e445c4561c7c` |
| `osv-scanner scan source --lockfile=Package.resolved` | Exit 0; three packages, no issues | `b0a3c78cc2a437fdee078734133a35e5bc15376e3478627e8bee96f196e5a25a` |

### Behavioral rejection/correction evidence

Before expanding the fixtures or documentation, the public production-HTTP
probe `./scripts/with-gate-environment swift test --filter FirstTokenHTTPTests`
rejected the starting implementation: terminal timing metadata was absent, exit 1.
After wiring dispatch and receipt measurement, that same command passed, exit 0: 'thinking'
won in the mixed frame and elapsed first-token time included the admitted retry
delay from the first dispatch. The final full gates reran that named assertion.

- Rejecting transcript SHA-256: `8af1437271cd114f7c96704080dd90b1a9361514dd514921f1bb9d2274b57398`; actual exit 1.
- Corrected transcript SHA-256: `c68b59a1ebfcb7a8b7f2c7288fb17c7a2dfdb36d8707fc5c76f4b9f7b7b12ba0`; actual exit 0.

Additional real-boundary red/green checks caught and corrected configured-session
authentication loss and raw encoding-error replacement, and then verified that
provider-terminal errors cannot acquire first-token fields from trailing frames.
For the last case, `./scripts/with-gate-environment swift test --filter
FirstTokenProviderErrorTests` rejected the missing terminal fence with exit 1;
the final full-trait `FirstToken` run and both complete gates passed its exact
provider-error/content/absence assertions after correction.

Provider-terminal rejection transcript SHA-256: `50856fc463493ac3290d79eac5659137c8e72ca27bec3236e85a6517e533be19`.
Corrected full-trait timing subset transcript SHA-256: `8b7fb67485f794d1721607668a62f6dfe26828014d147b40d21d3ca4b671a10f` (exit 0; 24 tests, 10 suites).

### Available CI evidence and publication limits

The starting commit `63cf0645930dadd7731a240f8a1029e8d51f1007` has successful
[Validate, Test, and Publish run 39078182114](https://github.com/svetzal/mojentic-sw/actions/runs/39078182114)
(macOS, Linux Swift 6.4, Linux Swift 6.1 minimum, lint and format) and successful
[Supply Chain run 39078182172](https://github.com/svetzal/mojentic-sw/actions/runs/39078182172).
Those are baseline CI evidence, not CI for this uncommitted tree. New CI must
follow Foundry finalization. No Darwin recovery investigation was repeated.
The former Anthropic decision blocker is resolved by the binding owner decision
above. These prior results alone do not establish final-source readiness. No tag,
publication, released-registry install or dependent adoption is claimed; the
publication hold remains until coordinated approval and final-source CI.

## Final local release-readiness assessment

This assessment retains the complete cycle-8 implementation at
`0895693a826e07c69a85e4d9543f6a0f8b5f7ee3` and adds the owner-directed Anthropic
acceptance correction. It does not redo the Darwin investigation, change native
reasoning for 3.1, or require unreleased dependents to adopt Swift. The October 15
3.0.0 authorization remains in force. Dependencies, tools minimum 6.1, versions,
git refs and publication state are unchanged.

| Release part | Swift assessment and executable mapping |
| --- | --- |
| 1 — transient recovery and October 12 amendment | Retained. The part-1 decision map above and `RECOVERY-CONFORMANCE.md` cover admission, frozen requests, status/transport classification, Retry-After, observed/delivered output, cancellation, tool interruption and safe evidence. Full default/full-trait gates execute the public HTTP broker/session and provider route cases. No recovery policy or replay semantics changed. |
| 2 — native reasoning | Retained with the existing authorized Swift divergence. `NativeReasoningControlTests.exactContractControlsAcrossPublicBoundaries`, `rejectsUnsupportedControlsBeforeDispatch`, `ReasoningHistoryConformanceTests.populatedHistoryAcrossPublicRetryBoundaries`, `legacyAndNilHistoryStayCompatible`, `defaultPolicyKeepsOneAttemptWithNilHistory`, and broker/session retention tests map controls, validation, separate reasoning/content and opt-in history. Existing conformance mappings above remain binding; no 3.1 shape alignment is attempted. |
| 3 — metadata, request fidelity and client timing | Retained discovery and request-fidelity contracts; refreshed stale cycle-8 source-manifest entries without changing their behavioral rows. `FirstToken*` covers dispatch origins, retries, continuations, failures, provider metadata, old response decoding and concurrent calls. `FirstTokenAnthropicTests.initialObjectWaitsForFragment` closes the owner acceptance gap. The fresh source-artifact consumers verify public API requests, responses, errors, optional fields and terminal evidence. |
| 4 — Kotlin drops iOS | Kotlin-specific; no Swift implementation change. Swift retains its authorized ecosystem platforms. |
| 5 — October 15 audit bugs | No demonstrated Swift gap. Anthropic's common request builder uses `AnthropicMessageAdapter.adapt` for legacy and recovery and retains assistant text/tool turns (`AnthropicMessageAdapterTests.assistantToolCalls`, existing broker/tool continuation coverage). Swift has no removed Rust `num_predict` cast API; `maxTokens` is the sole caller output limit and request contracts verify provider mapping. `ChatSession` stores and forwards `CompletionConfig` directly on send/stream; Swift optional binding preserves explicit zero (request-fidelity explicit-zero cases). `RequestFidelityTests.sessionReservesOnlyExplicitOutputLimit` verifies public session history and omitted provider defaults. |

The CHANGELOG retains the breaking enum/event/config changes and migration
instructions introduced since 2.1.0. Its obsolete Anthropic question is replaced
with the owner rule. DocC documents the same successful zero-argument behavior.
Source tests use `import Mojentic` for the new regression and reach real production
HTTP. The packaged consumer extracts a source archive into a temporary directory,
resolves/builds a fresh SwiftPM consumer with full provider traits, and exercises
all four Anthropic combinations plus the prior six timing/error/broker/concurrency
checks. No registry publication or registry installation is claimed.

### Current contract identities and verification scope

The executable timing set is `swift-stream-first-token-v2-owner-anthropic-input`.
Its catalog keeps the prior generic v1 delta rows and provenance and adds the
owner's Anthropic start/fragment/end/expected records. Both the public source test
and packaged consumer derive their HTTP fixtures and exact tool expectations
from those records. Neither an independent mock nor a schema check is used as
behavioral verification. Provider simulation and public library consumption run
locally; there is no running cross-repository application boundary in this task.

### Acceptance proof

The same public-HTTP command,
`./scripts/with-gate-environment swift test --traits full --filter FirstTokenAnthropicTests.initialObjectWaitsForFragment`,
rejected a deliberate source mutation that counted initial input objects (actual
exit 1). Fragment first-token timestamps were about 105 ms rather than at least
300 ms, and both zero-argument routes wrongly acquired first-token fields.
After explicitly excluding tool-start objects in `StreamMeasurement`, the command
passed (actual exit 0): correct successful tools and fragment-based timing on both
routes, with duration-only zero-argument calls. This validates the preserved
cycle-8 behavior against the resolved owner rule; it does not claim cycle 8
originally counted empty objects. Foundry archives the complete proof logs.

### Tested working source and contract hashes

The final tests consume the uncommitted correction on base
`0895693a826e07c69a85e4d9543f6a0f8b5f7ee3`; the source/contract tree SHA-256 is
`94838427a737c6372757098c28bb16010969185e2cf18238e19f17cf2e707478` (326 files).
The reproducible tree algorithm is the path-plus-NUL-plus-binary-file-hash
algorithm specified above, over the same roots. Root prose and Foundry scratch
are excluded. The source artifact hashes below identify the actual detached
archives extracted and built by the fresh consumers, rather than a baseline
archive or an assumed future release.

| Contract catalog | SHA-256 |
| --- | --- |
| `native_reasoning_v1.json` | `be212ff011125f1d0927e3a65a0d7cd87eedbf9f5ff69e803b4112a80ae6b1f6` |
| `context_window_v1.json` | `9327502962112a020bafb46c6a677366df732f5a29cd44c92f17e8f632281395` |
| `request_fidelity_v1.json` | `369a944ecbd8426a69dd8b299d9cf3718393b38b129ac854f2424dcf0d72e3d5` |
| `stream_first_token_v1.json` | `949fb9dcb237d362d6ca539ccd90d054578e0ff220090a6544e53962a22f0cc4` |

Acceptance rejecting transcript SHA-256: `bf3aab07e2b26a60e7446c086af36fa4b49e07863b858934f4530d51ae3053b6` (exit 1).
Acceptance corrected transcript SHA-256: `b599a1c0ea01e6dca0782f73f377a7347e20332bdde7dd66b4f0f2993d6068c0` (exit 0).

### Current commands and actual results

Host: Linux x86-64, Swift 6.4, SwiftLint 0.65.1. One `.hone-gates.json` was
discovered; all six required gates passed. Full-trait tests also execute the
reasoning history and recovery conformance cases beyond the targeted subsets.
Transcript digests hash captured stdout followed by stderr; complete logs and
behavioral proof are archived by Foundry, not added as repository evidence.

| Command | Actual result | Transcript SHA-256 |
| --- | --- | --- |
| `./scripts/with-gate-environment swift format lint --strict --recursive Sources Tests` | Exit 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `./scripts/with-gate-environment swiftlint --strict` | Exit 0 | `4cef862f7f39b2165a51002043387699370bb65dbaec377362703f9f9048bc52` |
| `./scripts/with-gate-environment swift build -c release` | Exit 0 | `f37f8701193c12dd4346aed768d0451770dbbf06c1548ac384421d7f545d1e18` |
| `./scripts/with-gate-environment swift test --parallel` | Exit 0; 437 tests, 126 suites | `a5c18f5886a04b19170862f58e09812d4fcc2f87eb21d115eb141a76291a625f` |
| `./scripts/with-gate-environment swift test --traits full` | Exit 0; 456 tests, 132 suites | `a0a07201f83e567ea640904d2db387451ee4435727c90067e7f1a72d12fe94d9` |
| `./scripts/with-gate-environment swift package --disable-sandbox generate-documentation --target Mojentic --output-path .build/docs --warnings-as-errors` | Exit 0 | `f077ebfa075891f4d48facedf1d1c5ced42e785f8a536e5617c39fc4e09e369e` |
| `./scripts/with-gate-environment swift test --traits full --filter FirstToken` | Exit 0; 25 tests, 10 suites | `928551bcbb9cdda3a10d4c8bf03158bea94e958930ea040be0de5fb2db2e15a7` |
| `./scripts/with-gate-environment swift test --traits full --filter NativeReasoning` | Exit 0; 11 tests, 4 suites | `57277877fc8b915e03132593c95b4b351a296a7e11e9bdf8319188a514f83b31` |
| `scripts/verify-context-window-contract --traits full` | Exit 0; 12 tests, 4 suites | `6bf5c6a035e1333845283e2857d3d7281eab81d168621f17ae1c3caac022ea1e` |
| `scripts/verify-request-fidelity-contract` | Exit 0; 14 tests, 3 suites | `0053435ffc7795f273202af9bcf741f4685d19ccb5850015f50cc2b02cca6314` |
| `./scripts/with-gate-environment scripts/verify-packaged-stream-timing` | Exit 0; 10 named public consumer checks; four exact Anthropic outcomes | `2f2c1bd560c28eb0ac2f2dabfd665564a724ed4242951686b5dc192f06f92088` |
| `./scripts/with-gate-environment scripts/verify-packaged-request-fidelity` | Exit 0; 42 provider/consumer request pairs and two expected warning assertions | `a189800b4349505e399a2362ccb0b5dc3fcf7feb201759c59da0e99e30e6ca87` |
| `osv-scanner scan source --lockfile=Package.resolved` | Exit 0; 3 resolved packages; no issues | `bc9fc77392e1888d7e04470dcd2a52cfe200255b09e45673dd926612076b5c28` |

Freshly extracted source artifact identities:

- `packaged-timing`: SHA-256 `ff804d213ccfe3fe5294f5d6d5c0b840bee146176149fe47a3f5b113e082a753`; fresh SwiftPM resolve/build and public HTTP consumer exit 0.
- `packaged-request`: SHA-256 `9264d9122c1d03cb042d53dc47a21eb1b36fb6f288334a783d76cdebf872421e`; fresh SwiftPM resolve/build and public HTTP consumer exit 0.

The timing consumer's preserved redundant `try` markers were removed after log
review; the fresh consumer was rebuilt and rerun successfully with no Swift
compiler diagnostics. SwiftPM emitted host configuration/security-cache access
warnings and the execution host emitted `safeExec` signal warnings; these are
recorded tool-environment diagnostics, not suppressed source diagnostics.
Expected provider warnings remain asserted by the request-fidelity consumer.
Dependencies and the lockfile were not changed; OSV reports no issues and no
advisory suppression was added. Both contract manifests and refreshed Swift
source manifests verify against the tested tree.

### Readiness and final-source CI

Swift local implementation and distribution self-validation for release parts
1–5 are complete under the binding owner decision. The correction is ready for
Foundry finalization and coordinated release review. The final working source
above has no landed commit or CI run yet: all changes are intentionally
uncommitted. CI for the eventual finalized source must pass before release
approval; it cannot be inferred from local checks or prior green runs.

The recorded `63cf0645930dadd7731a240f8a1029e8d51f1007` baseline
[Validate, Test, and Publish run 39078182114](https://github.com/svetzal/mojentic-sw/actions/runs/39078182114)
and [Supply Chain run 39078182172](https://github.com/svetzal/mojentic-sw/actions/runs/39078182172)
remain baseline evidence only. They do not verify cycle-8 base `0895693` plus this
correction. The existing Darwin investigation and its historical platform/API
results are retained without rerunning them or claiming new Darwin verification.

Coordinated publication stays held for final landed-source CI and the
coordinator's all-six-port readiness/approval condition. No refs, versions,
tags or publication state were modified. No released registry artifact or
dependent adoption is claimed. Foundry owns finalization; proof logs and scratch
are execution evidence and must not be included in the landed source change.
