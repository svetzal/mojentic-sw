import Foundation
import Testing

@testable import Mojentic

struct StreamingRecoveryTests {
    @Test(arguments: StreamingBoundary.all, [400, 401, 403, 504])
    func numericFailuresAndPrivateEvidence(_ boundary: StreamingBoundary, _ status: Int) async throws {
        let reply = RecoveryReply(
            status: status,
            headers: ["X-Request-ID": "payload-sentinel"],
            body: "credential-sentinel",
            truncated: status != 504)
        let server = try RecoveryLoopback(replies: [reply])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder, attempts: 3)
        policy.retryableStatuses.formUnion([400, 401, 403])
        policy.retryableCategories.insert(.transport)
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, policy))
        }
        #expect(failure.outcome == (status == 504 ? .exhausted : .ineligible))
        #expect(failure.history.count == (status == 504 ? 3 : 1))
        #expect(failure.failure.status == status)
        #expect(failure.failure.inspectEvidence().body == Data(reply.body.utf8))
        #expect(failure.failure.progress.rawBytes == reply.body.utf8.count)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(server.requests.withLock { $0.count } == failure.history.count)
        if status == 504 {
            #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        } else {
            #expect(failure.failure.inspectEvidence().cause is URLError)
        }
        let safe = String(describing: failure) + String(reflecting: failure)
        let events = try JSONEncoder().encode(recorder.events.withLock { $0 })
        #expect(!safe.contains("sentinel"))
        #expect(!(String(data: events, encoding: .utf8) ?? "").contains("sentinel"))
        #expect(!String(reflecting: recorder.events.withLock { $0 }).contains("sentinel"))
    }

    @Test(arguments: StreamingBoundary.all, ["content", "reasoning", "tool"])
    func semanticInterruptionNeverRetries(_ boundary: StreamingBoundary, _ kind: String) async throws {
        let body = try boundary.frame(
            content: kind == "content" ? "é🐈" : "",
            reasoning: kind == "reasoning" ? "想" : "",
            tool: kind == "tool")
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body, truncated: true)])
        let recorder = RecoveryRecorder()
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)))
        }
        #expect(failure.outcome == .interrupted)
        #expect(!failure.failure.eligible)
        #expect(failure.history.count == 1)
        #expect(server.requests.withLock { $0.count } == 1)
        let progress = failure.failure.progress
        #expect(progress.observed.contentBytes == (kind == "content" ? 6 : 0))
        #expect(progress.observed.reasoningBytes == (kind == "reasoning" ? 3 : 0))
        #expect(progress.observed.toolFragments == (kind == "tool" ? 1 : 0))
        #expect(progress.delivered.contentBytes == (kind == "content" ? 6 : 0))
        #expect(progress.delivered.reasoningBytes == (kind == "reasoning" && !boundary.single ? 3 : 0))
        #expect(progress.delivered.completedToolCalls == 0)
        #expect(failure.failure.inspectEvidence().body == Data(body.utf8))
        #expect(!recorder.events.withLock { $0.map(\.transition) }.contains(.attemptSucceeded))
    }

    @Test(arguments: StreamingBoundary.all)
    func captureAfterObservationPreventsDelivery(_ boundary: StreamingBoundary) async throws {
        let body = try boundary.frame(content: "é", reasoning: "想", done: true, metrics: true)
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.wireObserver = { event in if case .body = event { throw RecoveryCaptureSentinel() } }
        let seen = RecoveryLocked<[String]>([])
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, policy), record: seen)
        }
        #expect(failure.outcome == .captureFailed)
        #expect(failure.failure.inspectEvidence().cause is RecoveryCaptureSentinel)
        #expect(failure.failure.progress.observed.contentBytes == 2)
        #expect(failure.failure.progress.observed.reasoningBytes == 3)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(seen.withLock { $0.isEmpty })
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true])
    func validatedLengthPreservesTelemetryOnly(_ single: Bool) async throws {
        let boundary = StreamingBoundary(omlx: false, single: single)
        let body = try boundary.frame(
            content: "é",
            reasoning: "想",
            tool: true,
            done: true,
            reason: "length",
            metrics: true)
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        let seen = RecoveryLocked<[String]>([])
        let failure = try await recoveryFailure {
            try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)), record: seen)
        }
        #expect(seen.withLock { $0 } == ["progress", "metrics"])
        #expect(failure.outcome == .interrupted)
        #expect(failure.failure.progress.observed.contentBytes == 2)
        #expect(failure.failure.progress.observed.reasoningBytes == 3)
        #expect(failure.failure.progress.observed.completedToolCalls == 1)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        if case .incompleteCompletion(let evidence)? = failure.failure.inspectEvidence().cause
            as? MojenticError
        {
            #expect(evidence.finishReason == "length")
            #expect(evidence.usage?.completionTokens == 12)
            #expect(evidence.metadata?["eval_duration"] == .integer(6_000_000_000))
        } else {
            Issue.record("Expected original finish-validation failure")
        }
        #expect(
            recorder.events.withLock { $0.suffix(2).map(\.transition) } == [.attemptFailed, .interrupted])
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: StreamingBoundary.all)
    func legacyRemainsSingleSend(_ boundary: StreamingBoundary) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 503, body: "legacy")])
        do {
            try await boundary.consume(boundary.gateway(server, nil))
            Issue.record("Expected rejection")
        } catch { #expect(!(error is RecoveryError)) }
        #expect(server.requests.withLock { $0.count } == 1)
    }
}
