import Foundation
@testable import Mojentic
import Testing

struct RecoveryStatusConformanceTests {
    @Test
    func jsonPermanentTruncationProof() async throws {
        let body = "credential-sentinel é猫 partial"
        let reply = RecoveryReply(
            status: 401, headers: ["X-Recovery-Probe": "exact"], body: body, truncated: true,
        )
        let server = try RecoveryLoopback(replies: [reply])
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
        #if os(Linux)
            #expect(cause.code == .unknown)
        #else
            #expect(cause.code == .networkConnectionLost)
        #endif
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

    private func assertTerminalStatus(
        _ boundary: RecoveryStatusBoundary, status: Int, attempts: Int, truncated: Bool,
    ) async throws {
        let count = status == 504 ? attempts : 1
        let replies = (1...count).map { statusReply(status, attempt: $0, truncated: truncated) }
        let server = try RecoveryLoopback(replies: replies)
        let recorder = RecoveryRecorder()
        let admissions = RecoveryLocked<[(RecoveryFailure, Int)]>([])
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        let delivered = RecoveryLocked<[String]>([])
        var policy = recoveryPolicy(recorder, attempts: attempts)
        policy.retryableStatuses = [400, 401, 403, 504]
        policy.retryableCategories = [.http, .transport, .clientTimeout]
        policy.admission = { failure, next in
            admissions.withLock { $0.append((failure, next)) }
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        policy.reportObserver = { report in
            reports.withLock { $0.append(report) }
        }
        let gateway = boundary.provider.gateway(server, policy: policy)
        let error = try await recoveryFailure { try await boundary.invoke(gateway, delivered: delivered) }
        #expect(delivered.withLock { $0 } == [])
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        let last = try #require(identities.last)
        let outcome: RecoveryTransition = status == 504 ? .exhausted : .ineligible
        #expect(error.outcome == outcome)
        #expect(error.logicalID == last.logicalID)
        #expect(error.history.map(\.identity) == identities.map(Optional.some))
        try assertStatusFailure(error.failure, identity: last, reply: #require(replies.last))
        for (index, failure) in error.history.enumerated() {
            try assertStatusFailure(failure, identity: identities[index], reply: replies[index])
        }
        let admitted = admissions.withLock { $0 }
        #expect(admitted.map(\.0.identity) == identities.dropLast().map(Optional.some))
        #expect(admitted.map(\.1) == Array(2..<(count + 1)))
        for (index, admission) in admitted.enumerated() {
            try assertStatusFailure(admission.0, identity: identities[index], reply: replies[index])
        }
        var transitions: [RecoveryTransition] = []
        var eventIDs: [RecoveryIdentity] = []
        for (index, identity) in identities.enumerated() {
            let prefix: [RecoveryTransition] =
                index == 0 ? [.attemptStarted] : [.retryStarted, .attemptStarted]
            let suffix: [RecoveryTransition] =
                if index == count - 1 {
                    [outcome]
                } else {
                    [.admissionPending, .admissionAllowed, .delayScheduled]
                }
            let steps = prefix + [.attemptFailed] + suffix
            transitions += steps
            eventIDs += steps.map { _ in identity }
        }
        let events = recorder.events.withLock { $0 }
        #expect(events.map(\.transition) == transitions)
        #expect(events.map(\.identity) == eventIDs.map(Optional.some))
        #expect(events.map(\.logicalID) == eventIDs.map(\.logicalID))
        for event in events {
            #expect(event.progress.observed == RecoverySemanticProgress())
            #expect(event.progress.delivered == RecoverySemanticProgress())
            if event.transition != .attemptStarted, event.transition != .retryStarted {
                let identity = try #require(event.identity)
                #expect(event.progress.rawBytes == replies[identity.wireNumber - 1].body.utf8.count)
                #expect(event.progress.headersReceived)
            }
        }
        let published = reports.withLock { $0 }
        #expect(published.count == 1)
        let report = try #require(published.first)
        #expect(report.identity == last)
        #expect(report.logicalID == last.logicalID)
        #expect(report.progress == error.failure.progress)
        #expect(report.history.map(\.identity) == identities.map(Optional.some))
        for (index, failure) in report.history.enumerated() {
            try assertStatusFailure(failure, identity: identities[index], reply: replies[index])
        }
        let safe = try JSONEncoder().encode(events)
        #expect(try !#require(String(bytes: safe, encoding: .utf8)).contains("sentinel"))
        #expect(!String(reflecting: error).contains("sentinel"))
    }
}
