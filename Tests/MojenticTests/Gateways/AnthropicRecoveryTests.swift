import Foundation
@testable import Mojentic
import Testing

#if anthropic
    struct AnthropicRecoveryTests {
        @Test
        func completeJSONRetriesFrozenSchemaAndSupportedThinking() async throws {
            let boundary = RecoveryBoundary(omlx: true, structured: true, anthropic: true)
            let server = try RecoveryLoopback(replies: [
                RecoveryReply(status: 503, body: "busy"), boundary.success(),
            ])
            let recorder = RecoveryRecorder()
            let schema: JSONValue = ["type": "object", "properties": ["answer": ["type": "integer"]]]
            let value = try await AnthropicGateway(
                apiKey: "credential-sentinel", baseURL: server.url, recovery: recoveryPolicy(recorder),
            ).completeJSON(
                model: "claude-sonnet-4-5",
                messages: [.system("system-sentinel"), .user("payload-sentinel")],
                schema: schema,
                config: CompletionConfig(temperature: 0.25, maxTokens: 8192, topP: 0.8, reasoning: .high),
            )
            #expect(value == ["answer": 42])
            let bodies = server.requests.withLock { $0 }
            #expect(bodies == recorder.requests.withLock { $0.map(\.1) })
            #expect(bodies.count == 2)
            #expect(bodies[0] == bodies[1])
            let headers = server.requestHeaders.withLock { $0 }
            #expect(headers.count == 2)
            #expect(headers.allSatisfy { $0.hasPrefix("POST /messages HTTP/1.1") })
            #expect(headers.allSatisfy { $0.lowercased().contains("x-api-key: credential-sentinel") })
            #expect(headers.allSatisfy { $0.lowercased().contains("anthropic-version: 2023-06-01") })
            let root = try JSONDecoder().decode(JSONValue.self, from: bodies[0]).objectValue
            #expect(root?["thinking"] == ["type": "enabled", "budget_tokens": 2048])
            #expect(root?["max_tokens"] == 8192)
            #expect(root?["temperature"] == 0.25)
            #expect(root?["top_p"] == 0.8)
            #expect(root?["messages"] == [["role": "user", "content": "payload-sentinel"]])
            let system = try #require(root?["system"]?.stringValue)
            #expect(system.hasPrefix("system-sentinel\n\nRespond with ONLY"))
            let encodedSchema = try #require(system.components(separatedBy: "Schema: ").last)
            #expect(try JSONDecoder().decode(JSONValue.self, from: Data(encodedSchema.utf8)) == schema)
            assertRecoveryRequests(recorder, server)
        }

        @Test(arguments: [false, true], ["end_turn", "max_tokens"])
        func terminalUsageAndToolsRespectFinish(_ single: Bool, _ reason: String) async throws {
            let boundary = StreamingBoundary(omlx: true, single: single, anthropic: true)
            let body = try boundary.frame(tool: !single, done: true, reason: reason, metrics: true)
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let recorder = RecoveryRecorder()
            let gateway = boundary.gateway(server, recoveryPolicy(recorder))
            let metrics = RecoveryLocked<[CompletionEvidence]>([])
            let seen = RecoveryLocked<[String]>([])
            var failure: RecoveryError?
            if single {
                for await event in try gateway.completeStreamEventsRecovering(
                    model: "fixture", messages: [], config: .init(),
                ) {
                    switch event {
                    case .metrics(let evidence):
                        metrics.withLock { $0.append(evidence) }
                        seen.withLock { $0.append("metrics") }
                    case .completed(let evidence):
                        #expect(evidence == metrics.withLock { $0.last })
                        seen.withLock { $0.append("completed") }
                    case .recoveryFailure(let error):
                        failure = error
                        seen.withLock { $0.append("failed") }
                    default: Issue.record("Unexpected terminal-only single-turn event")
                    }
                }
            } else {
                do {
                    for try await event in gateway.streamRecovering(
                        model: "fixture", messages: [], tools: nil, config: .init(),
                    ) {
                        switch event {
                        case .metrics(let evidence):
                            metrics.withLock { $0.append(evidence) }
                            seen.withLock { $0.append("metrics") }
                        case .toolCallRequest(let call):
                            #expect(
                                call
                                    == LLMToolCall(
                                        id: "original-tool",
                                        name: "resolve_date",
                                        arguments: ["relative": "tomorrow"],
                                    )
                            )
                            seen.withLock { $0.append("tool") }
                        case .done(let finish, let usage):
                            #expect(finish == .toolCalls)
                            #expect(usage == Usage(promptTokens: 3, completionTokens: 12, totalTokens: 15))
                            seen.withLock { $0.append("completed") }
                        default: Issue.record("Unexpected terminal-only tool event")
                        }
                    }
                } catch let error as RecoveryError {
                    failure = error
                    seen.withLock { $0.append("failed") }
                }
            }
            let evidence = metrics.withLock { $0 }
            assertTerminalMetrics(evidence, single: single, reason: reason)
            if reason == "max_tokens" {
                let error = try #require(failure)
                let cause = try #require(error.failure.inspectEvidence().cause as? MojenticError)
                guard case .incompleteCompletion(let original) = cause else {
                    Issue.record("Missing finish cause")
                    return
                }
                #expect(original == evidence.last)
                #expect(error.outcome == (single ? .malformedResponse : .interrupted))
                #expect(error.failure.progress.observed.completedToolCalls == (single ? 0 : 1))
                #expect(error.failure.progress.delivered.completedToolCalls == 0)
                #expect(error.history.count == 1)
                #expect(error.failure.inspectEvidence().body == Data(body.utf8))
                #expect(seen.withLock { $0 } == ["metrics", "metrics", "failed"])
                #expect(
                    recorder.events.withLock { $0.map(\.transition) } == [
                        .attemptStarted, .attemptFailed, error.outcome,
                    ]
                )
                #expect(!String(reflecting: error).contains("sentinel"))
            } else {
                #expect(failure == nil)
                #expect(
                    seen.withLock { $0 }
                        == (single
                            ? ["metrics", "metrics", "completed"]
                            : ["metrics", "metrics", "tool", "completed"])
                )
                #expect(
                    recorder.events.withLock { $0.map(\.transition) } == [.attemptStarted, .attemptSucceeded]
                )
            }
            #expect(!String(reflecting: evidence).contains("sentinel"))
            let safe = try JSONEncoder().encode(recorder.events.withLock { $0 })
            #expect(!(String(data: safe, encoding: .utf8) ?? "").contains("sentinel"))
            assertRecoveryRequests(recorder, server)
        }

        private func assertTerminalMetrics(_ evidence: [CompletionEvidence], single: Bool, reason: String) {
            #expect(
                evidence == [
                    CompletionEvidence(
                        usage: Usage(promptTokens: 3, completionTokens: 0, totalTokens: 3),
                        providerModel: "payload-sentinel",
                        metadata: ["id": "credential-sentinel"],
                    ),
                    CompletionEvidence(
                        finishReason: reason == "end_turn" && !single ? "tool_use" : reason,
                        usage: Usage(promptTokens: 3, completionTokens: 12, totalTokens: 15),
                        providerModel: "payload-sentinel",
                        metadata: ["id": "credential-sentinel"],
                    ),
                ]
            )
        }

        @Test(arguments: [false, true], [false, true])
        func malformedAndProviderErrorsAreTerminal(_ single: Bool, _ provider: Bool) async throws {
            let boundary = StreamingBoundary(omlx: true, single: single, anthropic: true)
            let providerError = #"""
                {"type":"error","error":{"type":"overloaded_error",\#
                "message":"credential-sentinel payload-sentinel"}}
                """#
            let malformed = #"""
                {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"secret"}}
                """#
            let payload = provider ? providerError : malformed
            let body = "event: error\ndata: \(payload)\n\n"
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let recorder = RecoveryRecorder()
            let error = try await recoveryFailure {
                try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)))
            }
            #expect(error.outcome == .malformedResponse)
            #expect(error.failure.category == (provider ? .providerResponse : .protocolFailure))
            #expect(error.failure.progress.observed == RecoverySemanticProgress())
            #expect(error.failure.progress.delivered == RecoverySemanticProgress())
            #expect(error.failure.inspectEvidence().body == Data(body.utf8))
            #expect(error.failure.inspectEvidence().cause is MojenticError)
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [
                    .attemptStarted, .attemptFailed, .malformedResponse,
                ]
            )
            #expect(!String(reflecting: error).contains("sentinel"))
            assertRecoveryRequests(recorder, server)
        }

        static let invalidUsagePayloads = [
            "[DONE]",
            #"{"type":"message_start","message":{"role":"assistant","usage":{"input_tokens":-1}}}"#,
        ]

        @Test(arguments: [false, true], invalidUsagePayloads)
        func invalidUsageAndForeignTerminalProduceNoMetrics(_ single: Bool, _ payload: String) async throws {
            let boundary = StreamingBoundary(omlx: true, single: single, anthropic: true)
            let body = "data: \(payload)\n\n"
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let recorder = RecoveryRecorder()
            let seen = RecoveryLocked<[String]>([])
            let failure = try await recoveryFailure {
                try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)), record: seen)
            }
            #expect(failure.outcome == .malformedResponse)
            #expect(failure.failure.category == .protocolFailure)
            #expect(failure.failure.progress.observed == RecoverySemanticProgress())
            #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
            #expect(failure.failure.inspectEvidence().body == Data(body.utf8))
            #expect(failure.failure.inspectEvidence().cause is MojenticError)
            #expect(seen.withLock { $0.isEmpty })
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [
                    .attemptStarted, .attemptFailed, .malformedResponse,
                ]
            )
            assertRecoveryRequests(recorder, server)
        }

        @Test
        func legacyLengthFinishAndUnsupportedSingleTurnStayUnchanged() async throws {
            let reply = RecoveryReply(
                body: #"{"content":[{"type":"text","text":"legacy"}],"stop_reason":"max_tokens"}"#
            )
            let server = try RecoveryLoopback(replies: [reply])
            let gateway = AnthropicGateway(apiKey: "fixture-key", baseURL: server.url)
            #expect(
                try await gateway.complete(model: "fixture", messages: [], tools: nil, config: .init())
                    .finishReason == .length
            )
            do {
                _ = try gateway.completeStreamEvents(model: "fixture", messages: [], config: .init())
                Issue.record("Legacy single turn should remain unsupported")
            } catch {
                guard case .streamEventsUnsupported = error else {
                    Issue.record("Unexpected legacy error")
                    return
                }
            }
            #expect(server.requests.withLock { $0.count } == 1)
        }
    }
#endif

/// Exact wire payload and identity assertions shared by public acceptance tests.
func assertRecoveryRequests(_ recorder: RecoveryRecorder, _ server: RecoveryLoopback) {
    let requests = recorder.requests.withLock { $0 }
    #expect(requests.map(\.1) == server.requests.withLock { $0 })
    #expect(!requests.isEmpty)
    let identities = requests.map(\.0)
    #expect(Set(identities.map(\.attemptID)).count == identities.count)
    #expect(identities.map(\.wireNumber) == Array(1...identities.count))
    #expect(identities.allSatisfy { $0.logicalID == identities.first?.logicalID })
    let events = recorder.events.withLock { $0 }
    #expect(events.allSatisfy { $0.logicalID == identities.first?.logicalID })
    #expect(events.allSatisfy { event in identities.contains { $0 == event.identity } })
    if requests.count > 1 {
        #expect(requests.dropFirst().allSatisfy { $0.1 == requests[0].1 })
    }
}
