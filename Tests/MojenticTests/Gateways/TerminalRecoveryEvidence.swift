import Foundation
@testable import Mojentic
import Testing

func verifyTerminalEvidence(
    _ boundary: StreamingBoundary,
    _ body: String,
    _ server: RecoveryLoopback,
    _ recorder: RecoveryRecorder,
    _ reports: RecoveryLocked<[CompletionRecoveryReport]>,
    cancel: Bool,
) throws {
    let requests = recorder.requests.withLock { $0 }
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(server.requests.withLock { $0 } == [request.1])
    #expect(request.0.wireNumber == 1)
    #expect(request.0.logicalID != request.0.attemptID)
    let events = recorder.events.withLock { $0 }
    #expect(events.allSatisfy { $0.identity == request.0 && $0.logicalID == request.0.logicalID })
    let report = try #require(reports.withLock { $0.last })
    #expect(report.logicalID == request.0.logicalID)
    #expect(report.history.count == (cancel ? 1 : 0))
    if cancel {
        let failure = try #require(report.history.first)
        #expect(failure.identity == request.0)
        #expect(failure.status == 200)
        #expect(
            failure.inspectEvidence().headers.first { $0.key.lowercased() == "x-request-id" }?.value
                == "terminal-original"
        )
        #expect(failure.category == .cancellation)
        #expect(failure.inspectEvidence().body == Data(body.utf8))
        #expect(failure.inspectEvidence().cause is CancellationError)
    }
    #expect(report.progress.rawBytes == body.utf8.count)
    #expect(report.progress.headersReceived)
    #expect(report.progress.observed.contentBytes == 2)
    #expect(report.progress.observed.reasoningBytes == 3)
    #expect(report.progress.delivered.contentBytes == 2)
    #expect(report.progress.delivered.reasoningBytes == (boundary.single || boundary.openAI ? 0 : 3))
    #expect(report.progress.observed.toolFragments == 0)
    #expect(report.progress.delivered.toolFragments == 0)
    #expect(report.progress.observed.completedToolCalls == 0)
    #expect(report.progress.delivered.completedToolCalls == 0)
    let wires = recorder.wires.withLock { $0 }
    var response = Data()
    for wire in wires {
        switch wire {
        case .request(let identity, _, _, let bytes):
            #expect(identity == request.0)
            #expect(bytes == request.1)
        case .headers(let identity, let status, _):
            #expect(identity == request.0)
            #expect(status == 200)
        case .body(let identity, let bytes):
            #expect(identity == request.0)
            response.append(bytes)
        }
    }
    #expect(response == Data(body.utf8))
}

func verifyPublicTerminalCancellation(
    _ consumer: TerminalRecoveryConsumer, _ reports: RecoveryLocked<[CompletionRecoveryReport]>, body: String,
) async throws {
    do {
        _ = try await consumer.next()
        Issue.record("Expected typed cancellation, without delivered completion")
    } catch let failure as RecoveryError {
        #expect(failure.outcome == .cancelled)
        #expect(failure.history.count == 1)
        let reported = try #require(reports.withLock { $0.last })
        #expect(failure.logicalID == reported.logicalID)
        #expect(failure.failure.identity == reported.history.first?.identity)
        #expect(failure.history.first?.identity == failure.failure.identity)
        #expect(failure.failure.progress == reported.progress)
        #expect(failure.failure.inspectEvidence().cause is CancellationError)
        #expect(failure.failure.inspectEvidence().body == Data(body.utf8))
        #expect(failure.failure.status == 200)
        let header = failure.failure.inspectEvidence().headers.first { $0.key.lowercased() == "x-request-id" }
        #expect(header?.value == "terminal-original")
    }
}
