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
        #expect(String(reflecting: actual.value) == String(reflecting: expected.1))
    }
}

func assertFailureMirror(_ failure: RecoveryFailure) {
    assertExactMirror(
        failure,
        [
            ("logicalID", failure.logicalID), ("identity", failure.identity as Any),
            ("provider", failure.provider), ("operation", failure.operation),
            ("category", failure.category), ("status", failure.status as Any),
            ("retryAfter", failure.retryAfter), ("progress", failure.progress),
            ("acceptance", failure.acceptance), ("phase", failure.phase as Any),
            ("eligible", failure.eligible), ("reason", failure.reason),
            ("providerCode", failure.providerCode as Any),
            ("providerRequestID", failure.providerRequestID as Any),
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
    _ boundary: RecoveryStatusBoundary, gateway: any LLMGateway, delivered: RecoveryLocked<[String]>,
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
    }
    #expect(events.count == 1)
    let terminal = try #require(events.first)
    #expect(terminal.isTerminal)
    if case .recoveryFailure(let error) = terminal { throw error }
    Issue.record("Expected a terminal recovery failure")
}
