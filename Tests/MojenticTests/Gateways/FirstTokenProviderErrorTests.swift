import Foundation
@testable import Mojentic
import Testing

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenProviderErrorTests {
    @Test(
        arguments: StreamingBoundary.all.filter(\.single),
        [(false, false), (false, true), (true, false), (true, true)])
    func providerErrorEndsObservationBeforeTrailingFrames(
        _ boundary: StreamingBoundary, _ scenario: (Bool, Bool)
    ) async throws {
        let (recovery, before) = scenario
        let error = boundary.omlx ? "data: {\"error\":\"busy\"}\n\n" : "{\"error\":\"busy\"}\n"
        let prefix = before ? try boundary.frame(content: "before") : ""
        let body = prefix + error + (try boundary.frame(content: "after terminal", done: true))
        let server = try InProcessHTTPFixture(replies: [RecoveryReply(body: body)])
        let gateway = boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil)
        let result = try await firstTokenOutcome(boundary, gateway: gateway, recovering: recovery)
        let terminal = recovery ? (before ? "interrupted" : "malformedResponse") : "error"
        try assertFirstToken(result, kind: before ? "content" : nil, terminal: terminal)
        #expect(result.content == (before ? "before" : ""))
        let cause: (any Error)?
        if let failure = result.failure as? RecoveryError {
            cause = failure.failure.inspectEvidence().cause
        } else {
            cause = result.failure
        }
        guard case .providerError(let status, let detail) = cause as? MojenticError else {
            Issue.record("Provider error must retain its exact typed cause")
            return
        }
        #expect(status == nil)
        #expect(detail == .string("busy"))
        #expect(server.requests.withLock { $0.count } == 1)
    }
}
