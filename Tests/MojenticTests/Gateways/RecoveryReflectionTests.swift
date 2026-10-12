import Foundation
@testable import Mojentic
import Testing

struct RecoveryReflectionTests {
    @Test
    func publicBoundaryProof() async throws {
        try await checkBoundary(
            RecoveryStatusBoundary(provider: .init(omlx: false, structured: false), operation: .single))
    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func allPublicBoundaries(_ boundary: RecoveryStatusBoundary) async throws {
        try await checkBoundary(boundary)
    }

    @Test
    func syntheticEvidenceAndEveryWireCase() throws {
        let identity = RecoveryIdentity(logicalID: UUID(), attemptID: UUID(), wireNumber: 7)
        let cause = NSError(
            domain: "cause-sentinel", code: 42, userInfo: [NSLocalizedDescriptionKey: "private-sentinel"])
        let bytes = Data("payload-sentinel é猫".utf8)
        let headers = ["Authorization": "credential-sentinel"]
        let evidence = RecoveryEvidence(
            headers: headers,
            body: bytes,
            cause: cause,
            providerCode: "overloaded_error",
            providerRequestID: "safe-request-42",
        )
        assertEvidenceMirror(evidence)
        assertPrivateReflection(evidence)
        #expect(evidence.headers == headers)
        #expect(evidence.body == bytes)
        #expect((evidence.cause as? NSError) === cause)
        let failure = RecoveryFailure(
            logicalID: identity.logicalID,
            identity: identity,
            provider: .anthropic,
            operation: .streaming,
            category: .capture,
            status: 503,
            retryAfter: .seconds(2),
            progress: .init(identity: identity),
            phase: .decoding,
            eligible: false,
            reason: "captureFailed",
            evidence: evidence,
        )
        assertFailureMirror(failure)
        #expect((failure.inspectEvidence().cause as? NSError) === cause)
        #expect(failure.inspectEvidence().headers == headers)
        #expect(failure.inspectEvidence().body == bytes)
        let error = RecoveryError(
            logicalID: identity.logicalID, outcome: .captureFailed, failure: failure, history: [failure])
        let report = CompletionRecoveryReport(
            logicalID: identity.logicalID, identity: identity, progress: failure.progress, history: [failure],
        )
        let sensitive: [Any] = [failure, error, report, RecoveryCompletionStreamEvent.recoveryFailure(error)]
        for value in sensitive {
            assertPrivateReflection(value)
        }
        let url = try #require(URL(string: "https://example.test/private-sentinel?token=credential-sentinel"))
        let wires: [RecoveryWireEvent] = [
            .request(identity, url, headers, bytes), .headers(identity, 503, headers), .body(identity, bytes),
        ]
        for wire in wires {
            assertWireMirror(wire)
            assertPrivateReflection(wire)
            switch wire {
            case .request(let actual, let capturedURL, let capturedHeaders, let capturedBytes):
                #expect(actual == identity)
                #expect(capturedURL == url)
                #expect(capturedHeaders == headers)
                #expect(capturedBytes == bytes)
            case .headers(let actual, let status, let capturedHeaders):
                #expect(actual == identity)
                #expect(status == 503)
                #expect(capturedHeaders == headers)
            case .body(let actual, let capturedBytes):
                #expect(actual == identity)
                #expect(capturedBytes == bytes)
            }
        }
    }

    private func checkBoundary(_ boundary: RecoveryStatusBoundary) async throws {
        let replies = (1...2).map { attempt in
            RecoveryReply(
                status: 503,
                headers: [
                    "X-Request-ID": "safe-request-\(attempt)", "X-Private": "credential-sentinel-\(attempt)",
                ],
                body: "payload-sentinel é猫 attempt-\(attempt)",
            )
        }
        let server = try RecoveryLoopback(replies: replies)
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder, attempts: 2)
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        let delivered = RecoveryLocked<[String]>([])
        let gateway = boundary.provider.gateway(server, policy: policy)
        let observed = RecoveryLocked<[RecoveryCompletionStreamEvent]>([])
        let error = try await recoveryFailure {
            try await invokeReflectionBoundary(
                boundary, gateway: gateway, delivered: delivered, observed: observed)
        }
        #expect(delivered.withLock { $0 }.isEmpty)
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        let expected = reflectionExpectedFailures(boundary, identities: identities, replies: replies)
        let terminalFailure = try #require(expected.last)
        #expect(error.logicalID == identities[0].logicalID)
        #expect(error.outcome == .exhausted)
        #expect(error.history.count == expected.count)
        #expect(error.history.map(\.identity) == identities.map(Optional.some))
        for (index, pair) in zip(error.history, expected).enumerated() {
            let (failure, expectedFailure) = pair
            try assertStatusFailure(
                failure, identity: identities[index], reply: replies[index])
            assertFailureMirror(failure, expected: expectedFailure)
            assertEvidenceMirror(failure.inspectEvidence())
            assertPrivateReflection(failure)
            assertPrivateReflection(failure.inspectEvidence())
        }
        assertExactMirror(
            error,
            [
                ("logicalID", identities[0].logicalID), ("outcome", RecoveryTransition.exhausted),
                ("failure", terminalFailure), ("history", expected),
            ])
        assertFailureMirror(error.failure, expected: terminalFailure)
        assertPrivateReflection(error)
        #expect(observed.withLock { $0.count } == (boundary.operation == .single ? 1 : 0))
        for event in observed.withLock({ $0 }) {
            let children = Array(Mirror(reflecting: event).children)
            #expect(children.map(\.label) == ["recoveryFailure"])
            let mirroredError = try #require(children.first?.value as? RecoveryError)
            assertExactMirror(
                mirroredError,
                [
                    ("logicalID", identities[0].logicalID), ("outcome", RecoveryTransition.exhausted),
                    ("failure", terminalFailure), ("history", expected),
                ])
            assertPrivateReflection(event)
        }
        let published = reports.withLock { $0 }
        #expect(published.count == 1)
        for report in published {
            #expect(report.logicalID == error.logicalID)
            #expect(report.identity == identities.last)
            #expect(report.history.map(\.identity) == error.history.map(\.identity))
            #expect(report.progress == error.failure.progress)
            assertExactMirror(
                report,
                [
                    ("logicalID", identities[0].logicalID), ("identity", identities.last as Any),
                    ("progress", terminalFailure.progress), ("history", expected),
                ])
            #expect(report.history.count == expected.count)
            for (index, pair) in zip(report.history, expected).enumerated() {
                let (failure, expectedFailure) = pair
                try assertStatusFailure(failure, identity: identities[index], reply: replies[index])
                assertFailureMirror(failure, expected: expectedFailure)
            }
            assertPrivateReflection(report)
        }
        for wire in recorder.wires.withLock({ $0 }) {
            assertWireMirror(wire)
            assertPrivateReflection(wire)
        }
        assertPrivateReflection([error])
        assertPrivateReflection(error.history)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled,
                .retryStarted, .attemptStarted, .attemptFailed, .exhausted,
            ])
    }
}
