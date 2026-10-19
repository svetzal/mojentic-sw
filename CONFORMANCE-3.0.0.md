# Swift 3.0.0 conformance

Local verification passed all six required gates, including both test modes and
DocC, against executable manifest `010a425e8d3d44ca8a484bbcbbd3f90fd6377357443670a4a977632644ed76eb`.
The [verification record](docs/DETERMINISTIC-TESTS.md) gives elapsed runtimes,
complete transcript hashes, unmasked trace evidence and the external verification gap.

This correction reconciles preserved campaign `foundry-task/mojentic-sw-mojentic-sw-no-network-tests-c2-1cb46e`
under Stacey's October 19 authorization. The public API and default production
transport are unchanged. The only new library change is the internal Anthropic
`LineStreamingTransport` initializer and dispatch route. The authorized per-completion
`StreamMeasurement` clock remains intact. Recovery semantics, dependencies,
Swift tools 6.1, versions, tags and publication state are preserved.

The local root copies of `TRANSIENT-RECOVERY-2026-10.md`,
`REASONING-PROTOTYPE-2026-10.md` and `MODEL-METADATA-2026-10.md` are byte-identical
to the authoritative mojentic-unify working copies inspected for this correction.
See [deterministic verification](docs/DETERMINISTIC-TESTS.md) for contract hashes,
tested source, gate results and inspection scope. Git retains earlier conformance
reports; their live-network and packaged results do not establish this correction.

## Characterization before migration

The existing assertions were inventoried before replacing the fixture. No test
suite was deleted. `RecoveryReply` moved out of the deleted `RecoveryLoopback.swift`
into `RecoveryReply.swift`; `RecoveryLocked` stays in `RecoveryTestSupport.swift`.
All dependent recovery/reasoning suites now use `InProcessHTTPFixture` at the HTTP
boundary. It uses unique `mojentic-fixture` URLs, URLProtocol for buffered/recovery
requests and `LineStreamingTransport` for ordinary streams. Unsupported custom
schemes cannot establish a real connection. Gateways, broker and sessions remain
the implementations under test, including their production encoding and decoding.

Timing assertions use injected instants and explicit rendezvous. Header assertions
now compare exact Unicode HTTP boundary values, rather than platform-dependent
TCP header decoding. Socket-close assertions become transport cancellation/finish
acknowledgements; they are combined with producer completion before caller resume.
The network-only packaged and example verifiers were removed. Their replacements
are public-API contract suites in both mandatory test modes; no current package
installation, external provider or cross-repository compatibility is claimed.

## Part 1: recovery and October 12 decisions

| Contract decision | Named tests and boundary assertions |
| --- | --- |
| Frozen request and identity | `RecoveryConformanceTests.bothOperationsPreserveShapingAndResults`, `RecoveryMetadataIdentityTests.publicBoundaryIdentity`: exact captured request bodies, logical/attempt IDs and wire numbers, response shaping and full lifecycle sequence. |
| Header octets and response evidence | `RecoveryHeaderEncodingTests.headerOctetsAndUTF8BodyThroughRecovery`: exact scripted header values, UTF-8 body bytes and frozen resend identities via `assertStatusWires`. |
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


## Part 2: native reasoning

