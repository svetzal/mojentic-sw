import Foundation
@testable import Mojentic
import Testing

struct StreamingRecoveryProofTests {
    @Test(arguments: [false, true])
    func publicHTTPRecovery(omlx: Bool) async throws {
        let success =
            if omlx {
                "data: {\"choices\":[{\"delta\":{\"content\":\"é\"},\"finish_reason\":\"stop\"}]}\n\n"
                    + "data: [DONE]\n\n"
            } else {
                "{\"message\":{\"content\":\"é\"},\"done\":true,\"done_reason\":\"stop\"}\n"
            }
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "credential-sentinel"), RecoveryReply(body: success),
        ])
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        let gateway = RecoveryBoundary(omlx: omlx, structured: false).gateway(server, policy: policy)
        var content = ""
        for try await event in gateway.streamRecovering(
            model: "fixture",
            messages: [.user("payload-sentinel")],
            tools: nil,
            config: .init(),
        ) {
            if case .textDelta(let text) = event {
                content += text
            }
        }
        #expect(content == "é")
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let last = try #require(requests.last)
        #expect(first.1 == last.1)
        #expect(first.0.logicalID == last.0.logicalID)
        #expect(first.0.attemptID != last.0.attemptID)
        #expect(last.0.wireNumber == 2)
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition.rawValue) == [
                "attemptStarted", "attemptFailed", "admissionPending", "admissionAllowed", "delayScheduled",
                "retryStarted", "attemptStarted", "attemptSucceeded",
            ]
        )
        #expect(events.first(where: { $0.transition == .attemptFailed })?.status == 503)
        #expect(events.last?.progress.delivered.contentBytes == 2)
        #expect(server.requests.withLock { $0.count } == 2)
        let report = try #require(reports.withLock { $0.last })
        let failed = try #require(report.history.first)
        #expect(report.history.count == 1)
        #expect(failed.identity == first.0)
        #expect(failed.status == 503)
        #expect(failed.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        #expect(failed.inspectEvidence().body == Data("credential-sentinel".utf8))
        let captured = recorder.wires.withLock { wires in
            wires.reduce(into: [UUID: Data]()) { bytes, event in
                if case .body(let identity, let data) = event {
                    bytes[identity.attemptID, default: Data()].append(data)
                }
            }
        }
        #expect(captured[first.0.attemptID] == Data("credential-sentinel".utf8))
        #expect(captured[last.0.attemptID] == Data(success.utf8))
        #expect(!String(reflecting: report).contains("sentinel"))
    }
}
