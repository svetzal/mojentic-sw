import Foundation
@testable import Mojentic
import Testing

@Suite("Recovery admission contract")
struct RecoveryAdmissionContractTests {
    @Test(arguments: RecoveryStatusBoundary.all)
    func emptyAdmissionDoesNotReject(_ boundary: RecoveryStatusBoundary) async throws {
        let reply = RecoveryReply(status: 503, body: "busy")
        let server = try RecoveryLoopback(replies: [reply])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.admission = { _, _ in AsyncStream { $0.finish() } }
        let gateway = boundary.buffered.gateway(server, policy: policy)
        let error = try await recoveryFailure {
            try await boundary.invoke(gateway, delivered: RecoveryLocked([]))
        }
        #expect(error.outcome == .admissionUndecided)
        #expect(error.history.count == 1)
        #expect(error.failure.eligible && error.failure.acceptance == .unknown)
        #expect((error.failure.inspectEvidence().cause as? RecoveryHTTPStatusFailure)?.status == 503)
        let identities = try assertStatusWires(recorder, server: server, replies: [reply])
        #expect(error.history.map(\.identity) == identities.map(Optional.some))
        #expect(
            recorder.events.withLock { $0.map(\.transition.rawValue) } == [
                "attemptStarted", "attemptFailed", "admissionPending", "admissionUndecided",
            ])
        assertAdmissionFields(recorder, boundary: boundary)
    }
}

extension RecoveryAdmissionContractTests {
    @Test(arguments: RecoveryStatusBoundary.all, ["none", "allow", "reject"])
    func providerAdmissionRules(_ boundary: RecoveryStatusBoundary, _ decision: String) async throws {
        let rejected = RecoveryReply(status: 503, body: "busy")
        let success = try admissionSuccess(boundary)
        let server = try RecoveryLoopback(replies: [rejected, success])
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        let admissions = RecoveryLocked<[RecoveryFailure]>([])
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        policy.admission = nil
        if decision != "none" {
            policy.admission = { failure, next in
                admissions.withLock { $0.append(failure) }
                #expect(next == 2)
                return AsyncStream {
                    $0.yield(decision == "allow" ? .allow : .reject)
                    $0.finish()
                }
            }
        }
        let remote = boundary.provider.openAI || boundary.provider.anthropic
        let retry = decision == "allow" || (decision == "none" && remote)
        let delivered = RecoveryLocked<[String]>([])
        let gateway = boundary.buffered.gateway(server, policy: policy)
        if retry {
            try await boundary.invoke(gateway, delivered: delivered)
            #expect(!delivered.withLock { $0 }.isEmpty)
        } else {
            let error = try await recoveryFailure { try await boundary.invoke(gateway, delivered: delivered) }
            #expect(error.outcome == (decision == "reject" ? .admissionRejected : .admissionRequired))
            #expect(error.history.count == 1)
            #expect(delivered.withLock { $0 }.isEmpty)
            #expect((error.failure.inspectEvidence().cause as? RecoveryHTTPStatusFailure)?.status == 503)
        }
        let identities = try assertStatusWires(
            recorder, server: server, replies: retry ? [rejected, success] : [rejected],
        )
        let report = try #require(reports.withLock { $0.first })
        #expect(report.history.count == 1)
        let failure = try #require(report.history.first)
        #expect(failure.identity == identities.first)
        #expect(failure.eligible && failure.acceptance == .unknown)
        #expect(failure.category == .http && failure.reason == "selectedHTTPStatus")
        #expect((failure.inspectEvidence().cause as? RecoveryHTTPStatusFailure)?.status == 503)
        #expect(admissions.withLock { $0.map(\.identity) } == (decision == "none" ? [] : [identities.first]))
        var expected: [RecoveryTransition] = [.attemptStarted, .attemptFailed]
        if decision != "none" {
            expected += [.admissionPending, decision == "allow" ? .admissionAllowed : .admissionRejected]
        }
        if retry {
            expected += [.delayScheduled, .retryStarted, .attemptStarted, .attemptSucceeded]
        } else if decision == "none" {
            expected += [.admissionRequired]
        }
        #expect(recorder.events.withLock { $0.map(\.transition) } == expected)
        assertAdmissionFields(recorder, boundary: boundary)
    }

