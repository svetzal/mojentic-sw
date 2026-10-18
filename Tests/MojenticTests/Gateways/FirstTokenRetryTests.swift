import Foundation
import Mojentic
import Testing

struct FirstTokenRetryTests {
    @Test(arguments: StreamingBoundary.withAnthropic)
    func allRecoveryRoutesKeepOneClockAcrossAdmittedRetry(_ boundary: StreamingBoundary) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "busy"),
            RecoveryReply(body: boundary.frame(content: "answer", reasoning: "thought", done: true)),
        ])
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.timing.sleep = { _ in try await Task.sleep(for: .milliseconds(150)) }
        let result = try await firstTokenOutcome(
            boundary, gateway: boundary.gateway(server, policy), recovering: true)
        try assertFirstToken(
            result, kind: "thinking", terminal: boundary.single ? "completed" : "done", minimum: 150)
        #expect(result.content == "answer")
        #expect(server.requests.withLock { $0.count } == 2)
    }
}
