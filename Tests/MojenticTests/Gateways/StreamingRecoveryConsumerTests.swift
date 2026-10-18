import Foundation
@testable import Mojentic
import Testing

struct StreamingRecoveryConsumerTests {
    @Test(
        arguments: StreamingBoundary.withAnthropic.filter { !$0.single },
        [(false, false), (false, true), (true, false), (true, true)],
    )
    func completedToolRunsOnceAcrossFollowUp(
        _ boundary: StreamingBoundary,
        _ mode: (Bool, Bool),
    ) async throws {
        let (session, recover) = mode
        let replies = try [
            RecoveryReply(body: boundary.frame(tool: true, done: true)),
            RecoveryReply(status: 503, body: "busy"),
            RecoveryReply(body: boundary.frame(content: "recovered", done: true)),
        ]
        let server = try RecoveryLoopback(replies: replies)
        let recorder = RecoveryRecorder()
        let admissions = RecoveryLocked<[(RecoveryFailure, Int)]>([])
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, next in
            admissions.withLock { $0.append((failure, next)) }
            return AsyncStream {
                $0.yield(recover ? .allow : .reject)
                $0.finish()
            }
        }
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
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
        var order: [String] = []
        var publicCall: LLMToolCall?
        var rejection: RecoveryError?
        do {
            for try await event in stream {
                switch event {
                case .metrics: break
                case .toolCallRequested(let call):
                    order.append("tool")
                    publicCall = call
                    #expect(call.name == "resolve_date")
                    #expect(call.arguments == ["relative": "tomorrow"])
                    if boundary.omlx {
                        #expect(call.id == "original-tool")
                    }
                case .toolCallResult(let id, let result):
                    order.append("result")
                    #expect(id == publicCall?.id)
                    #expect(result == ["original-result": "tool-sentinel"])
                case .textDelta(let text):
                    order.append("content")
                    #expect(text == "recovered")
                case .done(let response):
                    order.append("done")
                    #expect(response.content == "recovered")
                    #expect(response.finishReason == .stop)
                case .thinkingDelta:
                    Issue.record("Unexpected public reasoning event")
                }
            }
            #expect(recover)
        } catch let failure as RecoveryError {
            rejection = failure
            order.append("rejected")
            #expect(!recover)
            #expect(failure.outcome == .admissionRejected)
            #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
            #expect(failure.history.count == 1)
        }
        #expect(count.value.withLock { $0 } == 1)
        #expect(order == (recover ? ["tool", "result", "content", "done"] : ["tool", "result", "rejected"]))
        let bodies = server.requests.withLock { $0 }
        #expect(bodies.count == (recover ? 3 : 2))
        if recover {
            #expect(bodies[1] == bodies[2])
        }
        let initial = try JSONDecoder().decode(JSONValue.self, from: bodies[0])
        #expect(initial.objectValue?["messages"] == [["role": "user", "content": "original-user"]])
        for body in bodies.dropFirst() {
            try assertStreamingFollowUpHistory(body, boundary: boundary)
        }
        try assertStreamingFollowUpEvidence(
            recorder,
            server: server,
            replies: Array(replies.prefix(recover ? 3 : 2)),
            admissions: admissions.withLock { $0 },
            reports: reports.withLock { $0 },
            rejection: rejection,
        )
        if session {
            let history = await chat.messages()
            #expect(history.map(\.role) == (recover ? [.user, .assistant] : []))
            #expect(history.map(\.content) == (recover ? ["original-user", "recovered"] : []))
        }
    }

    @Test(arguments: StreamingBoundary.withAnthropic.filter { !$0.single }, [false, true])
    func recoveryPreservesStreamingToolDepth(_ boundary: StreamingBoundary, _ session: Bool) async throws {
        let toolReply = try RecoveryReply(body: boundary.frame(tool: true, done: true))
        let server = try RecoveryLoopback(replies: [
            toolReply, RecoveryReply(status: 503, body: "busy"), toolReply,
        ])
        let count = RecoveryToolCounter()
        let recorder = RecoveryRecorder()
        let broker = LLMBroker(gateway: boundary.gateway(server, recoveryPolicy(recorder)))
        let tools: [any LLMTool] = [RecoveryCountingTool(calls: count)]
        let config = CompletionConfig(maxToolIterations: 2)
        let chat = ChatSession(broker: broker, model: "fixture", tools: tools, config: config)
        let stream =
            if session {
                chat.stream("original-user")
            } else {
                broker.stream(
                    model: "fixture", messages: [.user("original-user")], tools: tools, config: config,
                )
            }
        do {
            for try await _ in stream {}
            Issue.record("Expected tool depth failure")
        } catch MojenticError.toolDepthExceeded(let limit) { #expect(limit == 2) }
        #expect(count.value.withLock { $0 } == 2)
        let bodies = server.requests.withLock { $0 }
        #expect(bodies.count == 3)
        #expect(bodies == recorder.requests.withLock { $0.map(\.1) })
        #expect(bodies[1] == bodies[2])
        try assertStreamingFollowUpHistory(bodies[2], boundary: boundary)
        if session {
            #expect(await chat.messages().isEmpty)
        }
    }

    @Test(arguments: StreamingBoundary.withAnthropic.filter { !$0.single })
    func brokerSingleTurnRetainsTypedRecovery(_ boundary: StreamingBoundary) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 504, body: "busy")])
        let broker = LLMBroker(gateway: boundary.gateway(server, recoveryPolicy(RecoveryRecorder())))
        var terminals = 0
        for await event in broker.generateRecoveryStreamEvents(model: "fixture", messages: []) {
            if case .recoveryFailure(let failure) = event {
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
