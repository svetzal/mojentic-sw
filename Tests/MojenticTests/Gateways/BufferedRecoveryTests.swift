import Foundation
import Testing

@testable import Mojentic

final class RecoveryRecorder: Sendable {
    let requests = RecoveryLocked<[(RecoveryIdentity, Data)]>([])
    let events = RecoveryLocked<[RecoveryEvent]>([])
    let wires = RecoveryLocked<[RecoveryWireEvent]>([])
}

@Suite("Buffered recovery public boundary")
struct BufferedRecoveryTests {
    @Test func admitted503PreservesBytesAndIdentity() async throws {
        let server = try RecoveryLoopback()
        var policy = CompletionRecoveryPolicy()
        policy.maximumAttempts = 2
        policy.baseDelay = 0
        policy.admission = { _, _ in
            AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        let recorder = RecoveryRecorder()
        policy.wireObserver = { event in
            if case .request(let identity, _, _, let bytes) = event {
                recorder.requests.withLock { $0.append((identity, bytes)) }
            }
        }
        policy.observer = { event in recorder.events.withLock { $0.append(event) } }
        let gateway = OllamaGateway(baseURL: server.url, recovery: policy)
        let result = try await gateway.complete(
            model: "fixture",
            messages: [.user("original")],
            tools: nil,
            config: CompletionConfig()
        )
        #expect(result.content == "recovered")
        #expect(result.thinking == "reasoning")
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let last = try #require(requests.last)
        #expect(first.1 == last.1)
        #expect(first.0.logicalID == last.0.logicalID)
        #expect(first.0.attemptID != last.0.attemptID)
        #expect(first.0.wireNumber == 1)
        #expect(last.0.wireNumber == 2)
        let fields = try JSONDecoder().decode(JSONValue.self, from: first.1)
        #expect(fields.objectValue?["model"] == "fixture")
        #expect(fields.objectValue?["stream"] == false)
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition.rawValue) == [
                "attemptStarted", "attemptFailed", "admissionPending", "admissionAllowed",
                "delayScheduled", "retryStarted", "attemptStarted", "attemptSucceeded",
            ]
        )
        #expect(events.last?.progress.observed.contentBytes == 9)
        #expect(events.last?.progress.delivered.reasoningBytes == 9)
    }
}
