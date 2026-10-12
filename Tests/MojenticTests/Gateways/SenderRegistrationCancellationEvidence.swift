import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension SenderRegistrationCancellationTests {
    func assertAttempt(
        recorder: RecoveryRecorder,
        server: RecoveryLoopback,
        cleaned: CompletionRecoveryReport?,
        body: String,
        boundary: StreamingBoundary,
        path: String,
    ) {
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        let fields = requests.first.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.1) }
        #expect(fields?.objectValue?["model"] == "fixture")
        #expect(fields?.objectValue?["stream"] == true)
        let bodies = recorder.wires.withLock { wires in
            wires.compactMap { event -> Data? in
                if case .body(let identity, let bytes) = event {
                    #expect(identity == requests.first?.0)
                    return bytes
                }
                return nil
            }
        }
        #expect(bodies.reduce(into: Data()) { $0.append($1) } == Data(body.utf8))
        #expect(cleaned?.identity == requests.first?.0)
        #expect(cleaned?.logicalID == requests.first?.0.logicalID)
        #expect(cleaned?.identity?.wireNumber == 1)
        #expect(cleaned?.history.count == 1)
        #expect(cleaned?.history.first?.identity == requests.first?.0)
        #expect(cleaned?.history.first?.status == 200)
        #expect(cleaned?.history.first?.category == .cancellation)
        let cause = cleaned?.history.first?.inspectEvidence().cause as? URLError
        #expect(cause?.code == .cancelled)
        #expect(cleaned?.history.first?.inspectEvidence().body == Data(body.utf8))
        #expect(
            cleaned?.history.first?.inspectEvidence().headers.contains {
                $0.key.lowercased() == "x-request-id" && $0.value == "original-header"
            } == true
        )
        #expect(cleaned?.progress.headersReceived == true)
        #expect(cleaned?.progress.rawBytes == body.utf8.count)
        #expect(cleaned?.progress.observed.contentBytes == 2)
        #expect(cleaned?.progress.observed.reasoningBytes == (boundary.single ? 0 : 3))
        #expect(cleaned?.progress.observed.toolFragments == (boundary.single ? 0 : 1))
        #expect(cleaned?.progress.observed.completedToolCalls == (boundary.single || boundary.omlx ? 0 : 1))
        #expect(cleaned?.progress.delivered.completedToolCalls == 0)
        var delivered = RecoverySemanticProgress()
        if path != "gateway", !(boundary.anthropic && boundary.single) {
            if path == "session" {
                delivered.reasoningBytes = boundary.openAI ? 0 : 3
                delivered.contentBytes = 2
            } else if boundary.omlx, !boundary.single, !boundary.openAI {
                delivered.reasoningBytes = boundary.openAI ? 0 : 3
            } else {
                delivered.contentBytes = 2
            }
        }
        #expect(cleaned?.progress.delivered == delivered)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .cancelled,
            ]
        )
        #expect(recorder.events.withLock { $0.allSatisfy { $0.identity == requests.first?.0 } })
        if let identity = requests.first?.0 {
            var progress = RecoveryProgress()
            progress.headersReceived = true
            progress.rawBytes = body.utf8.count
            progress.observed.contentBytes = 2
            progress.observed.reasoningBytes = boundary.single ? 0 : 3
            progress.observed.toolFragments = boundary.single ? 0 : 1
            progress.observed.completedToolCalls = boundary.single || boundary.omlx ? 0 : 1
            progress.delivered = delivered
            #expect(cleaned?.progress == progress)
            #expect(cleaned?.history.first?.progress == progress)
            let evidence = RecoveryLifecycleEvidence(boundary)
            #expect(
                recorder.events.withLock { $0 }
                    == evidence.terminal(
                        identity: identity,
                        progress: progress,
                        category: .cancellation,
                        outcome: .cancelled,
                        reason: "observedSemanticOutput",
                        phase: .streaming,
                    ))
        }
    }

}
