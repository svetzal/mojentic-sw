import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension SenderRegistrationCancellationTests {
    /// A byte-acknowledged incomplete first line cannot produce a semantic sender.
    ///
    /// Expectations follow from the scripted LF boundary, not observed lifecycle events.
    func beforeFraming(
        _ boundary: StreamingBoundary,
        path: String,
        server: InProcessHTTPFixture,
        recorder: RecoveryRecorder,
        schedule: SenderRegistrationSchedule,
        report: RecoveryLocked<CompletionRecoveryReport?>,
        body: Data
    ) async throws {
        try await awaitFinished(schedule.producersCompleted, count: 1)
        let completed = schedule.completed.withLock { $0 }
        let identity = try #require(recorder.requests.withLock { $0.first?.0 })
        let cleaned = try #require(report.withLock { $0 })
        #expect(completed.count == 1)
        #expect(completed.first?.0 == identity)
        #expect(completed.first?.1 == body)
        #expect(server.closedClients.withLock { $0 } == 1)
        #expect(server.requests.withLock { $0 } == recorder.requests.withLock { $0.map(\.1) })
        #expect(recorder.requests.withLock { $0.count } == 1)
        #expect(cleaned.identity == identity)
        #expect(cleaned.logicalID == identity.logicalID)
        #expect(identity.wireNumber == 1)
        #expect(cleaned.history.count == 1)
        let failure = try #require(cleaned.history.first)
        #expect(failure.identity == identity)
        #expect(failure.category == .transport)
        #expect(failure.status == 200)
        #expect(failure.phase == .streaming)
        #expect(failure.eligible)
        #expect(failure.reason == "transientTransport")
        #expect(failure.inspectEvidence().body == body)
        #expect(
            failure.inspectEvidence().headers.contains {
                $0.key.lowercased() == "x-request-id" && $0.value == "original-header"
            })
        let cause = try #require(failure.inspectEvidence().cause as? URLError)
        // The in-process boundary injects the same typed connection-loss cause on every platform.
        #expect(cause.code == .networkConnectionLost)
        var progress = RecoveryProgress()
        progress.headersReceived = true
        progress.rawBytes = body.count
        #expect(cleaned.progress == progress)
        #expect(failure.progress == progress)
        let evidence = RecoveryLifecycleEvidence(boundary)
        let events =
            [evidence.event(.attemptStarted, identity: identity)]
            + [RecoveryTransition.attemptFailed, .exhausted].map {
                evidence.event(
                    $0,
                    identity: identity,
                    progress: progress,
                    category: .transport,
                    status: 200,
                    phase: .streaming,
                    eligible: true,
                    reason: "transientTransport")
            }
        #expect(recorder.events.withLock { $0 } == events)
        let observedBody = recorder.wires.withLock { wires in
            wires.reduce(into: Data()) { bytes, event in
                if case .body(let receivedIdentity, let data) = event {
                    #expect(receivedIdentity == identity)
                    bytes.append(data)
                }
            }
        }
        #expect(observedBody == body)
        if boundary.single, path == "broker" {
            try await waitForTerminalSender(schedule)
            #expect(schedule.heldRole.withLock { $0 } == "broker")
            #expect(schedule.entered.withLock { $0.count } == 1)
            #expect(schedule.entered.withLock { $0.allSatisfy { $0.contains("recoveryFailure") } })
        } else {
            #expect(schedule.heldRole.withLock { $0 } == nil)
            #expect(schedule.entered.withLock { $0.isEmpty })
        }
        server.trace.record(
            "framing.transport.before.semantic.registration", identity: identity, progress: progress)
    }

    func finishTransport(
        task: Task<Void, any Error>,
        schedule: SenderRegistrationSchedule,
        consumer: RecoveryConsumerPause,
        retained: RecoveryLocked<RetainedStream?>,
        server: InProcessHTTPFixture,
        path: String,
        boundary: StreamingBoundary,
    ) async throws {
        if boundary.single, path == "broker" {
            // This sender is a terminal error, not decoded content. Cancel
            // its rendezvous only after preserving the transport report.
            server.trace.record("caller.cancel.terminal")
            task.cancel()
            schedule.registration.resume()
        }
        let count = path == "gateway" ? 1 : path == "broker" ? 2 : 3
        try await awaitFinished(schedule.producersCompleted, count: count)
        #expect(schedule.producersCompleted.withLock { $0.count } == count)
        #expect(schedule.finished.withLock { $0.count } == count)
        try await consumeTransport(try #require(retained.withLock { $0 }), path: path)
        server.trace.record("consumer.resume")
        consumer.resume()
        try await task.value
    }

    private func waitForTerminalSender(_ schedule: SenderRegistrationSchedule) async throws {
        await schedule.heldRole.wait { $0 != nil }
    }

    func consumeTransport(_ stream: RetainedStream, path: String) async throws {
        switch stream {
        case .gateway(let stream):
            try await expectTransport {
                for try await _ in stream { Issue.record("Incomplete line delivered") }
            }
        case .relay(let stream):
            try await expectTransport {
                for try await _ in stream { Issue.record("Incomplete relay line delivered") }
            }
        case .completion(let stream):
            var terminals = 0
            for await event in stream {
                if case .recoveryFailure(let error) = event {
                    #expect(error.outcome == .exhausted)
                    #expect(error.history.count == 1)
                    #expect(error.history.first?.category == .transport)
                } else if case .error(.cancelled) = event, path == "broker" {
                    // The transport report precedes cancellation of this terminal rendezvous.
                } else {
                    Issue.record("Incomplete completion line delivered")
                }
                terminals += 1
            }
            #expect(terminals == 1)
        }
    }

    private func expectTransport(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            Issue.record("Expected transport terminal")
        } catch let error as RecoveryError {
            #expect(error.outcome == .exhausted)
            #expect(error.history.count == 1)
            #expect(error.history.first?.category == .transport)
            #expect(error.failure.inspectEvidence().cause is URLError)
        }
    }
}
