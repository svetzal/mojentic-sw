import Foundation
import Mojentic
import Testing

@Suite(.serialized)
struct ReasoningHistoryConformanceTests {
    @Test(arguments: [false, true])
    func explicitProfileRejectsUnsupportedNativeHistoryBeforeHTTP(omlx: Bool) async throws {
        let server = try InProcessHTTPFixture(replies: [])
        let gateway = RecoveryBoundary(
            omlx: omlx,
            structured: false
        ).gateway(
            server,
            policy: .init())
        let config = CompletionConfig(
            reasoningProfile: .init(
                supportedEfforts: [.enabled],
                supportsHistory: false))
        await #expect(throws: MojenticError.self) {
            _ = try await gateway.complete(
                model: "fixture",
                messages: reasoningHistory(populated: true),
                tools: nil,
                config: config)
        }
        #expect(server.requests.withLock { $0.isEmpty })
    }

    @Test func legacyCodableRecordsLeaveReasoningUnknown() throws {
        let old = Data(#"{"temperature":1,"maxTokens":123,"extraOptions":{}}"#.utf8)
        let config = try JSONDecoder().decode(CompletionConfig.self, from: old)
        #expect(config.reasoning == nil)
        #expect(config.reasoningProfile == nil)
        #expect(!config.retainThinking)
        let response = try JSONDecoder().decode(LLMResponse.self, from: Data(#"{"content":"answer"}"#.utf8))
        #expect(response.thinking == nil)
        #expect(response.retainedMessages.isEmpty)
    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func populatedHistoryAcrossPublicRetryBoundaries(_ boundary: RecoveryStatusBoundary) async throws {
        let failed = RecoveryReply(status: 503, body: "original failure é猫")
        let success = try reasoningReply(boundary)
        let server = try InProcessHTTPFixture(replies: [failed, success])
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        let admissions = RecoveryLocked<[(RecoveryFailure, Int)]>([])
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        policy.admission = { failure, next in
            admissions.withLock { $0.append((failure, next)) }
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        try await invokeReasoningHistory(
            boundary,
            gateway: boundary.provider.gateway(
                server,
                policy: policy),
            messages: reasoningHistory(populated: true),
        )
        let identities = try assertStatusWires(recorder, server: server, replies: [failed, success])
        try assertReasoningSocketHistory(server, provider: boundary.provider, populated: true)
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition.rawValue) == [
                "attemptStarted", "attemptFailed", "admissionPending", "admissionAllowed", "delayScheduled",
                "retryStarted", "attemptStarted", "attemptSucceeded",
            ]
        )
        #expect(events.prefix(5).allSatisfy { $0.identity == identities[0] })
        #expect(events.suffix(3).allSatisfy { $0.identity == identities[1] })
        #expect(events.allSatisfy { $0.logicalID == identities[0].logicalID })
        let admission = try #require(admissions.withLock { $0.first })
        #expect(admissions.withLock { $0.count } == 1)
        #expect(admission.1 == 2)
        try assertStatusFailure(admission.0, identity: identities[0], reply: failed)
        let report = try #require(reports.withLock { $0.first })
        #expect(reports.withLock { $0.count } == 1)
        #expect(report.identity == identities[1])
        try #require(report.history.count == 1)
        try assertStatusFailure(report.history[0], identity: identities[0], reply: failed)
    }

    @Test(
        arguments: RecoveryStatusBoundary.all.filter { !($0.provider.anthropic && $0.operation == .single) },
        [false, true],
    )
    func legacyAndNilHistoryStayCompatible(
        _ boundary: RecoveryStatusBoundary, _ populated: Bool,
    ) async throws {
        let server = try InProcessHTTPFixture(replies: [reasoningReply(boundary)])
        try await invokeReasoningHistory(
            boundary,
            gateway: boundary.provider.gateway(
                server,
                policy: nil),
            messages: reasoningHistory(populated: populated),
            legacy: true,
        )
        #expect(server.requests.withLock { $0.count } == 1)
        try assertReasoningSocketHistory(server, provider: boundary.provider, populated: populated)
    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func defaultPolicyKeepsOneAttemptWithNilHistory(_ boundary: RecoveryStatusBoundary) async throws {
        let failed = RecoveryReply(status: 503, body: "original failure")
        let server = try InProcessHTTPFixture(replies: [failed])
        let recorder = RecoveryRecorder()
        var policy = CompletionRecoveryPolicy()
        policy.timing = deterministicRecoveryTiming()
        #expect(policy.maximumAttempts == 1)
        policy.observer = { event in recorder.events.withLock { $0.append(event) } }
        policy.wireObserver = { event in
            recorder.wires.withLock { $0.append(event) }
            if case .request(let identity, _, _, let bytes) = event {
                recorder.requests.withLock { $0.append((identity, bytes)) }
            }
        }
        let failure = try await recoveryFailure {
            try await invokeReasoningHistory(
                boundary,
                gateway: boundary.provider.gateway(
                    server,
                    policy: policy),
                messages: reasoningHistory(populated: false),
            )
        }
        let identities = try assertStatusWires(recorder, server: server, replies: [failed])
        try assertReasoningSocketHistory(server, provider: boundary.provider, populated: false)
        #expect(failure.outcome == .exhausted)
        #expect(failure.history.map(\.identity) == identities.map(Optional.some))
        try assertStatusFailure(failure.failure, identity: identities[0], reply: failed)
        let events = recorder.events.withLock { $0 }
        #expect(events.map(\.transition) == [.attemptStarted, .attemptFailed, .exhausted])
        #expect(events.allSatisfy { $0.identity == identities[0] && $0.logicalID == identities[0].logicalID })
    }

    #if anthropic
        @Test(arguments: [false, true])
        func anthropicLegacySingleTurnRemainsUnsupported(_ populated: Bool) throws {
            let provider = RecoveryBoundary(
                omlx: true,
                structured: false,
                anthropic: true)
            let server = try InProcessHTTPFixture(replies: [provider.success()])
            let gateway = provider.gateway(
                server,
                policy: nil)
            #expect(throws: MojenticError.self) {
                _ = try gateway.completeStreamEvents(
                    model: "fixture",
                    messages: reasoningHistory(populated: populated),
                    config: .init(),
                )
            }
            #expect(server.requests.withLock { $0 }.isEmpty)
        }
    #endif

    @Test
    func additiveMessageAPIsAndCodableCompatibility() throws {
        let oldFactory: (String?, [LLMToolCall]?) -> LLMMessage = LLMMessage.assistant
        #expect(oldFactory("legacy", nil).thinking == nil)
        #expect(
            LLMMessage(
                role: .assistant,
                content: "legacy"
            ).thinking == nil)
        let oldJSON = Data(#"{"role":"assistant","content":"legacy"}"#.utf8)
        #expect(try JSONDecoder().decode(LLMMessage.self, from: oldJSON).thinking == nil)
        let populated = LLMMessage.assistant(
            "content",
            thinking: historyThinking)
        #expect(try JSONDecoder().decode(LLMMessage.self, from: JSONEncoder().encode(populated)) == populated)
        #expect(populated != .assistant("content"))
        let nilJSON = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(oldFactory("legacy", nil)),
        )
        #expect(nilJSON.objectValue?["thinking"] == nil)
    }
}
