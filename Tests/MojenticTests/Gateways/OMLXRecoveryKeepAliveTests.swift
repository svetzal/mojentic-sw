import Foundation
@testable import Mojentic
import Testing

struct OMLXRecoveryKeepAliveTests {
    @Test(arguments: [false, true])
    func keepaliveOnlyRequiresAdmission(_ single: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: single)
        let body = try keepalive() + keepalive()
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body, truncated: true)])
        let recorder = RecoveryRecorder()
        let pending = AsyncStream<Void>.makeStream()
        let decision = AsyncStream<RecoveryAdmission>.makeStream()
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, number in
            #expect(number == 2)
            #expect(failure.progress.rawBytes == body.utf8.count)
            #expect(failure.progress.observed == RecoverySemanticProgress())
            #expect(failure.progress.delivered == RecoverySemanticProgress())
            #expect(failure.inspectEvidence().body == Data(body.utf8))
            #expect(failure.inspectEvidence().cause is URLError)
            pending.continuation.yield(())
            return decision.stream
        }
        let order = RecoveryLocked<[String]>([])
        let task = Task { try await boundary.consume(boundary.gateway(server, policy), record: order) }
        var iterator = pending.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(order.withLock { $0.isEmpty })
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .admissionPending,
            ])
        decision.continuation.yield(.reject)
        decision.continuation.finish()
        let error = try await recoveryFailure { try await task.value }
        #expect(error.outcome == .admissionRejected)
        #expect(error.failure.inspectEvidence().body == Data(body.utf8))
        #expect(server.requests.withLock { $0.count } == 1)
        assertRecoveryRequests(recorder, server)
        let decoder = RecoveryStreamDecoder(provider: .omlx, singleTurn: single)
        _ = decoder.observe(Data(body.utf8), status: 200)
        #expect(decoder.snapshot().evidence == CompletionEvidence())
        #expect(!decoder.snapshot().terminal)
        #expect(decoder.snapshot().frameIndex == 0)
    }

    @Test(arguments: [false, true])
    func interleavedKeepalivesPreserveGenuineFrames(_ single: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: single)
        let first =
            #"data: {"id":"genuine-id","created":42,"model":"genuine-model","choices":["#
            + #"{"index":0,"delta":{"content":"é"},"finish_reason":null}]}"#
            + "\n\n"
        let last = #"data: {"choices":[{"index":0,"delta":{"content":"猫"},"finish_reason":"stop"}]}"# + "\n\n"
        let baseline = first + last + "data: [DONE]\n\n"
        let interleaved = try keepalive() + first + keepalive() + last + keepalive() + "data: [DONE]\n\n"
        for body in [baseline, interleaved] {
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let recorder = RecoveryRecorder()
            let order = RecoveryLocked<[String]>([])
            let policy = recoveryPolicy(recorder)
            let evidence = try await consume(
                boundary, gateway: boundary.gateway(server, policy), order: order)
            if single {
                #expect(evidence?.providerModel == "genuine-model")
                #expect(evidence?.metadata?["id"] == "genuine-id")
                #expect(evidence?.metadata?["created"] == 42)
                #expect(evidence?.finishReason == "stop")
            }
            #expect(order.withLock { $0 } == ["content:é", "content:猫", "completed"])
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [.attemptStarted, .attemptSucceeded])
            #expect(server.requests.withLock { $0.count } == 1)
            assertRecoveryRequests(recorder, server)
            let progress = try #require(recorder.events.withLock { $0.last?.progress })
            #expect(progress.rawBytes == body.utf8.count)
            #expect(progress.observed.contentBytes == 5 && progress.delivered.contentBytes == 5)
            #expect(progress.observed.reasoningBytes == 0 && progress.delivered.reasoningBytes == 0)
            #expect(progress.observed.toolFragments == 0 && progress.delivered.toolFragments == 0)
        }
        let decoder = RecoveryStreamDecoder(provider: .omlx, singleTurn: single)
        _ = decoder.observe(Data(first.utf8), status: 200)
        let genuine = decoder.snapshot().evidence
        #expect(genuine.providerModel == "genuine-model")
        #expect(genuine.metadata?["id"] == "genuine-id")
        #expect(genuine.metadata?["created"] == 42)
        _ = decoder.observe(Data(try keepalive().utf8), status: 200)
        #expect(decoder.snapshot().evidence == genuine)
        #expect(decoder.snapshot().frameIndex == 1)
        _ = decoder.observe(Data((last + "data: [DONE]\n\n").utf8), status: 200)
        #expect(decoder.snapshot().terminal && decoder.snapshot().failure == nil)
        let withoutKeepalives = RecoveryStreamDecoder(provider: .omlx, singleTurn: single)
        _ = withoutKeepalives.observe(Data(baseline.utf8), status: 200)
        #expect(decoder.snapshot().frameIndex == withoutKeepalives.snapshot().frameIndex)
        #expect(decoder.snapshot().frameIndex == 2)
        #expect(decoder.snapshot().evidence == withoutKeepalives.snapshot().evidence)
        #expect(decoder.snapshot().progress.observed.contentBytes == 5)
        #expect(
            decoder.snapshot().progress.rawBytes
                == (try (first + keepalive() + last + "data: [DONE]\n\n").utf8.count))
    }

    @Test(arguments: [false, true], [false, true])
    func exactModelAndProviderGuard(_ single: Bool, _ openAI: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: single, openAI: openAI)
        let model = openAI ? "keepalive" : "keepalive-2"
        let body =
            (#"data: {"model":"MODEL","choices":[{"index":0,"delta":{"content":"ordinary"},"#
            + #""finish_reason":"stop"}]}"#)
            .replacingOccurrences(of: "MODEL", with: model) + "\n\ndata: [DONE]\n\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        let order = RecoveryLocked<[String]>([])
        let evidence = try await consume(
            boundary, gateway: boundary.gateway(server, recoveryPolicy(recorder)), order: order)
        #expect(order.withLock { $0 } == ["content:ordinary", "completed"])
        if single { #expect(evidence?.providerModel == model) }
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(recorder.events.withLock { $0.map(\.transition) } == [.attemptStarted, .attemptSucceeded])
        let decoder = RecoveryStreamDecoder(provider: openAI ? .openAI : .omlx, singleTurn: single)
        _ = decoder.observe(Data(body.utf8), status: 200)
        #expect(decoder.snapshot().frameIndex == 1)
        #expect(decoder.snapshot().evidence.providerModel == model)
        #expect(decoder.snapshot().progress.observed.contentBytes == 8)
    }

    private func consume(
        _ boundary: StreamingBoundary,
        gateway: any LLMGateway,
        order: RecoveryLocked<[String]>,
    ) async throws -> CompletionEvidence? {
        guard boundary.single else {
            try await boundary.consume(gateway, record: order)
            return nil
        }
        var evidence: CompletionEvidence?
        for await event in try gateway.completeStreamEventsRecovering(
            model: "fixture", messages: [], config: .init())
        {
            switch event {
            case .content(let text): order.withLock { $0.append("content:\(text)") }
            case .completed(let value):
                evidence = value
                order.withLock { $0.append("completed") }
            case .recoveryFailure(let error): throw error
            case .error(let error): throw error
            default: Issue.record("Unexpected semantic telemetry")
            }
        }
        return evidence
    }

    private func keepalive() throws -> String {
        try #require(OMLXFixture.lines("stream_thinking.sse").first) + "\n\n"
    }
}
