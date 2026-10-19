import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryLifecycleBufferedCallerTests {
    @Test(
        arguments: TypedRecoveryBoundary.all.filter {
            [.broker, .brokerJSON, .brokerResponse, .session, .sessionImages].contains($0.path)
        },
        [false, true]
    )
    func successThroughCaller(_ boundary: TypedRecoveryBoundary, _ retry: Bool) async throws {
        let structured = boundary.path == .brokerJSON
        let provider = RecoveryBoundary(
            omlx: boundary.provider.omlx,
            structured: structured,
            openAI: boundary.provider.openAI,
            anthropic: boundary.provider.anthropic
        )
        let success = try provider.success()
        let rejected = RecoveryReply(status: 503, body: "busy")
        let replies = retry ? [rejected, success] : [success]
        let server = try InProcessHTTPFixture(replies: replies)
        let recorder = RecoveryRecorder()
        let counter = RecoveryToolCounter()
        let gateway = provider.gateway(server, policy: recoveryPolicy(recorder))
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(
            broker: broker,
            model: "fixture",
            systemPrompt: "seed",
            tools: [RecoveryCountingTool(calls: counter)]
        )
        let content = try await boundary.bufferedLifecycleResult(broker, session: session)
        #expect(content == (structured ? #"{"answer":42}"# : "recovered"))
        #expect(counter.value.withLock { $0 } == 0)
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        let observed = RecoverySemanticProgress(reasoningBytes: 9, contentBytes: structured ? 13 : 9)
        var delivered = observed
        if provider.openAI { delivered.reasoningBytes = 0 }
        #expect(
            recorder.events.withLock { $0 }
                == RecoveryLifecycleEvidence(boundary).success(
                    identities: identities,
                    reply: success,
                    progress: lifecycleProgress(success, observed: observed, delivered: delivered),
                    rejected: retry ? rejected : nil
                )
        )
        var expectedHistory: [LLMMessage] = [.system("seed")]
        if boundary.path == .session { expectedHistory += [.user("question"), .assistant("recovered")] }
        if boundary.path == .sessionImages {
            let user = LLMMessage.user(
                text: "question",
                images: [ImageContent(base64: typedRecoveryImageBase64, mimeType: "image/png")]
            )
            expectedHistory += [user, .assistant("recovered")]
            for request in server.requests.withLock({ $0 }) {
                try assertTypedImageRequest(request, provider: provider)
            }
        }
        #expect(await session.messages() == expectedHistory)
    }
}

extension TypedRecoveryBoundary {
    func bufferedLifecycleResult(_ broker: LLMBroker, session: ChatSession) async throws -> String {
        switch path {
        case .broker:
            return try await broker.complete(model: "fixture", messages: [.user("question")]).content
        case .brokerJSON:
            let answer = try await broker.completeJSON(
                model: "fixture",
                messages: [.user("question")],
                responseType: TypedRecoveryProjection.self
            )
            #expect(answer.answer == 42)
            return #"{"answer":42}"#
        case .brokerResponse:
            return try await broker.generateResponse(model: "fixture", messages: [.user("question")]).content
        case .session:
            return try await session.send("question").content
        case .sessionImages:
            return try await session.send(
                text: "question",
                images: [ImageContent(base64: typedRecoveryImageBase64, mimeType: "image/png")]
            ).content
        default:
            throw MojenticError.invalidArgument(message: "Expected buffered caller")
        }
    }
}
