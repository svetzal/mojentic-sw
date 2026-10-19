import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryVocabularyTests {
    @Test(arguments: RecoveryStatusBoundary.all.filter { $0.operation != .json })
    func publicVocabulary(_ boundary: RecoveryStatusBoundary) async throws {
        let replies = [
            statusReply(503, attempt: 1, truncated: false), statusReply(504, attempt: 2, truncated: false),
        ]
        let server = try InProcessHTTPFixture(replies: replies)
        let recorder = RecoveryRecorder()
        let admissions = RecoveryLocked<[RecoveryFailure]>([])
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, next in
            #expect(next == 2)
            admissions.withLock { $0.append(failure) }
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        let error = try await recoveryFailure {
            try await invokeMetadataBoundary(
                boundary, gateway: boundary.provider.gateway(server, policy: policy))
        }
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        #expect(error.outcome == .exhausted)
        #expect(error.history.count == 2)
        #expect(error.failure.identity == identities[1])
        #expect(admissions.withLock { $0.count } == 1)
        let report = try #require(reports.withLock { $0.last })
        #expect(report.history.map(\.identity) == identities.map(Optional.some))
        let provider =
            boundary.provider.anthropic
            ? "anthropic" : boundary.provider.openAI ? "openai" : boundary.provider.omlx ? "omlx" : "ollama"
        let streaming = [.tools, .single].contains(boundary.operation)
        let operation =
            streaming ? "streaming" : (boundary.operation == .ordinary ? "ordinary" : "structured")
        for failure in error.history + [error.failure] + report.history + admissions.withLock({ $0 }) {
            #expect(failure.provider.rawValue == provider)
            #expect(failure.operation.rawValue == operation)
            let typedProvider: RecoveryProvider = failure.provider
            let typedOperation: RecoveryOperation = failure.operation
            #expect(typedProvider == RecoveryProvider(rawValue: provider))
            #expect(typedOperation == RecoveryOperation(rawValue: operation))
            #expect(failure.phase == (streaming ? .streaming : .decoding))
        }
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition) == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled,
                .retryStarted, .attemptStarted, .attemptFailed, .exhausted,
            ])
        for event in events {
            #expect(event.provider.rawValue == provider)
            #expect(event.operation.rawValue == operation)
            #expect(event.logicalID == identities[0].logicalID)
            #expect(
                event.identity
                    == identities[event.transition == .exhausted || event.identity?.wireNumber == 2 ? 1 : 0])
            let encoded = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(RecoveryEvent.self, from: encoded) == event)
            let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
            #expect(json.objectValue?["provider"] == .string(provider))
            #expect(json.objectValue?["operation"] == .string(operation))
            var invalid = try #require(json.objectValue)
            invalid["provider"] = "unknown-provider"
            let invalidProvider = try JSONEncoder().encode(JSONValue.object(invalid))
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(RecoveryEvent.self, from: invalidProvider)
            }
            invalid = try #require(json.objectValue)
            invalid["operation"] = "unknown-operation"
            let invalidOperation = try JSONEncoder().encode(JSONValue.object(invalid))
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(RecoveryEvent.self, from: invalidOperation)
            }
        }
        for request in recorder.requests.withLock({ $0 }) {
            try assertMetadataPayload(request.1, boundary: boundary)
        }
    }
}
