import Foundation
@testable import Mojentic
import Testing

#if anthropic
    struct AnthropicStopSequenceTests {
        @Test(arguments: [
            "complete", "completeJSON", "completeStructured", "streamRecovering",
            "completeStreamEventsRecovering",
        ])
        func successfulStopSequencePreservesEvidence(_ entrypoint: String) async throws {
            let streaming = entrypoint.contains("Recovering")
            let text = #"{"answer":"é思"}"#
            let body = try stopSequenceBody(streaming: streaming, text: text)
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let recorder = RecoveryRecorder()
            let gateway = AnthropicGateway(
                apiKey: "credential-sentinel", baseURL: server.url, recovery: recoveryPolicy(recorder),
            )
            let schema: JSONValue = ["type": "object"]
            let messages: [LLMMessage] = [.user("stop-sequence-probe")]
            var response: LLMGatewayResponse?
            var evidence: CompletionEvidence?
            var content = ""
            var order: [String] = []
            switch entrypoint {
            case "complete":
                response = try await gateway.complete(
                    model: "fixture", messages: messages, tools: nil, config: .init(),
                )
            case "completeJSON":
                let value = try await gateway.completeJSON(
                    model: "fixture", messages: messages, schema: schema, config: .init(),
                )
                #expect(value == ["answer": "é思"])
            case "completeStructured":
                let value = try await gateway.completeStructured(
                    model: "fixture", messages: messages, schema: schema, config: .init(),
                )
                #expect(value.value == ["answer": "é思"])
                response = value.response
            case "streamRecovering":
                for try await event in gateway.streamRecovering(
                    model: "fixture", messages: messages, tools: nil, config: .init(),
                ) {
                    #expect(order.last != "done")
                    switch event {
                    case .textDelta(let text):
                        content += text
                        order.append("content")
                    case .metrics(let value):
                        evidence = value
                        order.append("metrics")
                    case .done(let reason, let usage):
                        #expect(reason == .stop)
                        #expect(usage == evidence?.usage)
                        order.append("done")
                    case .progress: break
                    default: Issue.record("Unexpected reasoning or tool event")
                    }
                }
                #expect(order == ["metrics", "content", "metrics", "done"])
            default:
                for await event in gateway.completeStreamEventsRecovering(
                    model: "fixture", messages: messages, config: .init(),
                ) {
                    #expect(order.last != "completed")
                    switch event {
                    case .content(let text):
                        content += text
                        order.append("content")
                    case .metrics(let value):
                        evidence = value
                        order.append("metrics")
                    case .completed(let value):
                        #expect(value == evidence)
                        order.append("completed")
                    case .progress: break
                    default: Issue.record("Unexpected terminal failure")
                    }
                }
                #expect(order == ["metrics", "content", "metrics", "completed"])
            }
            if let response {
                #expect(response.content == text)
                #expect(response.toolCalls.isEmpty)
                // Retain the existing buffered mapping and original raw provider evidence.
                #expect(response.finishReason == .other)
                evidence = CompletionEvidence(
                    finishReason: response.providerFinishReason,
                    usage: response.usage,
                    providerModel: response.providerModel,
                    metadata: response.metadata,
                )
            }
            if streaming {
                #expect(content == text)
            }
            if entrypoint != "completeJSON" {
                let evidence = try #require(evidence)
                #expect(evidence.finishReason == "stop_sequence")
                #expect(evidence.usage?.promptTokens == 3)
                #expect(evidence.usage?.completionTokens == 4)
                #expect(evidence.providerModel == "payload-sentinel")
                #expect(evidence.metadata == ["id": "credential-sentinel"])
            }
            try assertWireEvidence(recorder, server, body: body, streaming: streaming)
            try retainStopSequenceCapture(recorder, server, entrypoint: entrypoint)
        }

        private func stopSequenceBody(streaming: Bool, text: String) throws -> String {
            if streaming {
                return try StreamingBoundary(omlx: true, single: false, anthropic: true).anthropicFrame(
                    content: text,
                    reasoning: "",
                    tool: false,
                    done: true,
                    reason: "stop_sequence",
                    metrics: false,
                )
            }
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            return """
                {"id":"credential-sentinel","model":"payload-sentinel","content":[
                {"type":"text","text":"\(escaped)"}],
                "stop_reason":"stop_sequence","usage":{"input_tokens":3,"output_tokens":4}}
                """
        }

        @Test(arguments: [false, true])
        func legacyStopSequenceMappingRemainsOther(_ streaming: Bool) async throws {
            let body = try stopSequenceBody(streaming: streaming, text: "legacy")
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let gateway = AnthropicGateway(apiKey: "fixture-key", baseURL: server.url)
            if streaming {
                var content = ""
                var finishes: [FinishReason?] = []
                for try await event in gateway.stream(
                    model: "fixture", messages: [], tools: nil, config: .init(),
                ) {
                    switch event {
                    case .textDelta(let text): content += text
                    case .done(let reason, _): finishes.append(reason)
                    default: Issue.record("Unexpected legacy event")
                    }
                }
                #expect(content == "legacy")
                #expect(finishes == [.other])
            } else {
                let response = try await gateway.complete(
                    model: "fixture", messages: [], tools: nil, config: .init(),
                )
                #expect(response.content == "legacy")
                #expect(response.finishReason == .other)
                #expect(response.providerFinishReason == "stop_sequence")
            }
            #expect(server.requests.withLock { $0.count } == 1)
        }

        private func assertWireEvidence(
            _ recorder: RecoveryRecorder, _ server: RecoveryLoopback, body: String, streaming: Bool,
        ) throws {
            let requests = recorder.requests.withLock { $0 }
            #expect(requests.count == 1)
            #expect(requests.map(\.1) == server.requests.withLock { $0 })
            let request = try #require(requests.first)
            #expect(request.0.wireNumber == 1)
            #expect(request.0.logicalID != request.0.attemptID)
            let fields = try JSONDecoder().decode(JSONValue.self, from: request.1).objectValue
            #expect(fields?["model"] == "fixture")
            #expect(fields?["stream"] == .bool(streaming))
            #expect(fields?["messages"] == [["role": "user", "content": "stop-sequence-probe"]])
            #expect(server.requestHeaders.withLock { $0.first?.hasPrefix("POST /messages HTTP/1.1") } == true)
            var received = Data()
            for wire in recorder.wires.withLock({ $0 }) {
                switch wire {
                case .request(let identity, let url, let headers, let bytes):
                    #expect(identity == request.0)
                    #expect(url == server.url.appendingPathComponent("messages"))
                    #expect(headers["x-api-key"] == "credential-sentinel")
                    #expect(bytes == request.1)
                case .headers(let identity, let status, _):
                    #expect(identity == request.0)
                    #expect(status == 200)
                case .body(let identity, let bytes):
                    #expect(identity == request.0)
                    received.append(bytes)
                }
            }
            #expect(received == Data(body.utf8))
            let events = recorder.events.withLock { $0 }
            #expect(events.map(\.transition) == [.attemptStarted, .attemptSucceeded])
            #expect(events.allSatisfy { $0.identity == request.0 })
        }
    }
#endif
