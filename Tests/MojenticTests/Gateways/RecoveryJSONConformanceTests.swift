import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryJSONConformanceTests {
    @Test(arguments: RecoveryStatusBoundary.all.filter { $0.operation == .json })
    func completeJSONRetrySuccess(_ boundary: RecoveryStatusBoundary) async throws {
        let rejected = statusReply(503, attempt: 1, truncated: false)
        let success = try boundary.buffered.success()
        let server = try InProcessHTTPFixture(replies: [rejected, success])
        let recorder = RecoveryRecorder()
        let admissions = RecoveryLocked<[(RecoveryFailure, Int)]>([])
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
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
        let delivered = RecoveryLocked<[String]>([])
        try await boundary.invoke(boundary.provider.gateway(server, policy: policy), delivered: delivered)
        #expect(delivered.withLock { $0 } == ["json:42"])
        let identities = try assertStatusWires(recorder, server: server, replies: [rejected, success])
        let first = try #require(identities.first)
        let last = try #require(identities.last)
        let request = try #require(recorder.requests.withLock { $0.first?.1 })
        let fields = try JSONDecoder().decode(JSONValue.self, from: request).objectValue
        #expect(fields?["model"] == "fixture")
        #expect(fields?["stream"] == false)
        if boundary.provider.anthropic {
            #expect(fields?["system"]?.stringValue?.contains("Schema:") == true)
        } else if boundary.provider.omlx {
            #expect(fields?["response_format"] != nil)
        } else {
            #expect(fields?["format"] == ["type": "object"])
        }
        let admitted = admissions.withLock { $0 }
        #expect(admitted.map(\.0.identity) == [first])
        #expect(admitted.map(\.1) == [2])
        try assertStatusFailure(#require(admitted.first?.0), identity: first, reply: rejected)
        let published = reports.withLock { $0 }
        #expect(published.count == 1)
        let report = try #require(published.first)
        #expect(report.logicalID == last.logicalID)
        #expect(report.identity == last)
        #expect(report.history.map(\.identity) == [first])
        try assertStatusFailure(#require(report.history.first), identity: first, reply: rejected)
        #expect(report.progress.headersReceived)
        #expect(report.progress.rawBytes == success.body.utf8.count)
        var observed = RecoverySemanticProgress()
        observed.contentBytes = #"{"answer":42}"#.utf8.count
        observed.reasoningBytes = 9
        var expectedDelivered = observed
        if boundary.provider.openAI {
            expectedDelivered.reasoningBytes = 0
        }
        #expect(report.progress.observed == observed)
        #expect(report.progress.delivered == expectedDelivered)
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition) == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled,
                .retryStarted, .attemptStarted, .attemptSucceeded,
            ]
        )
        #expect(events.map(\.identity) == [first, first, first, first, first, last, last, last])
        #expect(events.map(\.logicalID) == Array(repeating: first.logicalID, count: 8))
        #expect(events.last?.progress == report.progress)
        for event in events.prefix(5).dropFirst() {
            #expect(event.progress.rawBytes == rejected.body.utf8.count)
            #expect(event.progress.headersReceived)
            #expect(event.progress.observed == RecoverySemanticProgress())
            #expect(event.progress.delivered == RecoverySemanticProgress())
        }
    }
}
