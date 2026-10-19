import Foundation
@testable import Mojentic
import Testing

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenToolRouteTests {
    @Test(arguments: StreamingBoundary.all, [false, true])
    func argumentsCountAcrossToolCapableAndRejectingSingleTurnRoutes(
        _ boundary: StreamingBoundary, _ recovery: Bool
    ) async throws {
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(body: boundary.frame(tool: true, done: true))
        ])
        let gateway = boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil)
        let result = try await firstTokenOutcome(boundary, gateway: gateway, recovering: recovery)
        let terminal = boundary.single ? (recovery ? "interrupted" : "error") : "done"
        try assertFirstToken(result, kind: "tool_call", terminal: terminal)
        if boundary.single {
            #expect(result.tools.isEmpty)
            let cause: (any Error)?
            if let failure = result.failure as? RecoveryError {
                cause = failure.failure.inspectEvidence().cause
            } else {
                cause = result.failure
            }
            guard case .unexpectedToolCalls = cause as? MojenticError else {
                Issue.record("Single-turn tool rejection must retain its original typed cause")
                return
            }
        } else {
            #expect(result.tools.count == 1)
            let call = try #require(result.tools.first)
            #expect(call.name == "resolve_date")
            #expect(call.arguments == ["relative": "tomorrow"])
            if boundary.omlx { #expect(call.id == "original-tool") }
        }
    }
}