| Binding behavior | Executable evidence |
| --- | --- |
| Six distinct controls; exact boolean/string types; omitted effort stays unknown; ordinary, structured, JSON, streamed tools and single-turn events, including retry | `NativeReasoningControlTests.exactContractControlsAcrossPublicBoundaries`: every shared control row across both local providers; actual first/retry HTTP bodies and separated response fields |
| Explicit caller-selected profiles and exact Qwen3.8 capabilities; no model-name inference | `explicitProfileAcceptsUnknownDefaultAndExactQwenEfforts`, `rejectsUnsupportedControlsBeforeDispatch`: arbitrary names accept selected supported controls; Qwen-like names cannot bypass rejection |
| Unsupported effort, retention and provider extensions fail before dispatch; shared-enum regression audit | `rejectsUnsupportedControlsBeforeDispatch`: ordinary, structured and both recovery stream APIs leave HTTP request capture empty for rejected controls; full-trait Anthropic cases; existing OpenAI/Anthropic legacy high/medium/low tests remain in full suite |
| Native history capability validation | `ReasoningHistoryConformanceTests.explicitProfileRejectsUnsupportedNativeHistoryBeforeHTTP`: existing populated reasoning history is rejected without HTTP |
| Completed ordinary and streamed multiple-tool continuity; outer-turn session retention; identities, order and separated results | `NativeReasoningContinuityTests.completedMultipleToolCallsAndSessionHistory`: both providers, ordinary and streams; entire role order, two calls and results, native fields in second and third HTTP requests; oMLX original call IDs and result linkage |
| Opt-in retention and oMLX preserve request | `retentionIsOptIn`, `completedMultipleToolCallsAndSessionHistory`, `NativeReasoningTests.completedToolHistoryCrossesHTTPBoundary`, `booleanControlAndRetentionPreserveOtherTemplateOptions`; exact `chat_template_kwargs.preserve_thinking`; forced server settings are outside this client guarantee |
| Cancellation after native delta excludes history and dispatch | `NativeReasoningExclusionTests.cancellationAfterNativeDeltaDoesNotRetainOrDispatch`: held in-process HTTP stream, observed native delta, cancellation, empty session history and unexecuted tool; `cancelledBufferedResponseCannotReturnRetainedHistory` pauses the I/O tracer after an in-process buffered response and excludes cancellation races before retained history returns |
| Errors and incomplete streams cannot manufacture native history | `incompleteStreamCannotBecomeRetainedHistory`, `failedContinuationNeverCommitsNativeHistory`: both providers; no final retained turn after EOF without completion or failed next request |
| Optional native history and legacy Codable records | Existing `legacyAndNilHistoryStayCompatible`, `defaultPolicyKeepsOneAttemptWithNilHistory`, `ReasoningHistoryTests`; added `legacyCodableRecordsLeaveReasoningUnknown` defaults absent retention to false without inventing effort or exchanges |
| Recovery accounting and existing iteration limits | Existing recovery/broker tests remain mandatory in both test gates; reasoning controls are validated before recovery creates a wire attempt and frozen bodies preserve controls/history across retry |

## Part 3: discovery and request fidelity

| Decision | Executable public-API assertions |
| --- | --- |
| Provider context identity, provenance and validation | `ContextWindowContractTests.sharedProviderAndConsumerRows`: contract-derived status/body, exact request model/method/path/headers, correct identity among similar model names, positive integer capacity, optional model parameter, missing fields, typed malformed/HTTP/transport errors. Direct and pure consumer projections use the same rows. |
| Raw-byte discovery invariance | `ContextWindowJourneyTests.discoveryPreservesCompletion`: ordinary/JSON/structured/tool-stream/single-turn routes, defaults and explicit zero/options; first and last entire encoded bodies and headers are equal before/after discovery. |
| Registry context without remote lookup | `ContextWindowContractTests.registryRowsNeverRequestHTTP`: registered/unknown model rows, capacity and provenance, zero dispatched requests. |
| Only caller-specified sampling/output/context | `RequestFidelityTests` shared default/explicit rows and `CompletionConfigTests`: omission versus explicit zero, exact provider output key, no leaked local-provider keys; Codable absent/null/legacy numeric records. |
| Required Anthropic output limits and thinking | `anthropicRequiredLimitAndThinking`, `documentedLegacyOutputLimit`, `anthropicContractCoversRegisteredModels`: exact model names/default/explicit limits and thinking budgets from request-fidelity-v1; unsupported thinking remains absent. |
| OpenAI accepted sampling and unsupported effort | `unsupportedReasoningIsDropped` and shared request rows: allowed temperature conversion, absence when unset, exact warning level/label/model and omitted unsupported effort. |
| Session context reservation | `RequestFidelityTests.sessionReservesOnlyExplicitOutputLimit`: history and request reservation reflect explicit caller limit; omitted output/context fields remain absent. |

