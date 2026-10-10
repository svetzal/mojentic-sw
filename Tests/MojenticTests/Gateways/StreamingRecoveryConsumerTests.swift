import Foundation
@testable import Mojentic
import Testing

struct StreamingRecoveryConsumerTests {
    @Test(arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func completedToolRunsOnceAcrossFollowUp(_ omlx: Bool, _ mode: (Bool, Bool)) async throws {
        let (session, recover) = mode
        let boundary = StreamingBoundary(omlx: omlx, single: false)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: boundary.frame(tool: true, done: true)),
            RecoveryReply(status: 503, body: "busy"),
            RecoveryReply(body: boundary.frame(content: "recovered", done: true)),
        ])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        if !recover {
            policy.admission = { _, _ in
                AsyncStream {
                    $0.yield(.reject)
                    $0.finish()
                }
            }
        }
        let count = RecoveryToolCounter()
        let broker = LLMBroker(gateway: boundary.gateway(server, policy))
        let tools: [any LLMTool] = [RecoveryCountingTool(calls: count)]
        let config = CompletionConfig(maxToolIterations: 2)
        let chat = ChatSession(broker: broker, model: "fixture", tools: tools, config: config)
        let stream =
            if session {
                chat.stream("original-user")
            } else {
                broker.stream(
                    model: "fixture",
                    messages: [.user("original-user")],
                    tools: tools,
                    config: config,
                )
            }
        var content = ""
        do {
            for try await event in stream {
                if case .textDelta(let text) = event {
                    content += text
                }
            }
            #expect(recover)
        } catch let failure as RecoveryError {
            #expect(!recover)
            #expect(failure.outcome == .admissionRejected)
            #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
            #expect(failure.history.count == 1)
        }
        #expect(count.value.withLock { $0 } == 1)
        #expect(content == (recover ? "recovered" : ""))
        let bodies = server.requests.withLock { $0 }
        #expect(bodies.count == (recover ? 3 : 2))
        if recover {
            #expect(bodies[1] == bodies[2])
        }
        let fields = try JSONDecoder().decode(JSONValue.self, from: bodies[1]).objectValue
        if case .array(let messages)? = fields?["messages"] {
            #expect(messages.contains { $0.objectValue?["role"] == "tool" })
            #expect(String(describing: messages).contains("tool-sentinel"))
        } else {
            Issue.record("Missing follow-up tool history")
        }
        if session {
            #expect(await chat.messages().map(\.role) == (recover ? [.user, .assistant] : []))
        }
    }

    @Test(arguments: [false, true])
    func recoveryPreservesStreamingToolDepth(_ omlx: Bool) async throws {
        let boundary = StreamingBoundary(omlx: omlx, single: false)
        let toolReply = try RecoveryReply(body: boundary.frame(tool: true, done: true))
        let server = try RecoveryLoopback(replies: [
            toolReply, RecoveryReply(status: 503, body: "busy"), toolReply,
        ])
        let count = RecoveryToolCounter()
        let broker = LLMBroker(gateway: boundary.gateway(server, recoveryPolicy(RecoveryRecorder())))
        do {
            for try await _ in broker.stream(
                model: "fixture",
                messages: [],
                tools: [RecoveryCountingTool(calls: count)],
                config: CompletionConfig(maxToolIterations: 2),
            ) {}
            Issue.record("Expected tool depth failure")
        } catch MojenticError.toolDepthExceeded(let limit) { #expect(limit == 2) }
        #expect(count.value.withLock { $0 } == 2)
        #expect(server.requests.withLock { $0.count } == 3)
    }

    @Test(arguments: [false, true])
    func brokerSingleTurnRetainsTypedRecovery(_ omlx: Bool) async throws {
        let boundary = StreamingBoundary(omlx: omlx, single: true)
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 504, body: "busy")])
        let broker = LLMBroker(gateway: boundary.gateway(server, recoveryPolicy(RecoveryRecorder())))
        var terminals = 0
        for await event in broker.generateStreamEvents(model: "fixture", messages: []) {
            if case .error(.recovery(let failure)) = event {
                terminals += 1
                #expect(failure.outcome == .exhausted)
                #expect(failure.history.count == 2)
                #expect(failure.failure.status == 504)
                #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
            } else if event.isTerminal {
                Issue.record("Unexpected terminal")
            }
        }
        #expect(terminals == 1)
        #expect(server.requests.withLock { $0.count } == 2)
    }
}
