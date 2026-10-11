import Foundation
@testable import Mojentic
import Testing

struct OpenAIRecoveryTests {
    @Test(arguments: [false, true], ["stop", "length"])
    func terminalUsagePrecedesOutcomeAndExcludesEchoes(_ single: Bool, _ reason: String) async throws {
        let boundary = StreamingBoundary(omlx: true, single: single, openAI: true)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: boundary.frame(done: true, reason: reason, metrics: true))
        ])
        let seen = RecoveryLocked<[String]>([])
        let recorder = RecoveryRecorder()
        if reason == "stop" {
            try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)), record: seen)
            #expect(seen.withLock { $0 } == ["metrics", "completed"])
        } else {
            let failure = try await recoveryFailure {
                try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)), record: seen)
            }
            #expect(seen.withLock { $0 } == ["metrics"])
            let cause = try #require(failure.failure.inspectEvidence().cause as? MojenticError)
            guard case .incompleteCompletion(let evidence) = cause else {
                Issue.record("Expected original finish evidence")
                return
            }
            #expect(evidence.finishReason == "length")
            #expect(evidence.usage?.completionTokens == 12)
            #expect(evidence.providerModel == "payload-sentinel")
        }
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true])
    func multipleChoicesAreMalformedWithoutDelivery(_ single: Bool) async throws {
        let body = #"data: {"choices":[{"delta":{}},{"delta":{"content":"hidden"}}]}"# + "\n\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let boundary = StreamingBoundary(omlx: true, single: single, openAI: true)
        let seen = RecoveryLocked<[String]>([])
        let failure = try await recoveryFailure {
            try await boundary.consume(
                boundary.gateway(server, recoveryPolicy(RecoveryRecorder())), record: seen,
            )
        }
        #expect(failure.outcome == .malformedResponse)
        #expect(!failure.failure.eligible)
        #expect(seen.withLock { $0.isEmpty })
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true])
    func singleTurnRejectedToolsRetainAllObservedSemantics(_ captureFails: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: true, openAI: true)
        let body = try boundary.frame(content: "é", reasoning: "想", tool: true)
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if captureFails, case .body = event {
                throw RecoveryCaptureSentinel()
            }
        }
        let seen = RecoveryLocked<[String]>([])
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, policy), record: seen)
        }
        #expect(failure.outcome == (captureFails ? .captureFailed : .interrupted))
        #expect(failure.failure.progress.observed.contentBytes == 2)
        #expect(failure.failure.progress.observed.reasoningBytes == 3)
        #expect(failure.failure.progress.observed.toolFragments == 1)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(failure.failure.inspectEvidence().body == Data(body.utf8))
        if captureFails {
            #expect(failure.failure.inspectEvidence().cause is RecoveryCaptureSentinel)
        } else {
            guard case .unexpectedToolCalls? = failure.failure.inspectEvidence().cause as? MojenticError
            else {
                Issue.record("Expected original single-turn tool rejection")
                return
            }
        }
        #expect(failure.history.count == 1)
        #expect(seen.withLock { $0.isEmpty })
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(!recorder.events.withLock { $0.map(\.transition) }.contains(.retryStarted))
    }

    @Test(arguments: [false, true], [false, true])
    func legacyStreamsRemainSingleSendWithPolicy(_ single: Bool, _ enabled: Bool) async throws {
        let frame =
            #"""
            data: {"choices":[{"delta":{"content":"ok","reasoning_content":"private"},\#
            "finish_reason":"stop"}]}
            """#
        let body = frame + "\n\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        let gateway = OpenAIGateway(
            apiKey: "credential-sentinel",
            baseURL: server.url,
            recovery: enabled ? recoveryPolicy(recorder) : nil,
        )
        if single {
            var result: [String] = []
            for await event in gateway.completeStreamEvents(model: "gpt-4o", messages: [], config: .init()) {
                switch event {
                case .content(let text): result.append(text)
                case .error: result.append("error")
                case .completed: Issue.record("Missing DONE must remain a legacy failure")
                }
            }
            #expect(result == ["ok", "error"])
        } else {
            let seen = try await collect(
                gateway.stream(model: "gpt-4o", messages: [], tools: nil, config: .init())
            )
            #expect(seen == [.text("ok"), .done(.stop, nil)])
        }
        #expect(recorder.events.withLock { $0.isEmpty })
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true], ["choices", "usage", "tools"])
    func malformedBufferedResponsesCannotRetry(_ structured: Bool, _ field: String) async throws {
        let body =
            switch field {
            case "choices": #"{"choices":[]}"#
            case "usage": #"{"choices":[{"message":{"content":"{}"}}],"usage":{"total_tokens":-1}}"#
            default:
                #"""
                {"choices":[{"message":{"content":"{}","tool_calls":[{"id":"t","type":"function",\#
                "function":{"name":"x","arguments":"invalid"}}]}}]}
                """#
            }
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let boundary = RecoveryBoundary(omlx: true, structured: structured, openAI: true)
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(
                boundary.gateway(server, policy: recoveryPolicy(RecoveryRecorder()))
            )
        }
        #expect(failure.outcome == .ineligible)
        #expect(!failure.failure.eligible)
        #expect(
            failure.failure.inspectEvidence().cause is MojenticError
                || failure.failure.inspectEvidence().cause is DecodingError
        )
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: ["gpt-4o", "o3"], [false, true])
    func recoveryPreservesModelShaping(_ model: String, _ structured: Bool) async throws {
        let boundary = RecoveryBoundary(omlx: true, structured: structured, openAI: true)
        let reply = try boundary.success()
        let old = try RecoveryLoopback(replies: [reply])
        let new = try RecoveryLoopback(replies: [RecoveryReply(status: 503, body: "busy"), reply])
        let config = CompletionConfig(temperature: 0.3, maxTokens: 17, topP: 0.8, reasoning: .high)
        for (server, policy) in [(old, nil), (new, recoveryPolicy(RecoveryRecorder()))] {
            let gateway = OpenAIGateway(apiKey: "key", baseURL: server.url, recovery: policy)
            if structured {
                _ = try await gateway.completeJSON(
                    model: model, messages: [.user("original")], schema: ["type": "object"], config: config,
                )
            } else {
                _ = try await gateway.complete(
                    model: model, messages: [.user("original")], tools: nil, config: config,
                )
            }
        }
        let requests = new.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        let fields = try JSONDecoder().decode(JSONValue.self, from: requests[0]).objectValue
        let original = try JSONDecoder().decode(
            JSONValue.self, from: #require(old.requests.withLock { $0.first }),
        ).objectValue
        #expect(fields == original)
        #expect(fields?[model == "o3" ? "max_completion_tokens" : "max_tokens"] == 17)
        #expect(fields?["reasoning_effort"] == (model == "o3" ? "high" : nil))
    }
}
