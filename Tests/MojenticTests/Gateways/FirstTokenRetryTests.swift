import Foundation
@testable import Mojentic
import Testing

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenRetryTests {
    @Test(arguments: StreamingBoundary.withAnthropic)
    func allRecoveryRoutesKeepOneClockAcrossAdmittedRetry(_ boundary: StreamingBoundary) async throws {
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(status: 503, body: "busy"),
            RecoveryReply(body: boundary.frame(content: "answer", reasoning: "thought", done: true)),
        ])
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.timing.sleep = { _ in TestStreamClock.current?.advance(150) }
        let result = try await firstTokenOutcome(
            boundary, gateway: boundary.gateway(server, policy), recovering: true)
        try assertFirstToken(
            result, kind: "thinking", terminal: boundary.single ? "completed" : "done", minimum: 150)
        #expect(result.content == "answer")
        #expect(result.evidence?.metadata?["time_to_first_token_ms"] == .number(150))
        #expect(result.evidence?.metadata?["request_duration_ms"] == .number(150))
        #expect(server.requests.withLock { $0.count } == 2)
    }
}
