import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryLifecycleCompletionTests {
    @Test(
        arguments: RecoveryStatusBoundary.all.filter {
            [.ordinary, .structured, .json].contains($0.operation)
        },
        [false, true]
    )
    func bufferedSuccess(_ boundary: RecoveryStatusBoundary, _ retry: Bool) async throws {
        let success = try boundary.buffered.success()
        let rejected = RecoveryReply(status: 503, body: "busy")
        let replies = retry ? [rejected, success] : [success]
        let server = try InProcessHTTPFixture(replies: replies)
        let recorder = RecoveryRecorder()
        let delivered = RecoveryLocked<[String]>([])
        try await boundary.invoke(
            boundary.provider.gateway(server, policy: recoveryPolicy(recorder)),
            delivered: delivered
        )
        #expect(
            delivered.withLock { $0 } == [
                boundary.operation == .json
                    ? "json:42" : boundary.operation == .ordinary ? "recovered" : #"{"answer":42}"#
            ]
        )
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        let observed = RecoverySemanticProgress(
            reasoningBytes: 9,
            contentBytes: boundary.operation == .ordinary ? 9 : 13
        )
        var output = observed
        if boundary.provider.openAI { output.reasoningBytes = 0 }
        #expect(
            recorder.events.withLock { $0 }
                == RecoveryLifecycleEvidence(boundary.buffered).success(
                    identities: identities,
                    reply: success,
                    progress: lifecycleProgress(success, observed: observed, delivered: output),
                    rejected: retry ? rejected : nil
                )
        )
    }

    @Test(arguments: RecoveryLifecycleStreamCase.all, [false, true])
    func streamingSuccess(_ scenario: RecoveryLifecycleStreamCase, _ retry: Bool) async throws {
        let boundary = scenario.boundary
        let success = try RecoveryReply(body: boundary.frame(content: "é🐈", done: true))
        let rejected = RecoveryReply(status: 503, body: "busy")
        let replies = retry ? [rejected, success] : [success]
        let server = try InProcessHTTPFixture(replies: replies)
        let recorder = RecoveryRecorder()
        let gateway = boundary.gateway(server, recoveryPolicy(recorder))
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(broker: broker, model: "fixture", systemPrompt: "seed")
        let seen = try await withRecoveryStreamCancellation {
            var seen: [String] = []
            let consumer = try scenario.consumer(gateway, broker: broker, session: session)
            while let event = try await consumer.next() { seen.append(event) }
            #expect(try await consumer.next() == nil)
            return seen
        }
        #expect(seen.filter { $0.hasPrefix("content:") } == ["content:é🐈"])
        #expect(seen.filter { $0 == "terminal" } == ["terminal"])
        #expect(!seen.contains("tool") && !seen.contains("tool-result"))
        #expect(
            await session.messages()
                == (scenario.path == "session"
                    ? [.system("seed"), .user("question"), .assistant("é🐈")] : [.system("seed")])
        )
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        let semantic = RecoverySemanticProgress(contentBytes: 6)
        #expect(
            recorder.events.withLock { $0 }
                == RecoveryLifecycleEvidence(boundary).success(
                    identities: identities,
                    reply: success,
                    progress: lifecycleProgress(success, observed: semantic, delivered: semantic),
                    rejected: retry ? rejected : nil
                )
        )
    }
}

struct RecoveryLifecycleStreamCase: Sendable, CustomStringConvertible {
    let boundary: StreamingBoundary
    let path: String
    var description: String { "\(boundary)/\(path)" }
    static var all: [Self] {
        StreamingBoundary.withAnthropic.flatMap { boundary in
            (boundary.single ? ["gateway", "broker"] : ["gateway", "broker", "session"]).map {
                Self(boundary: boundary, path: $0)
            }
        }
    }

    func consumer(
        _ gateway: any LLMGateway,
        broker: LLMBroker,
        session: ChatSession
    ) throws -> TerminalRecoveryConsumer {
        if boundary.single {
            return try TerminalRecoveryConsumer(
                path == "gateway"
                    ? gateway.completeStreamEventsRecovering(model: "fixture", messages: [], config: .init())
                    : broker.generateRecoveryStreamEvents(model: "fixture", messages: [])
            )
        }
        if path == "gateway" {
            return TerminalRecoveryConsumer(
                gateway.streamRecovering(
                    model: "fixture",
                    messages: [],
                    tools: nil,
                    config: .init()
                )
            )
        }
        return TerminalRecoveryConsumer(
            path == "session"
                ? session.stream("question") : broker.stream(model: "fixture", messages: [.user("question")])
        )
    }
}
