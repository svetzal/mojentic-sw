import Foundation
@testable import Mojentic
import Testing

struct RecoveryStatusBoundary: Sendable, CustomStringConvertible {
    enum Operation: String, CaseIterable, Sendable {
        case ordinary, structured, json, tools, single
    }

    let provider: RecoveryBoundary
    let operation: Operation
    var description: String {
        "\(provider)/\(operation.rawValue)"
    }

    var buffered: RecoveryBoundary {
        RecoveryBoundary(
            omlx: provider.omlx,
            structured: operation != .ordinary,
            openAI: provider.openAI,
            anthropic: provider.anthropic,
        )
    }

    static var all: [Self] {
        RecoveryBoundary.all.filter { !$0.structured }.flatMap { provider in
            Operation.allCases.map { Self(provider: provider, operation: $0) }
        }
    }

    func invoke(_ gateway: any LLMGateway, delivered: RecoveryLocked<[String]>) async throws {
        switch operation {
        case .ordinary, .structured:
            let response = try await buffered.complete(gateway)
            delivered.withLock { $0.append(response.content) }
        case .json:
            let json = try await gateway.completeJSON(
                model: "fixture",
                messages: [.user("payload-sentinel")],
                schema: ["type": "object"],
                config: .init(temperature: 0.25, maxTokens: 123, topP: 0.8, reasoning: .high),
            )
            #expect(json == ["answer": 42])
            delivered.withLock { $0.append("json:42") }
        case .tools, .single:
            try await StreamingBoundary(
                omlx: provider.omlx,
                single: operation == .single,
                openAI: provider.openAI,
                anthropic: provider.anthropic,
            ).consume(gateway, record: delivered)
        }
    }
}

func statusReply(_ status: Int, attempt: Int, truncated: Bool) -> RecoveryReply {
    RecoveryReply(
        status: status,
        headers: ["X-Request-ID": "credential-sentinel-\(attempt)", "X-Exact": "wire-\(attempt)"],
        body: "payload-sentinel é猫 attempt-\(attempt)",
        truncated: truncated,
    )
}

func statusHeaders(_ reply: RecoveryReply) -> [String: String] {
    var headers = reply.headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
    headers["content-length"] = String(reply.body.utf8.count + (reply.truncated ? 20 : 0))
    headers["connection"] = "close"
    headers["content-type"] = "application/json"
    return headers
}

func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
    headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
}

/// Compares ordered captures to actual socket bytes and exact scripted HTTP evidence.
func assertStatusWires(
    _ recorder: RecoveryRecorder, server: RecoveryLoopback, replies: [RecoveryReply],
) throws -> [RecoveryIdentity] {
    let requests = recorder.requests.withLock { $0 }
    #expect(server.requests.withLock { $0 } == requests.map(\.1))
    try #require(requests.count == replies.count)
    let first = try #require(requests.first)
    #expect(requests.map(\.1) == replies.map { _ in first.1 })
    let identities = requests.map(\.0)
    #expect(identities.map(\.wireNumber) == Array(1...replies.count))
    #expect(identities.map(\.logicalID) == replies.map { _ in first.0.logicalID })
    for index in identities.indices {
        for earlier in identities.prefix(index) {
            #expect(identities[index].attemptID != earlier.attemptID)
        }
    }
    var headerIDs: [RecoveryIdentity] = []
    var bodies: [Data] = []
    var requestIDs: [RecoveryIdentity] = []
    for event in recorder.wires.withLock({ $0 }) {
        switch event {
        case .request(let identity, _, _, let bytes):
            let index = requestIDs.count
            try #require(identities.indices.contains(index))
            #expect(headerIDs == Array(identities.prefix(index)))
            #expect(bodies == replies.prefix(index).map { Data($0.body.utf8) })
            #expect(identity == identities[index])
            #expect(bytes == requests[index].1)
            requestIDs.append(identity)
        case .headers(let identity, let status, let headers):
            let index = headerIDs.count
            try #require(identities.indices.contains(index))
            #expect(requestIDs == Array(identities.prefix(index + 1)))
            #expect(identity == identities[index])
            #expect(status == replies[index].status)
            #expect(normalizedHeaders(headers) == statusHeaders(replies[index]))
            headerIDs.append(identity)
            bodies.append(Data())
        case .body(let identity, let data):
            let index = try #require(bodies.indices.last)
            #expect(identity == identities[index])
            bodies[index].append(data)
        }
    }
    #expect(requestIDs == identities)
    #expect(headerIDs == identities)
    #expect(bodies == replies.map { Data($0.body.utf8) })
    return identities
}

func assertStatusFailure(
    _ failure: RecoveryFailure, identity: RecoveryIdentity, reply: RecoveryReply,
) throws {
    #expect(failure.identity == identity)
    #expect(failure.logicalID == identity.logicalID)
    #expect(failure.category == .http)
    #expect(failure.status == reply.status)
    #expect(failure.acceptance == .unknown)
    #expect(failure.eligible == ([503, 504].contains(reply.status)))
    #expect(
        failure.reason == ([503, 504].contains(reply.status) ? "selectedHTTPStatus" : "permanentHTTPStatus")
    )
    #expect(failure.progress.headersReceived)
    #expect(failure.progress.rawBytes == reply.body.utf8.count)
    #expect(failure.progress.observed == RecoverySemanticProgress())
    #expect(failure.progress.delivered == RecoverySemanticProgress())
    let evidence = failure.inspectEvidence()
    #expect(normalizedHeaders(evidence.headers) == statusHeaders(reply))
    #expect(evidence.body == Data(reply.body.utf8))
    if reply.truncated {
        let cause = try #require(evidence.cause as? URLError)
        #if os(Linux)
            #expect(cause.code == .unknown)
        #else
            #expect(cause.code == .networkConnectionLost)
        #endif
    } else {
        let cause = try #require(evidence.cause as? RecoveryHTTPStatusFailure)
        #expect(cause.status == reply.status)
    }
}
