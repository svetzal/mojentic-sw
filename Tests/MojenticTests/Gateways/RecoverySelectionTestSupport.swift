import Foundation
@testable import Mojentic
import Testing

struct RecoverySelection: Sendable {
    var statuses: Set<Int> = [400, 401, 403, 504]
    var categories: Set<RecoveryCategory> = [.http, .transport, .clientTimeout]
    var eligible: Bool?
    var delays: [TimeInterval] = []
    var configure: @Sendable (inout CompletionRecoveryPolicy) -> Void = { _ in }
}

func assertTerminalStatus(
    _ boundary: RecoveryStatusBoundary,
    status: Int,
    attempts: Int,
    truncated: Bool,
    selection: RecoverySelection = .init(),
) async throws {
    let selected = selection.eligible ?? (status == 504)
    let count = selected ? attempts : 1
    let replies = (1...count).map { number in
        var reply = statusReply(status, attempt: number, truncated: truncated)
        if status == 200 { reply.body = "" }
        return reply
    }
    let server = try RecoveryLoopback(replies: replies)
    let recorder = RecoveryRecorder()
    let admissions = RecoveryLocked<[(RecoveryFailure, Int)]>([])
    let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
    let delivered = RecoveryLocked<[String]>([])
    var policy = recoveryPolicy(recorder, attempts: attempts)
    policy.retryableStatuses = selection.statuses
    policy.retryableCategories = selection.categories
    policy.admission = { failure, next in
        admissions.withLock { $0.append((failure, next)) }
        return AsyncStream {
            $0.yield(.allow)
            $0.finish()
        }
    }
    selection.configure(&policy)
    policy.reportObserver = { report in
        reports.withLock { $0.append(report) }
    }
    let gateway = boundary.provider.gateway(server, policy: policy)
    let error = try await recoveryFailure { try await boundary.invoke(gateway, delivered: delivered) }
    #expect(error.failure.eligible == selected)
    #expect(
        error.failure.reason
            == (selected
                ? status == 200 ? "transientTransport" : "selectedHTTPStatus"
                : status == 200
                    ? "nonTransientTransport"
                    : [400, 401, 403].contains(status) ? "permanentHTTPStatus" : "unselectedHTTPStatus"))
    #expect(delivered.withLock { $0 } == [])
    let outcome: RecoveryTransition = selected ? .exhausted : .ineligible
    #expect(error.outcome == outcome)
    let identities = try assertStatusWires(recorder, server: server, replies: replies)
    let last = try #require(identities.last)
    #expect(error.logicalID == last.logicalID)
    #expect(error.history.map(\.identity) == identities.map(Optional.some))
    try assertSelectionFailure(
        error.failure,
        identity: last,
        reply: #require(replies.last),
        eligible: selected,
        boundary: boundary,
    )
    for (index, failure) in error.history.enumerated() {
        try assertSelectionFailure(
            failure,
            identity: identities[index],
            reply: replies[index],
            eligible: selected,
            boundary: boundary,
        )
    }
    let admitted = admissions.withLock { $0 }
    #expect(admitted.map(\.0.identity) == identities.dropLast().map(Optional.some))
    #expect(admitted.map(\.1) == Array(2..<(count + 1)))
    for (index, admission) in admitted.enumerated() {
        try assertSelectionFailure(
            admission.0,
            identity: identities[index],
            reply: replies[index],
            eligible: selected,
            boundary: boundary,
        )
    }
    try assertSelectionLifecycle(
        recorder,
        boundary: boundary,
        replies: replies,
        identities: identities,
        selected: selected,
        outcome: outcome,
        delays: selection.delays,
    )
    let published = reports.withLock { $0 }
    #expect(published.count == 1)
    let report = try #require(published.first)
    #expect(report.identity == last)
    #expect(report.logicalID == last.logicalID)
    #expect(report.progress == error.failure.progress)
    #expect(report.history.map(\.identity) == identities.map(Optional.some))
    for (index, failure) in report.history.enumerated() {
        try assertSelectionFailure(
            failure,
            identity: identities[index],
            reply: replies[index],
            eligible: selected,
            boundary: boundary,
        )
    }
    let safe = try JSONEncoder().encode(recorder.events.withLock { $0 })
    #expect(try !#require(String(bytes: safe, encoding: .utf8)).contains("sentinel"))
    #expect(!String(reflecting: error).contains("sentinel"))
}

func assertSelectionFailure(
    _ failure: RecoveryFailure,
    identity: RecoveryIdentity,
    reply: RecoveryReply,
    eligible: Bool,
    boundary: RecoveryStatusBoundary,
) throws {
    try assertStatusFailure(failure, identity: identity, reply: reply, eligible: eligible)
    #expect(failure.provider == boundary.recoveryProvider)
    #expect(failure.operation == boundary.recoveryOperation)
    #expect(
        failure.phase
            == (boundary.recoveryOperation == .streaming
                ? .streaming : reply.truncated ? .receiving : .decoding))
    #expect(failure.retryAfter == .absent)
    #expect(failure.providerCode == nil)
    let requestID =
        [RecoveryProvider.omlx, .openAI].contains(boundary.recoveryProvider)
        ? reply.headers["X-Request-ID"] : nil
    #expect(failure.providerRequestID == requestID)
    #expect(failure.inspectEvidence().providerCode == nil)
    #expect(failure.inspectEvidence().providerRequestID == requestID)
    var progress = RecoveryProgress()
    progress.headersReceived = true
    progress.rawBytes = reply.body.utf8.count
    #expect(failure.progress == progress)
}
