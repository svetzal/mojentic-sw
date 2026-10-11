import Foundation
@testable import Mojentic
import Testing

#if anthropic
    struct AnthropicRecoveryProofTests {
        @Test
        func captureFailureRetainsReceivedSemanticsWithoutResend() async throws {
            let body = #"""
                {"id":"payload-sentinel","model":"served","content":[
                {"type":"text","text":"é"},{"type":"thinking","thinking":"思"},
                {"type":"tool_use","id":"t","name":"resolve_date","input":{}}],
                "stop_reason":"tool_use","usage":{"input_tokens":3,"output_tokens":4}}
                """#
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let recorder = RecoveryRecorder()
            var policy = recoveryPolicy(recorder)
            policy.wireObserver = { event in
                recorder.wires.withLock { $0.append(event) }
                if case .request(let identity, _, _, let bytes) = event {
                    recorder.requests.withLock { $0.append((identity, bytes)) }
                }
                if case .body = event {
                    throw RecoveryCaptureSentinel()
                }
            }
            let gateway = AnthropicGateway(
                apiKey: "credential-sentinel", baseURL: server.url, recovery: policy,
            )
            let error = try await recoveryFailure {
                _ = try await gateway.complete(
                    model: "claude-sonnet-4-5",
                    messages: [.user("payload-sentinel")],
                    tools: nil,
                    config: .init(),
                )
            }
            #expect(error.outcome == .captureFailed)
            #expect(error.failure.provider == "anthropic")
            #expect(error.failure.progress.observed.contentBytes == 2)
            #expect(error.failure.progress.observed.reasoningBytes == 3)
            #expect(error.failure.progress.observed.toolFragments == 1)
            #expect(error.failure.progress.observed.completedToolCalls == 1)
            #expect(error.failure.progress.delivered == RecoverySemanticProgress())
            #expect(error.failure.inspectEvidence().cause is RecoveryCaptureSentinel)
            #expect(error.failure.inspectEvidence().body == Data(body.utf8))
            #expect(error.history.count == 1)
            #expect(server.requests.withLock { $0.count } == 1)
            #expect(recorder.requests.withLock { $0.map(\.1) } == server.requests.withLock { $0 })
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [
                    .attemptStarted, .attemptFailed, .captureFailed,
                ]
            )
            #expect(!String(reflecting: error).contains("sentinel"))
        }
    }
#endif
