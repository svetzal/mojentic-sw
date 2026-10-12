import Foundation
@testable import Mojentic
import Testing

func assertPrivateReflection(_ value: Any) {
    func walk(_ value: Any, depth: Int) {
        #expect(depth < 30)
        guard depth < 30 else { return }
        #expect(!(value is Data))
        #expect(!(value is URL))
        #expect(!(value is [UInt8]))
        #expect(!(value is [String: String]))
        if value is any Error {
            #expect(value is RecoveryFailure || value is RecoveryError)
        }
        for child in Mirror(reflecting: value).children {
            #expect(!["evidence", "headers", "body", "cause"].contains(child.label ?? ""))
            walk(child.value, depth: depth + 1)
        }
    }
    walk(value, depth: 0)
    var dumped = ""
    dump(value, to: &dumped)
    for formatted in [dumped, String(describing: value), String(reflecting: value)] {
        #expect(!formatted.contains("sentinel"))
        #expect(!formatted.contains("é猫"))
    }
}

func assertExactMirror(_ value: Any, _ expected: [(String, Any)]) {
    let children = Array(Mirror(reflecting: value).children)
    #expect(children.map(\.label) == expected.map { Optional($0.0) })
    for (actual, expected) in zip(children, expected) {
        if let failure = expected.1 as? RecoveryFailure {
            guard let actualFailure = actual.value as? RecoveryFailure else {
                Issue.record("Expected a typed RecoveryFailure child: \(expected.0)")
                continue
            }
            assertFailureMirror(actualFailure, expected: failure)
        } else if let history = expected.1 as? [RecoveryFailure] {
            guard let actualHistory = actual.value as? [RecoveryFailure] else {
                Issue.record("Expected a typed [RecoveryFailure] child: \(expected.0)")
                continue
            }
            #expect(actualHistory.count == history.count)
            for (actualFailure, expectedFailure) in zip(actualHistory, history) {
                assertFailureMirror(actualFailure, expected: expectedFailure)
            }
        } else if let expectedValue = expected.1 as? any Equatable {
            assertTypedMirrorValue(actual.value, expected: expectedValue)
        } else {
            Issue.record("Missing typed mirror assertion for \(expected.0)")
        }
    }
}

private func assertTypedMirrorValue<Value: Equatable>(_ actual: Any, expected: Value) {
    guard let typed = actual as? Value else {
        Issue.record("Mirror child lost its expected type: \(Value.self)")
        return
    }
    #expect(typed == expected)
}

func assertFailureMirror(_ failure: RecoveryFailure, expected: RecoveryFailure? = nil) {
    let expected = expected ?? failure
    assertExactMirror(
        failure,
        [
            ("logicalID", expected.logicalID), ("identity", expected.identity as Any),
            ("provider", expected.provider), ("operation", expected.operation),
            ("category", expected.category), ("status", expected.status as Any),
            ("retryAfter", expected.retryAfter), ("progress", expected.progress),
            ("acceptance", expected.acceptance), ("phase", expected.phase as Any),
            ("eligible", expected.eligible), ("reason", expected.reason),
            ("providerCode", expected.providerCode as Any),
            ("providerRequestID", expected.providerRequestID as Any),
        ])
    let children = Array(Mirror(reflecting: failure).children)
    #expect(children.first?.value as? UUID == failure.logicalID)
    #expect(children.first { $0.label == "identity" }?.value as? RecoveryIdentity == failure.identity)
    #expect(children.first { $0.label == "progress" }?.value as? RecoveryProgress == failure.progress)
}

func assertEvidenceMirror(_ evidence: RecoveryEvidence) {
    assertExactMirror(
        evidence,
        [
            ("providerCode", evidence.providerCode as Any),
            ("providerRequestID", evidence.providerRequestID as Any),
        ])
}

func assertWireMirror(_ wire: RecoveryWireEvent) {
    switch wire {
    case .request(let identity, _, _, _):
        assertExactMirror(wire, [("kind", "request"), ("identity", identity)])
    case .headers(let identity, let status, _):
        assertExactMirror(wire, [("kind", "headers"), ("identity", identity), ("status", status)])
    case .body(let identity, _):
        assertExactMirror(wire, [("kind", "body"), ("identity", identity)])
    }
}

func invokeReflectionBoundary(
    _ boundary: RecoveryStatusBoundary,
    gateway: any LLMGateway,
    delivered: RecoveryLocked<[String]>,
    observed: RecoveryLocked<[RecoveryCompletionStreamEvent]>,
) async throws {
    guard boundary.operation == .single else {
        try await boundary.invoke(gateway, delivered: delivered)
        return
    }
    var events: [RecoveryCompletionStreamEvent] = []
    for await event in try gateway.completeStreamEventsRecovering(
        model: "fixture", messages: [.user("payload-sentinel")], config: .init(),
    ) {
        assertPrivateReflection(event)
        events.append(event)
        observed.withLock { $0.append(event) }
    }
    #expect(events.count == 1)
    let terminal = try #require(events.first)
    #expect(terminal.isTerminal)
    if case .recoveryFailure(let error) = terminal { throw error }
    Issue.record("Expected a terminal recovery failure")
}

func reflectionExpectedFailures(
    _ boundary: RecoveryStatusBoundary, identities: [RecoveryIdentity], replies: [RecoveryReply],
) -> [RecoveryFailure] {
    let provider: RecoveryProvider =
        boundary.provider.anthropic
        ? .anthropic
        : boundary.provider.openAI ? .openAI : boundary.provider.omlx ? .omlx : .ollama
    let streaming = boundary.operation == .tools || boundary.operation == .single
    let operation: RecoveryOperation =
        streaming ? .streaming : boundary.operation == .ordinary ? .ordinary : .structured
    return zip(identities, replies).map { identity, reply in
        RecoveryFailure(
            logicalID: identity.logicalID,
            identity: identity,
            provider: provider,
            operation: operation,
            category: .http,
            status: reply.status,
            retryAfter: .absent,
            progress: .init(headersReceived: true, rawBytes: reply.body.utf8.count),
            phase: streaming ? .streaming : .decoding,
            eligible: true,
            reason: "selectedHTTPStatus",
            evidence: .init(
                headers: statusHeaders(reply),
                body: Data(reply.body.utf8),
                cause: nil,
                providerCode: nil,
                providerRequestID: provider == .anthropic ? nil : reply.headers["X-Request-ID"],
            ),
        )
    }
}
