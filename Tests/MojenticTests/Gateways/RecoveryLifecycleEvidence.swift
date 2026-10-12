import Foundation
@testable import Mojentic
import Testing

/// Expectations come from scripted replies and public wire capture, never lifecycle output.
struct RecoveryLifecycleEvidence {
    let provider: RecoveryProvider
    let operation: RecoveryOperation

    init(_ boundary: RecoveryBoundary) {
        provider =
            boundary.anthropic ? .anthropic : boundary.openAI ? .openAI : boundary.omlx ? .omlx : .ollama
        operation = boundary.structured ? .structured : .ordinary
    }

    init(_ boundary: StreamingBoundary) {
        provider =
            boundary.anthropic ? .anthropic : boundary.openAI ? .openAI : boundary.omlx ? .omlx : .ollama
        operation = .streaming
    }

    func event(
        _ transition: RecoveryTransition,
        identity: RecoveryIdentity,
        progress: RecoveryProgress = RecoveryProgress(),
        category: RecoveryCategory? = nil,
        status: Int? = nil,
        phase: RecoveryPhase? = nil,
        eligible: Bool? = nil,
        reason: String? = nil,
        delay: TimeInterval? = nil,
    ) -> RecoveryEvent {
        RecoveryEvent(
            logicalID: identity.logicalID,
            transition: transition,
            identity: identity,
            progress: progress,
            category: category,
            status: status,
            delay: delay,
            provider: provider,
            operation: operation,
            phase: phase,
            acceptance: .unknown,
            eligible: eligible,
            reason: reason,
        )
    }

    func interruption(identity: RecoveryIdentity, progress: RecoveryProgress) -> [RecoveryEvent] {
        [RecoveryTransition.attemptStarted, .attemptFailed, .interrupted].map { transition in
            let starting = transition == .attemptStarted
            return event(
                transition,
                identity: identity,
                progress: starting ? RecoveryProgress() : progress,
                category: starting ? nil : .transport,
                status: starting ? nil : 200,
                phase: starting ? nil : .streaming,
                eligible: starting ? nil : false,
                reason: starting ? nil : "observedSemanticOutput",
            )
        }
    }
}

extension RecoveryLifecycleEvidence {
    init(_ boundary: TypedRecoveryBoundary) {
        provider = RecoveryLifecycleEvidence(boundary.provider).provider
        operation =
            boundary.path.streaming
            ? .streaming
            : [.structured, .json, .brokerJSON].contains(boundary.path) ? .structured : .ordinary
    }

    func terminal(
        identity: RecoveryIdentity,
        progress: RecoveryProgress,
        category: RecoveryCategory,
        outcome: RecoveryTransition,
        reason: String,
        phase: RecoveryPhase,
    ) -> [RecoveryEvent] {
        [event(.attemptStarted, identity: identity)]
            + [.attemptFailed, outcome].map {
                event(
                    $0,
                    identity: identity,
                    progress: progress,
                    category: category,
                    status: 200,
                    phase: phase,
                    eligible: false,
                    reason: reason,
                )
            }
    }

    func undispatched(
        logicalID: UUID,
        outcome: RecoveryTransition,
        category: RecoveryCategory,
        reason: String
    ) -> [RecoveryEvent] {
        [
            RecoveryEvent(
                logicalID: logicalID,
                transition: outcome,
                identity: nil,
                progress: RecoveryProgress(),
                category: category,
                status: nil,
                delay: nil,
                provider: provider,
                operation: operation,
                phase: nil,
                acceptance: .no,
                eligible: false,
                reason: reason,
            )
        ]
    }

    func http(
        _ steps: [RecoveryTransition],
        identity: RecoveryIdentity,
        reply: RecoveryReply,
        delay: TimeInterval = 0,
    ) -> [RecoveryEvent] {
        var progress = RecoveryProgress()
        progress.headersReceived = true
        progress.rawBytes = reply.body.utf8.count
        return steps.map {
            let starting = $0 == .attemptStarted || $0 == .retryStarted
            return event(
                $0,
                identity: identity,
                progress: starting ? RecoveryProgress() : progress,
                category: starting ? nil : .http,
                status: starting ? nil : reply.status,
                phase: starting ? nil : operation == .streaming ? .streaming : .decoding,
                eligible: starting ? nil : true,
                reason: starting ? nil : "selectedHTTPStatus",
                delay: $0 == .delayScheduled ? delay : nil,
            )
        }
    }

    func success(
        identities: [RecoveryIdentity],
        reply: RecoveryReply,
        progress: RecoveryProgress,
        rejected: RecoveryReply? = nil,
    ) -> [RecoveryEvent] {
        var expected: [RecoveryEvent] = []
        if let rejected {
            expected += http(
                [.attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled],
                identity: identities[0],
                reply: rejected,
            )
            expected.append(event(.retryStarted, identity: identities[1]))
        }
        let identity = identities[rejected == nil ? 0 : 1]
        expected.append(event(.attemptStarted, identity: identity))
        expected.append(
            event(
                .attemptSucceeded,
                identity: identity,
                progress: progress,
                status: reply.status,
                phase: operation == .streaming ? .streaming : .decoding,
            )
        )
        return expected
    }
}

func lifecycleProgress(
    _ reply: RecoveryReply,
    observed: RecoverySemanticProgress = RecoverySemanticProgress(),
    delivered: RecoverySemanticProgress = RecoverySemanticProgress(),
) -> RecoveryProgress {
    var progress = RecoveryProgress()
    progress.headersReceived = true
    progress.rawBytes = reply.body.utf8.count
    progress.observed = observed
    progress.delivered = delivered
    return progress
}

func assertCancellationLifecycle(
    _ recorder: RecoveryRecorder,
    lifecycle: RecoveryLifecycleEvidence,
    reply: RecoveryReply,
    phase: String
) throws {
    let identity = try #require(recorder.requests.withLock { $0.first?.0 })
    var expected: [RecoveryEvent]
    if phase == "active" {
        expected = lifecycle.terminal(
            identity: identity,
            progress: lifecycleProgress(reply),
            category: .cancellation,
            outcome: .cancelled,
            reason: "callerCancelled",
            phase: lifecycle.operation == .streaming ? .streaming : .receiving
        )
    } else {
        let steps: [RecoveryTransition] =
            phase == "admission"
            ? [.attemptStarted, .attemptFailed, .admissionPending]
            : [.attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled]
        expected = lifecycle.http(steps, identity: identity, reply: reply)
        expected.append(
            lifecycle.event(
                .cancelled,
                identity: identity,
                progress: lifecycleProgress(reply),
                category: .cancellation,
                status: 503,
                phase: lifecycle.operation == .streaming ? .streaming : .decoding,
                eligible: false,
                reason: "callerCancelled"
            )
        )
    }
    #expect(recorder.events.withLock { $0 } == expected)
}
