import Foundation
@testable import Mojentic
import Testing

/// Exercises the clock through the public streaming API at the line transport boundary.
struct StreamMeasurementClockProbeTests {
    @Test
    func firstTokenAndDurationUseInjectedClock() async throws {
        let origin = ContinuousClock.now
        let ticks = RecoveryLocked<Int64>(-25)
        try await StreamMeasurement.$now.withValue({
            origin.advanced(
                by: .milliseconds(
                    ticks.withLock { value in
                        value += 25
                        return value
                    }))
        }) {
            let gateway = OllamaGateway(
                baseURL: try #require(URL(string: "mojentic-fixture://clock")),
                lineTransport: FakeLineTransport(lines: [
                    #"{"message":{"content":"in-process"},"done":true}"#
                ]))
            var text = ""
            var evidence: CompletionEvidence?
            for try await event in gateway.stream(
                model: "fixture", messages: [.user("request")], tools: nil, config: .init())
            {
                if case .textDelta(let value) = event { text += value }
                if case .done(_, _, let value) = event { evidence = value }
            }
            #expect(text == "in-process")
            #expect(evidence?.metadata?["first_token_kind"] == .string("content"))
            #expect(evidence?.metadata?["time_to_first_token_ms"] == .number(25))
            #expect(evidence?.metadata?["request_duration_ms"] == .number(50))
        }
    }
}
