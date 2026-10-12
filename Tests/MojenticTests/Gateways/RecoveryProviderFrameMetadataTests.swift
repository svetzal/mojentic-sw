import Foundation
@testable import Mojentic
import Testing

struct RecoveryProviderFrameMetadataTests {
    @Test(
        arguments: RecoveryStatusBoundary.all.filter { [.tools, .single].contains($0.operation) },
        ["allowed", "credential", "unknown"],
    )
    func providerFrame(_ boundary: RecoveryStatusBoundary, _ variant: String) async throws {
        let anthropic = boundary.provider.anthropic
        let allowed = anthropic ? "overloaded_error" : "server_error"
        let code =
            variant == "allowed" ? allowed : variant == "credential" ? "credential-sentinel" : "unknown_code"
        var reply = try metadataReply(
            code: code,
            requestID: variant == "credential" ? "credential-sentinel" : "req-unrelated-frame",
            anthropic: anthropic,
        )
        reply.status = 200
        reply.body = boundary.provider.omlx ? "event: error\ndata: \(reply.body)\n\n" : reply.body + "\n"
        let server = try RecoveryLoopback(replies: [reply])
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder, attempts: 1)
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        let error = try await recoveryFailure {
            try await invokeMetadataBoundary(
                boundary, gateway: boundary.provider.gateway(server, policy: policy))
        }
        let identities = try assertStatusWires(recorder, server: server, replies: [reply])
        let report = try #require(reports.withLock { $0.first })
        #expect(error.history.map(\.identity) == identities.map(Optional.some))
        #expect(report.history.map(\.identity) == identities.map(Optional.some))
        for failure in error.history + [error.failure] + report.history {
            #expect(failure.category == .providerResponse)
            #expect(failure.providerCode == (variant == "allowed" ? allowed : nil))
            #expect(failure.inspectEvidence().providerCode == failure.providerCode)
            #expect(failure.providerRequestID == (variant == "credential" ? nil : "req-unrelated-frame"))
            #expect(failure.inspectEvidence().providerRequestID == failure.providerRequestID)
            try assertExactMetadataHeaders(failure, recorder: recorder)
            #expect(failure.inspectEvidence().body == Data(reply.body.utf8))
            let cause = try #require(failure.inspectEvidence().cause as? MojenticError)
            guard case .providerError(let status, let detail) = cause else {
                Issue.record("Expected typed provider cause")
                return
            }
            #expect(status == nil)
            #expect(detail == .object([anthropic ? "type" : "code": .string(code)]))
        }
        try assertMetadataPayload(#require(recorder.requests.withLock { $0.first?.1 }), boundary: boundary)
    }
}