## Part 3: client first-token timing

| Decision | Executable public-API assertions |
| --- | --- |
| Monotonic origin at dispatch, excluding delayed capture | `FirstTokenLifecycleTests.delayedCaptureIsOutsideFirstDispatch`: in-process HTTP for every recovery boundary; 200 injected ms of pre-send capture stays outside duration, with exact clock difference of 200 ms. Native legacy SDK dispatch follows serialization and cancellation checks. |
| Content, thinking and absent-token cases on supported legacy/recovery routes | `FirstTokenRouteTests.contentThinkingEmptyAndProviderMetrics`, `FirstTokenAnthropicTests.nativeLegacyAndRecoveryKinds`: exact kind, visible content, success terminal, provider usage, duration at least first-token time, and absent first-token fields for empty output. |
| Same-frame precedence and irrelevant/empty fields | `FirstTokenRouteTests.executableContractThroughHTTP`: named catalog cases include thinking/content/tool precedence, content/tool precedence, empty content, tool name only, empty arguments, and legacy function-call arguments. Each asserts the exact kind or absence and the declared completed/error outcome. |
| Tool arguments on every established wire shape and terminal route | `FirstTokenToolRouteTests.argumentsCountAcrossToolCapableAndRejectingSingleTurnRoutes` covers Ollama/OpenAI/oMLX with and without recovery, both tools and strict single-turn APIs. It asserts `tool_call` timing, exact done/error/interrupted outcomes, original `unexpectedToolCalls` causes on rejection, and exact normalized tool name/arguments/available ID on success. Anthropic initial inputs and zero-argument calls are covered by `FirstTokenAnthropicTests.initialObjectWaitsForFragment`, using the owner rule below. |
| Partial arguments before assembly and before failure | `FirstTokenLifecycleTests.firstArgumentFragmentPrecedesTerminalAssembly`, `FirstTokenCancellationTests.argumentFragmentSurvivesFailureBeforeToolAssembly`: held boundary suffix/termination, `tool_call` first, exact `done` versus `interrupted`/throw outcome, duration minus first-token time exactly 200 injected ms. `FirstTokenAnthropicTests.firstPartialJSONCountsBeforeToolAssembly` covers native `input_json_delta` on both legacy and recovering tool-capable routes. |
| Keepalives and empty frames are not tokens | `FirstTokenRouteTests.omlxKeepaliveNeverCounts`: a keepalive containing apparent content still yields no visible content or first-token fields, completes normally, and never becomes the provider model. Catalog empty/name-only cases verify absence on errors too. |
| One clock through admitted retries | `FirstTokenRetryTests.allRecoveryRoutesKeepOneClockAcrossAdmittedRetry` and `FirstTokenHTTPTests.retryMixedFrameUsesFirstDispatchAndThinkingPrecedence`: actual HTTP 503 then success, exact thinking kind and visible content, first-token time includes the injected 150/80 ms retry delay, and duration is at least first-token time. |
| New clocks for completed and failed tool continuations | `FirstTokenLifecycleTests.brokerAndSessionToolContinuationsUseFreshClocks`, `failedToolContinuationHasFreshTimingAndNoReplay`: first turn `tool_call`, next turn `content`, exact success or typed `interrupted` outcome, one tool result, two boundary requests, no false final answer, and total injected time minus both request durations exactly 200 ms of tool time. Session success history and failed-history rollback remain asserted. |
| Failure before/after content and HTTP rejection | `FirstTokenProviderErrorTests.providerErrorEndsObservationBeforeTrailingFrames` sends a real provider-error frame followed by stray content in the same HTTP body: exact provider cause/detail, exact error/interrupted/malformed terminal, retained earlier content when present, and absent first-token fields when no token preceded the provider terminal.  `FirstTokenRouteTests.failuresBeforeAndAfterContent`: exact `exhausted`/`interrupted` versus legacy error/throw terminals, exact partial content, kind or absence, and duration relationships. `FirstTokenBrokerTests.httpRejectionRetainsStatusAndNoFirstToken` asserts original HTTP/provider status 503, original body/detail/cause, bounded attempt history and no first-token fields. |
| Cancellation with/without observed content | `FirstTokenCancellationTests.cancellationRetainsObservedTimingAndTypedRecovery`: actual scoped cancellation, exact typed `cancelled` outcome, observed kind or absence, terminal duration and one actual send. `cancellationReportRetainsTimingAfterIterationStops` verifies the cancellation failure category and retained report evidence across tool-capable and single-turn routes. |
| Provider metrics and existing recovery evidence | `FirstTokenBrokerTests.providerDurationsKeepOriginalUnits` tests both policy states: oMLX provider seconds remain 0.25/1.5/2/3.5 while client keys use milliseconds. `OMLXStreamEventsTests.completes` retains captured 0.73/0.73/1.97/2.7 provider values. Existing provider-frame identity, index, order, progress, raw-body, history and reflection suites remain in the full gates; provider-only projections exclude only the three new client keys. |
| Configured session and setup errors | `FirstTokenSessionTests.measuredStreamingPreservesConfiguredSessionAndHeaders`: exact configured transport response, Bearer key, typed 503 response and duration-only timing. `measuredStreamingForwardsAuthenticationToOriginalSession`: injected Basic challenge reaches the exact original session delegate, which cancels it with no resend or content. Credential-success replay is SDK behavior and is not claimed by this in-process replacement. `encodingFailureRetainsOriginalErrorBeforeDispatch`: invalid JSON number yields the original typed encoding transport error, no stream events and no HTTP dispatch. |
| Broker public APIs and supported older records | `FirstTokenBrokerTests.brokerSingleTurnPreservesTimingAndProviderMetrics` checks exact thinking precedence, final content, completed terminal and usage through both broker APIs. `olderResponseRecordsDecodeWithoutTiming` and exhaustive baseline consumers verify absent older metadata and the new enum shapes. |
| Independent concurrent completions | `FirstTokenLifecycleTests.concurrentCompletionsNeverShareOriginsOrKinds` checks concurrent held thinking and fast content completions with distinct elapsed relationships. `sameGatewayConcurrentCompletionsKeepSeparateOrigins` covers the removed packaged concurrency case through the same gateway, with exact independent origins and kinds. |


`AnthropicLineBoundaryProbeTests.publicStreamPreservesToolIdentityArgumentsAndExactTiming`
is the rejecting/passing public-API seam proof: exact unmasked tool ID, name,
Toronto argument, model, stream flag and full user-message body, plus 25 ms first
fragment and 50 ms duration. `FirstTokenAnthropicTests.initialObjectWaitsForFragment`
consumes the shared start/fragment/end records on ordinary and recovery paths:
initial empty input is excluded, fragments yield the exact contract tool, and
zero-argument tools retain duration with both first-token fields absent.
`firstPartialJSONCountsBeforeToolAssembly` proves the first fragment starts time
200 injected milliseconds before assembly. Retry, capture, continuation and
concurrent-call cases compare explicit injected time rather than elapsed wall time.

## Cross-repository coordination

Only mojentic-sw was changed or verified. The catalogs retain their original
reference commit provenance. Those references are not paired verification of
this revised executable set. Provider repositories and dependent applications
have not verified the same version/hash at tested commits in this run; that
coordination gap remains open. Swift's in-process transport doubles prove its
own adapter/consumer behavior, not a remote provider implementation.
