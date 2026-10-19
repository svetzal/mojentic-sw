import Foundation
@testable import Mojentic
import Testing

#if anthropic
    @Suite(.serialized)
    struct AnthropicLineBoundaryProbeTests {
        @Test
        func publicStreamPreservesToolIdentityArgumentsAndExactTiming() async throws {
            let origin = ContinuousClock.now
            let ticks = RecoveryLocked<Int64>(-25)
            let frames: [JSONValue] = [
                [
                    "type": "content_block_start", "index": 0,
                    "content_block": [
                        "type": "tool_use", "id": "unmasked-tool-id", "name": "lookup", "input": [:],
                    ],
                ],
                [
                    "type": "content_block_delta", "index": 0,
                    "delta": ["type": "input_json_delta", "partial_json": #"{"city":"Toronto"}"#],
                ],
                ["type": "content_block_stop", "index": 0],
                [
                    "type": "message_delta", "delta": ["stop_reason": "tool_use"],
                    "usage": ["output_tokens": 7],
                ],
                ["type": "message_stop"],
            ]
            let lines = try frames.map {
                "data: " + (try #require(String(bytes: JSONEncoder().encode($0), encoding: .utf8)))
            }
            let transport = FakeLineTransport(lines: lines)
            let now: @Sendable () -> ContinuousClock.Instant = {
                origin.advanced(
                    by: .milliseconds(
                        ticks.withLock {
                            $0 += 25
                            return $0
                        }))
            }
            try await StreamMeasurement.$now.withValue(now) {
                let gateway = AnthropicGateway(
                    apiKey: "fixture-key",
                    baseURL: try #require(URL(string: "mojentic-fixture://anthropic")),
                    lineTransport: transport)
                var calls: [LLMToolCall] = []
                var evidence: CompletionEvidence?
                for try await event in gateway.stream(
                    model: "fixture", messages: [.user("lookup Toronto")], tools: nil, config: .init())
                {
                    if case .toolCallRequest(let call) = event { calls.append(call) }
                    if case .done(_, _, let value) = event { evidence = value }
                }
                #expect(calls.map(\.id) == ["unmasked-tool-id"])
                #expect(calls.map(\.name) == ["lookup"])
                #expect(calls.map(\.arguments) == [.object(["city": "Toronto"])])
                #expect(evidence?.metadata?["first_token_kind"] == .string("tool_call"))
                #expect(evidence?.metadata?["time_to_first_token_ms"] == .number(25))
                #expect(evidence?.metadata?["request_duration_ms"] == .number(50))
                #expect(evidence?.usage?.completionTokens == 7)
                let request = try #require(await transport.recorder.requests.first)
                #expect(request.0.absoluteString == "mojentic-fixture://anthropic/messages")
                #expect(request.1 == ["x-api-key": "fixture-key", "anthropic-version": "2023-06-01"])
                let bodies = await transport.recorder.bodies
                #expect(bodies.first?.objectValue?["model"] == "fixture")
                #expect(bodies.first?.objectValue?["stream"] == true)
                #expect(
                    bodies.first?.objectValue?["messages"] == [["role": "user", "content": "lookup Toronto"]])
            }
        }
    }
#endif
