import Foundation
@testable import Mojentic
import Testing

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenHTTPTests {
    private func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number): number
        case .integer(let number): Double(number)
        default: nil
        }
    }

    @Test
    func retryMixedFrameUsesFirstDispatchAndThinkingPrecedence() async throws {
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(status: 503, body: "retry"),
            RecoveryReply(
                body:
                    "data: {\"choices\":[{\"delta\":{\"content\":\"visible\",\"reasoning_co"
                    + "ntent\":\"thought\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            ),
        ])
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.timing.sleep = { _ in TestStreamClock.current?.advance(80) }
        let gateway = StreamingBoundary(omlx: true, single: true, openAI: true).gateway(server, policy)
        var terminal: CompletionEvidence?
        var content = ""
        for await event in try gateway.completeStreamEventsRecovering(
            model: "fixture", messages: [.user("hello")], config: .init()
        ) {
            if case .content(let text) = event { content += text }
            if case .completed(let evidence) = event { terminal = evidence }
            if case .recoveryFailure = event { Issue.record("retry must end in completed") }
        }
        #expect(content == "visible")
        let metadata = try #require(terminal?.metadata)
        #expect(metadata["first_token_kind"] == .string("thinking"))
        let first = try #require(number(metadata["time_to_first_token_ms"]))
        let duration = try #require(number(metadata["request_duration_ms"]))
        #expect(first == 80)
        #expect(duration == 80)
        #expect(server.requests.withLock { $0.count } == 2)
    }
}
