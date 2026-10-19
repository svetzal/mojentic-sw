import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryProviderMetadataTests {
    @Test
    func wrappedCredentialAndEscapedPayload() async throws {
        let boundary = RecoveryBoundary(omlx: true, structured: true, openAI: true)
        let replies = [
            RecoveryReply(
                status: 503,
                headers: ["X-Request-ID": "credential-sentinel"],
                body: #"{"error":{"code":"server_error"}}"#,
            ),
            RecoveryReply(
                status: 503,
                headers: ["X-Request-ID": "nested-sentinel"],
                body: #"{"error":{"code":"unknown_code"}}"#,
            ),
        ]
        let server = try InProcessHTTPFixture(replies: replies)
        let recorder = RecoveryRecorder()
        let admitted = RecoveryLocked<[RecoveryFailure]>([])
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, _ in
            admitted.withLock { $0.append(failure) }
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        policy.reportObserver = { report in reports.withLock { $0.append(report) } }
        let gateway = boundary.gateway(server, policy: policy)
        let error = try await recoveryFailure {
            _ = try await gateway.completeStructured(
                model: "fixture",
                messages: [.user("quoted \"nested-sentinel\"\n")],
                schema: ["type": "object", "properties": ["nested": ["enum": ["nested-sentinel"]]]],
                config: .init(),
            )
        }
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        #expect(
            server.requestHeaders.withLock { $0 }.allSatisfy { $0.contains("Bearer credential-sentinel") })
        let failures =
            error.history + [error.failure] + admitted.withLock { $0 }
            + reports.withLock { $0.flatMap(\.history) }
        for failure in failures {
            let index = try #require(failure.identity?.wireNumber) - 1
            try assertStatusFailure(failure, identity: identities[index], reply: replies[index])
            try assertExactMetadataHeaders(failure, recorder: recorder)
            #expect(failure.providerRequestID == nil)
            #expect(failure.inspectEvidence().providerRequestID == nil)
            #expect(failure.providerCode == (index == 0 ? "server_error" : nil))
            #expect(failure.inspectEvidence().providerCode == failure.providerCode)
        }
        let payload = try #require(recorder.requests.withLock { $0.first?.1 })
        let fields = try JSONDecoder().decode(JSONValue.self, from: payload)
        #expect(
            fields.objectValue?["messages"] == [["role": "user", "content": "quoted \"nested-sentinel\"\n"]])

    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func everyPublicExposure(_ boundary: RecoveryStatusBoundary) async throws {
        let anthropic = boundary.provider.anthropic
        let allowed = anthropic ? "overloaded_error" : "server_error"
        let codes = ["credential-sentinel", allowed, allowed, allowed, "unknown_code", allowed, allowed]
        var ids = [
            "req-unrelated-1", "credential-sentinel", "payload-sentinel",
            "nested-sentinel", "req-unrelated-5", "req-unrelated-6", "decoded-sentinel",
        ]
        if [.structured, .json].contains(boundary.operation) {
            ids.insert("schema-sentinel", at: 4)
        }
        var expectedCodes = codes.map { $0 == allowed ? allowed : nil }
        if ids.count > codes.count { expectedCodes.insert(allowed, at: 4) }
        let replies = try ids.indices.map { index in
            try metadataReply(
                code: expectedCodes[index] ?? (index == 0 ? "credential-sentinel" : "unknown_code"),
                requestID: ids[index],
                anthropic: anthropic,
            )
        }
        let server = try InProcessHTTPFixture(replies: replies)
        let recorder = RecoveryRecorder()
        let admitted = RecoveryLocked<[RecoveryFailure]>([])
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder, attempts: replies.count)
        policy.admission = { failure, _ in
            admitted.withLock { $0.append(failure) }
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
        #expect(error.outcome == .exhausted)
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        #expect(error.history.map(\.identity) == identities.map(Optional.some))
        #expect(admitted.withLock { $0.map(\.identity) } == identities.dropLast().map(Optional.some))
        let report = try #require(reports.withLock { $0.first })
        #expect(reports.withLock { $0.count } == 1)
        #expect(report.history.map(\.identity) == identities.map(Optional.some))
        #expect(report.identity == identities.last)
        let failures = error.history + [error.failure] + admitted.withLock { $0 } + report.history
        for failure in failures {
            let index = try #require(failure.identity?.wireNumber) - 1
            try assertStatusFailure(failure, identity: identities[index], reply: replies[index])
            try assertExactMetadataHeaders(failure, recorder: recorder)
            #expect(failure.providerCode == expectedCodes[index])
            #expect(failure.inspectEvidence().providerCode == expectedCodes[index])
            let expectedID = ids[index].hasPrefix("req-unrelated") ? ids[index] : nil
            #expect(failure.providerRequestID == expectedID)
            #expect(failure.inspectEvidence().providerRequestID == expectedID)
        }
        try assertMetadataPayload(#require(recorder.requests.withLock { $0.first?.1 }), boundary: boundary)
        #expect(server.requestHeaders.withLock { $0 }.allSatisfy { $0.contains("credential-sentinel") })
    }

}
