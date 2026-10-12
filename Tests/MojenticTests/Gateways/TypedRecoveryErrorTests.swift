import Foundation
@testable import Mojentic
import Testing

@Suite("Typed recovery errors at public boundaries")
struct TypedRecoveryErrorTests {
    @Test(arguments: RecoveryBoundary.all.filter { !$0.structured })
    func multimodalLengthThroughSession(_ provider: RecoveryBoundary) async throws {
        try await lengthCause(.init(provider: provider, path: .sessionImages), false)
    }

    @Test
    func bufferedLengthThroughBroker() async throws {
        let reply = RecoveryReply(
            body:
                #"""
                {"model":"served","message":{"role":"assistant","content":"é"},
                "done":true,"done_reason":"length","prompt_eval_count":3,"eval_count":4}
                """#
        )
        let server = try RecoveryLoopback(replies: [reply])
        let recorder = RecoveryRecorder()
        let boundary = RecoveryBoundary(omlx: false, structured: false)
        let broker = LLMBroker(gateway: boundary.gateway(server, policy: recoveryPolicy(recorder)))
        let failure = try await recoveryFailure {
            _ = try await broker.complete(model: "fixture", messages: [.user("question")])
        }
        let cause = try #require(failure.failure.inspectEvidence().cause as? MojenticError)
        guard case .incompleteCompletion(let evidence) = cause else {
            Issue.record("Expected original typed length cause")
            return
        }
        #expect(evidence.finishReason == "length")
        #expect(evidence.usage?.promptTokens == 3)
        #expect(evidence.usage?.completionTokens == 4)
        #expect(evidence.providerModel == "served")
        let identities = try assertStatusWires(recorder, server: server, replies: [reply])
        #expect(failure.failure.identity == identities[0])
        #expect(identities[0].attemptID != identities[0].logicalID)
        #expect(failure.history.map(\.identity) == identities.map(Optional.some))
        #expect(failure.failure.progress.observed.contentBytes == 2)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
    }
}

extension TypedRecoveryErrorTests {
    @Test(arguments: TypedRecoveryBoundary.all, [false, true])
    func invalidPolicy(_ boundary: TypedRecoveryBoundary, _ scoped: Bool) async throws {
        let server = try RecoveryLoopback(replies: [])
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        let changes: [@Sendable (inout CompletionRecoveryPolicy) -> Void] = [
            { $0.maximumAttempts = 0 }, { $0.maximumAttempts = -1 },
            { $0.baseDelay = -1 }, { $0.baseDelay = .infinity }, { $0.baseDelay = .nan },
            { $0.baseDelay = -.infinity },
            { $0.delayCeiling = -1 }, { $0.delayCeiling = .nan },
            { $0.delayCeiling = .infinity }, { $0.delayCeiling = -.infinity },
            { $0.budget = -1 }, { $0.budget = .infinity }, { $0.budget = .nan },
            { $0.budget = -.infinity }, { $0.deadline = .nan },
            { $0.deadline = .infinity }, { $0.deadline = -.infinity },
        ]
        for change in changes {
            var policy = recoveryPolicy(recorder)
            change(&policy)
            let failure = try await invoke(boundary, server, policy, counter, scoped: scoped)
            let typed = try #require(failure as? MojenticError)
            guard case .invalidArgument(let message) = typed else {
                Issue.record("Policy error was replaced at the public boundary")
                return
            }
            #expect(message == "Invalid buffered recovery limits")
            #expect(server.requests.withLock { $0 }.isEmpty)
            #expect(recorder.requests.withLock { $0 }.isEmpty)
            #expect(recorder.wires.withLock { $0 }.isEmpty)
            #expect(recorder.events.withLock { $0 }.isEmpty)
            #expect(counter.value.withLock { $0 } == 0)
        }
        #expect(server.requests.withLock { $0 }.isEmpty)
        #expect(recorder.requests.withLock { $0 }.isEmpty)
        #expect(recorder.wires.withLock { $0 }.isEmpty)
        #expect(recorder.events.withLock { $0 }.isEmpty)
        #expect(counter.value.withLock { $0 } == 0)
    }

    @Test(arguments: TypedRecoveryBoundary.all, [(false, false), (false, true), (true, false), (true, true)])
    func captureCause(
        _ boundary: TypedRecoveryBoundary, _ options: (Bool, Bool),
    ) async throws {
        let (scoped, postResponse) = options
        let reply = try boundary.reply(length: false)
        let server = try RecoveryLoopback(replies: [reply])
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        var policy = recoveryPolicy(recorder)
        let observe = policy.wireObserver
        policy.wireObserver = { event in
            try observe?(event)
            switch event {
            case .request where !postResponse:
                throw TypedCaptureCause(stage: "request", sequence: 17)
            case .body where postResponse:
                throw TypedCaptureCause(stage: "response", sequence: 29)
            default: break
            }
        }
        let failure = try #require(
            await invoke(boundary, server, policy, counter, scoped: scoped) as? RecoveryError)
        #expect(failure.outcome == .captureFailed)
        #expect(failure.failure.category == .capture)
        let cause = try #require(failure.failure.inspectEvidence().cause as? TypedCaptureCause)
        #expect(cause.stage == (postResponse ? "response" : "request"))
        #expect(cause.sequence == (postResponse ? 29 : 17))
        let candidates = recorder.requests.withLock { $0 }
        let candidate = try #require(candidates.first)
        #expect(candidates.count == 1)
        if boundary.path == .sessionImages {
            try assertTypedImageRequest(candidate.1, provider: boundary.provider)
        }
        #expect(candidate.0.logicalID == failure.logicalID)
        #expect(candidate.0.wireNumber == 1)
        #expect(candidate.0.attemptID != candidate.0.logicalID)
        #expect(server.requests.withLock { $0 } == (postResponse ? [candidate.1] : []))
        #expect(failure.failure.identity == (postResponse ? candidate.0 : nil))
        #expect(failure.history.map(\.identity) == (postResponse ? [candidate.0] : []))
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        if postResponse {
            let identities = try assertStatusWires(recorder, server: server, replies: [reply])
            #expect(identities == [candidate.0])
            let historical = try #require(failure.history[0].inspectEvidence().cause as? TypedCaptureCause)
            #expect(historical.stage == "response")
            #expect(historical.sequence == 29)
            #expect(failure.history[0].progress == failure.failure.progress)
            #expect(failure.history[0].inspectEvidence().body == Data(reply.body.utf8))
            #expect(normalizedHeaders(failure.history[0].inspectEvidence().headers) == statusHeaders(reply))
            #expect(normalizedHeaders(failure.failure.inspectEvidence().headers) == statusHeaders(reply))
            #expect(failure.failure.progress.observed.contentBytes == 2)
            #expect(failure.failure.progress.observed == RecoverySemanticProgress(contentBytes: 2))
            #expect(failure.failure.progress.rawBytes == reply.body.utf8.count)
            #expect(failure.failure.progress.headersReceived)
            #expect(failure.failure.inspectEvidence().body == Data(reply.body.utf8))
        } else {
            #expect(failure.failure.progress == RecoveryProgress())
            #expect(failure.failure.inspectEvidence().body.isEmpty)
            #expect(failure.failure.inspectEvidence().headers.isEmpty)
            #expect(recorder.wires.withLock { $0.count } == 1)
        }
        #expect(counter.value.withLock { $0 } == 0)
    }

    @Test(arguments: TypedRecoveryBoundary.all, [false, true])
    func lengthCause(_ boundary: TypedRecoveryBoundary, _ scoped: Bool) async throws {
        let reply = try boundary.reply(length: true)
        let server = try RecoveryLoopback(replies: [reply])
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        let delivered = RecoveryLocked<Int>(0)
        let failure = try #require(
            await invoke(
                boundary, server, recoveryPolicy(recorder), counter, scoped: scoped, delivered: delivered)
                as? RecoveryError)
        let cause = try #require(failure.failure.inspectEvidence().cause as? MojenticError)
        guard case .incompleteCompletion(let evidence) = cause else {
            Issue.record("Length failure lost its original typed completion evidence")
            return
        }
        #expect(evidence.finishReason == (boundary.provider.anthropic ? "max_tokens" : "length"))
        #expect(evidence.usage == Usage(promptTokens: 3, completionTokens: 12, totalTokens: 15))
        #expect(evidence.providerModel == (boundary.path.streaming ? "payload-sentinel" : "served"))
        var metadata: [String: JSONValue]
        if boundary.provider.anthropic || boundary.provider.omlx {
            metadata = ["id": .string(boundary.path.streaming ? "credential-sentinel" : "typed-message")]
            if boundary.provider.omlx, !boundary.provider.openAI, !boundary.provider.anthropic,
                !boundary.path.streaming
            {
                metadata["usage"] = ["prompt_tokens": 3, "completion_tokens": 12, "total_tokens": 15]
            }
        } else {
            metadata = [
                "created_at": .string(boundary.path.streaming ? "credential-sentinel" : "typed-time"),
                "eval_duration": 6_000_000_000,
            ]
        }
        #expect(evidence.metadata == metadata)
        let identities = try assertStatusWires(recorder, server: server, replies: [reply])
        #expect(failure.logicalID == identities[0].logicalID)
        #expect(failure.failure.identity == identities[0])
        #expect(identities[0].attemptID != identities[0].logicalID)
        #expect(failure.history.map(\.identity) == identities.map(Optional.some))
        let historical = try #require(failure.history[0].inspectEvidence().cause as? MojenticError)
        guard case .incompleteCompletion(let historicalEvidence) = historical else {
            Issue.record("History lost the original typed length cause")
            return
        }
        #expect(historicalEvidence == evidence)
        #expect(failure.failure.inspectEvidence().body == Data(reply.body.utf8))
        #expect(normalizedHeaders(failure.failure.inspectEvidence().headers) == statusHeaders(reply))
        #expect(failure.history[0].inspectEvidence().body == Data(reply.body.utf8))
        #expect(normalizedHeaders(failure.history[0].inspectEvidence().headers) == statusHeaders(reply))
        #expect(failure.history[0].progress == failure.failure.progress)
        #expect(failure.failure.progress.rawBytes == reply.body.utf8.count)
        #expect(failure.failure.progress.headersReceived)
        #expect(failure.failure.progress.observed == RecoverySemanticProgress(contentBytes: 2))
        let deliveredBytes = boundary.path.streaming && boundary.provider.omlx ? 2 : 0
        #expect(delivered.withLock { $0 } == deliveredBytes)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress(contentBytes: deliveredBytes))
        #expect(counter.value.withLock { $0 } == 0)
    }

    private func invoke(
        _ boundary: TypedRecoveryBoundary,
        _ server: RecoveryLoopback,
        _ policy: CompletionRecoveryPolicy,
        _ counter: RecoveryToolCounter,
        scoped: Bool,
        delivered: RecoveryLocked<Int> = RecoveryLocked(0),
    ) async throws -> any Error {
        let gateway = boundary.provider.gateway(server, policy: policy)
        let broker = LLMBroker(gateway: gateway)
        let tool = RecoveryCountingTool(calls: counter)
        let session = ChatSession(
            broker: broker, model: "fixture", systemPrompt: "seeded history", tools: [tool])
        let seed = await session.messages()
        #expect(seed == [.system("seeded history")])
        let failure: any Error
        if scoped {
            failure = try await withRecoveryStreamCancellation {
                try await boundary.failure(
                    gateway: gateway, session: session, broker: broker, tool: tool, delivered: delivered)
            }
        } else {
            failure = try await boundary.failure(
                gateway: gateway, session: session, broker: broker, tool: tool, delivered: delivered)
        }
        #expect(await session.messages() == seed)
        if boundary.path == .sessionImages {
            for request in server.requests.withLock({ $0 }) {
                try assertTypedImageRequest(request, provider: boundary.provider)
            }
        }
        return failure
    }
}
