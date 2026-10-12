import Foundation
@testable import Mojentic
import Testing

extension RecoveryStatusBoundary {
    var recoveryProvider: RecoveryProvider {
        provider.anthropic ? .anthropic : provider.openAI ? .openAI : provider.omlx ? .omlx : .ollama
    }

    var recoveryOperation: RecoveryOperation {
        switch operation {
        case .ordinary: .ordinary
        case .structured, .json: .structured
        case .tools, .single: .streaming
        }
    }
}

func assertSelectionLifecycle(
    _ recorder: RecoveryRecorder,
    boundary: RecoveryStatusBoundary,
    replies: [RecoveryReply],
    identities: [RecoveryIdentity],
    selected: Bool,
    outcome: RecoveryTransition,
    delays: [TimeInterval],
) throws {
    var expected: [RecoveryEvent] = []
    for (index, identity) in identities.enumerated() {
        let reply = replies[index]
        let steps: [RecoveryTransition] =
            (index == 0 ? [.attemptStarted] : [.retryStarted, .attemptStarted])
            + [.attemptFailed]
            + (index == identities.count - 1
                ? [outcome] : [.admissionPending, .admissionAllowed, .delayScheduled])
        for step in steps {
            let starting = step == .attemptStarted || step == .retryStarted
            var progress = RecoveryProgress()
            if !starting {
                progress.headersReceived = true
                progress.rawBytes = reply.body.utf8.count
            }
            let category: RecoveryCategory = reply.status == 200 ? .transport : .http
            let reason =
                category == .transport
                ? (selected ? "transientTransport" : "nonTransientTransport")
                : selected
                    ? "selectedHTTPStatus"
                    : [400, 401, 403].contains(reply.status) ? "permanentHTTPStatus" : "unselectedHTTPStatus"
            let phase: RecoveryPhase =
                boundary.recoveryOperation == .streaming
                ? .streaming : reply.truncated ? .receiving : .decoding
            expected.append(
                RecoveryEvent(
                    logicalID: identity.logicalID,
                    transition: step,
                    identity: identity,
                    progress: progress,
                    category: starting ? nil : category,
                    status: starting ? nil : reply.status,
                    delay: step == .delayScheduled ? (delays.isEmpty ? 0 : delays[index]) : nil,
                    provider: boundary.recoveryProvider,
                    operation: boundary.recoveryOperation,
                    phase: starting ? nil : phase,
                    acceptance: .unknown,
                    eligible: starting ? nil : selected,
                    reason: starting ? nil : reason,
                ))
        }
    }
    #expect(recorder.events.withLock { $0 } == expected)
}
