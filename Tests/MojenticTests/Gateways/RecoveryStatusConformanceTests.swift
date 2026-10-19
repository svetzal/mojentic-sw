import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryStatusConformanceTests {
    @Test
    func jsonPermanentTruncationProof() async throws {
        let body = "credential-sentinel é猫 partial"
        let reply = RecoveryReply(
            status: 401, headers: ["X-Recovery-Probe": "exact"], body: body, truncated: true,
        )
        let server = try InProcessHTTPFixture(replies: [reply])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder, attempts: 3)
        policy.retryableStatuses = [400, 401, 403, 504]
        policy.retryableCategories = [.http, .transport]
        let gateway = RecoveryBoundary(omlx: false, structured: true).gateway(server, policy: policy)
        let error = try await recoveryFailure {
            _ = try await gateway.completeJSON(
                model: "fixture",
                messages: [.user("payload-sentinel")],
                schema: ["type": "object"],
                config: .init(),
            )
        }
        #expect(error.outcome == .ineligible)
        #expect(error.failure.status == 401)
        #expect(error.failure.category == .http)
        #expect(!error.failure.eligible)
        #expect(error.failure.inspectEvidence().body == Data(body.utf8))
        let cause = try #require(error.failure.inspectEvidence().cause as? URLError)
        #expect(cause.code == .networkConnectionLost)
        let requests = recorder.requests.withLock { $0 }
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        let identity = try #require(requests.first?.0)
        #expect(try assertStatusWires(recorder, server: server, replies: [reply]) == [identity])
        try assertStatusFailure(error.failure, identity: identity, reply: reply)
        #expect(identity.wireNumber == 1)
        #expect(error.logicalID == identity.logicalID)
        #expect(error.history.map(\.identity) == [identity])
        #expect(error.failure.identity == identity)
        let events = recorder.events.withLock { $0 }
        #expect(events.map(\.transition) == [.attemptStarted, .attemptFailed, .ineligible])
        #expect(events.map(\.identity) == [identity, identity, identity])
        #expect(error.failure.progress.rawBytes == body.utf8.count)
        #expect(error.failure.progress.observed == RecoverySemanticProgress())
        #expect(error.failure.progress.delivered == RecoverySemanticProgress())
    }

    @Test(arguments: RecoveryStatusBoundary.all, [400, 401, 403])
    func permanentStatusesKeepOneSend(_ boundary: RecoveryStatusBoundary, _ status: Int) async throws {
        try await assertTerminalStatus(boundary, status: status, attempts: 3, truncated: true)
    }

    @Test(arguments: RecoveryStatusBoundary.all, [1, 3])
    func persistent504ExhaustsExactLimit(_ boundary: RecoveryStatusBoundary, _ attempts: Int) async throws {
        try await assertTerminalStatus(boundary, status: 504, attempts: attempts, truncated: false)
        try await assertTerminalStatus(boundary, status: 504, attempts: attempts, truncated: true)
    }

    @Test
    func removedDefaultStatusProof() async throws {
        let boundary = RecoveryStatusBoundary(
            provider: .init(omlx: false, structured: false), operation: .single)
        try await assertTerminalStatus(
            boundary,
            status: 500,
            attempts: 3,
            truncated: false,
            selection: .init(statuses: [429, 502, 503, 504], eligible: false),
        )
    }

}