    @Test(arguments: RecoveryStatusBoundary.all, [false, true])
    func pendingAdmissionTerminates(_ boundary: RecoveryStatusBoundary, _ cancel: Bool) async throws {
        let rejected = RecoveryReply(status: 503, body: "busy")
        let server = try RecoveryLoopback(replies: [rejected, admissionSuccess(boundary)])
        let recorder = RecoveryRecorder()
        let pending = AsyncStream<Void>.makeStream()
        let sleeping = AsyncStream<Void>.makeStream()
        let elapsed = AsyncStream<Void>.makeStream()
        let terminated = AsyncStream<Bool>.makeStream()
        let now = RecoveryLocked<TimeInterval>(0)
        var policy = recoveryPolicy(recorder)
        policy.timing.monotonic = { now.withLock { $0 } }
        if !cancel { policy.budget = 5 }
        policy.admission = { _, _ in
            let stream = AsyncStream<RecoveryAdmission>.makeStream()
            stream.continuation.onTermination = { reason in
                switch reason {
                case .cancelled: terminated.continuation.yield(true)
                case .finished: terminated.continuation.yield(false)
                @unknown default: terminated.continuation.yield(false)
                }
                terminated.continuation.finish()
            }
            pending.continuation.yield(())
            return stream.stream
        }
        policy.timing.sleep = { delay in
            #expect(delay == 5)
            sleeping.continuation.yield(())
            var iterator = elapsed.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let gateway = boundary.buffered.gateway(server, policy: policy)
        let task = Task { try await boundary.invoke(gateway, delivered: RecoveryLocked([])) }
        var pendingIterator = pending.stream.makeAsyncIterator()
        _ = await pendingIterator.next()
        if cancel {
            task.cancel()
        } else {
            var sleepIterator = sleeping.stream.makeAsyncIterator()
            _ = await sleepIterator.next()
            now.withLock { $0 = 5 }
            elapsed.continuation.yield(())
            elapsed.continuation.finish()
        }
        var terminationIterator = terminated.stream.makeAsyncIterator()
        #expect(await terminationIterator.next() == true)
        let error = try await recoveryFailure { try await task.value }
        #expect(error.outcome == (cancel ? .cancelled : .limitRefused))
        #expect(error.history.count == 1)
        let original = try #require(error.history.first)
        #expect(original.eligible && original.acceptance == .unknown)
        #expect(original.identity == recorder.requests.withLock { $0.first?.0 })
        #expect((original.inspectEvidence().cause as? RecoveryHTTPStatusFailure)?.status == 503)
        if cancel {
            #expect(error.failure.inspectEvidence().cause is CancellationError)
        } else {
            #expect((error.failure.inspectEvidence().cause as? RecoveryHTTPStatusFailure)?.status == 503)
        }
        _ = try assertStatusWires(recorder, server: server, replies: [rejected])
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .admissionPending, cancel ? .cancelled : .limitRefused,
            ])
        assertAdmissionFields(recorder, boundary: boundary)
    }
}

private func admissionSuccess(_ boundary: RecoveryStatusBoundary) throws -> RecoveryReply {
    if boundary.operation == .tools || boundary.operation == .single {
        return try RecoveryReply(
            body: StreamingBoundary(
                omlx: boundary.provider.omlx,
                single: boundary.operation == .single,
                openAI: boundary.provider.openAI,
                anthropic: boundary.provider.anthropic,
            ).frame(content: "recovered", done: true))
    }
    return try boundary.buffered.success()
}

private func assertAdmissionFields(_ recorder: RecoveryRecorder, boundary: RecoveryStatusBoundary) {
    let streaming = boundary.operation == .tools || boundary.operation == .single
    let remote = boundary.provider.openAI || boundary.provider.anthropic
    let operation =
        streaming
        ? "streaming"
        : remote
            ? (boundary.operation == .ordinary ? "complete" : "completeStructured")
            : (boundary.operation == .ordinary ? "ordinary" : "structured")
    for event in recorder.events.withLock({ $0 }) {
        #expect(event.operation == operation)
        #expect(event.logicalID == recorder.requests.withLock { $0.first?.0.logicalID })
        #expect(event.acceptance == .unknown)
        if event.transition == .cancelled {
            #expect(event.category == .cancellation && event.reason == "callerCancelled")
            #expect(event.eligible == false)
            #expect(event.phase == (streaming ? .streaming : .decoding))
        }
        if [
            .attemptFailed, .admissionPending, .admissionAllowed, .admissionRejected,
            .admissionRequired, .admissionUndecided, .delayScheduled, .limitRefused,
        ].contains(event.transition) {
            #expect(event.eligible == true && event.acceptance == .unknown)
            #expect(event.phase == (streaming ? .streaming : .decoding))
            #expect(event.category == .http && event.reason == "selectedHTTPStatus")
        }
        if event.transition == .delayScheduled {
            #expect(event.delay == 0)
        } else {
            #expect(event.delay == nil)
        }
    }
}

extension RecoveryAdmissionContractTests {
    @Test(arguments: ["ollama", "omlx"], [false, true])
    func syntheticUnacceptedLocalFailure(_ provider: String, _ reject: Bool) async throws {
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.admission = nil
        if reject {
            policy.admission = { _, _ in
                AsyncStream {
                    $0.yield(.reject)
                    $0.finish()
                }
            }
        }
        // Public transports cannot prove nonacceptance after dispatch. Model only a failure
        // before dispatch: no actual attempt identity and no assertion about remote execution.
        var engine = BufferedRecovery(policy: policy, provider: provider, operation: "ordinary")
        let failure = engine.makeFailure(
            category: .transport, cause: URLError(.cannotConnectToHost), reason: "requestFailed",
        )
        #expect(failure.acceptance == .no && failure.eligible && failure.identity == nil)
        if reject {
            let error = try await recoveryFailure { try await engine.admit(failure, next: 2) }
            #expect(error.outcome == .admissionRejected)
            #expect((error.failure.inspectEvidence().cause as? URLError)?.code == .cannotConnectToHost)
            #expect(error.history.isEmpty)
        } else {
            try await engine.admit(failure, next: 2)
        }
        #expect(
            recorder.events.withLock { $0.map(\.transition) }
                == (reject
                    ? [.admissionPending, .admissionRejected] : [.delayScheduled]))
        #expect(recorder.requests.withLock { $0 }.isEmpty)
    }
}
