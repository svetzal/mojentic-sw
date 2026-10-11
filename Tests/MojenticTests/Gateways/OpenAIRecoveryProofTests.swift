import Foundation
@testable import Mojentic
import Testing

struct OpenAIRecoveryProofTests {
    @Test
    func captureFailureRetainsReceivedSemanticsWithoutResend() async throws {
        let body = #"""
            {"choices":[{"message":{"role":"assistant","content":"é","reasoning_content":"思",\#
            "tool_calls":[{"id":"t","type":"function",\#
            "function":{"name":"resolve_date","arguments":"{}"}}]},\#
            "finish_reason":"tool_calls"}]}
            """#
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.wireObserver = { event in
            recorder.wires.withLock { $0.append(event) }
            if case .body = event {
                throw RecoveryCaptureSentinel()
            }
        }
        let gateway = OpenAIGateway(apiKey: "credential-sentinel", baseURL: server.url, recovery: policy)
        let error = try await recoveryFailure {
            _ = try await gateway.complete(
                model: "gpt-4o", messages: [.user("payload-sentinel")], tools: nil, config: .init(),
            )
        }
        #expect(error.outcome == .captureFailed)
        #expect(error.failure.provider == "openai")
        #expect(error.failure.progress.observed.contentBytes == 2)
        #expect(error.failure.progress.observed.reasoningBytes == 3)
        #expect(error.failure.progress.observed.toolFragments == 1)
        #expect(error.failure.progress.delivered == RecoverySemanticProgress())
        #expect(error.failure.inspectEvidence().cause is RecoveryCaptureSentinel)
        #expect(error.failure.inspectEvidence().body == Data(body.utf8))
        #expect(error.history.count == 1)
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .captureFailed,
            ]
        )
        #expect(!String(reflecting: error).contains("sentinel"))
    }
}
