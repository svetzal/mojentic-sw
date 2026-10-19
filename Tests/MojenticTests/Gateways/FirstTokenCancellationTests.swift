import Foundation
@testable import Mojentic
import Testing

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenCancellationTests {
    @Test(arguments: StreamingBoundary.withAnthropic.filter { !$0.single }, [false, true])
    func cancellationRetainsObservedTimingAndTypedRecovery(
        _ boundary: StreamingBoundary, _ content: Bool
    ) async throws {
        let body = content ? try boundary.frame(content: "partial") : "\n"
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(body: body, truncated: true, hold: true)
        ])
        defer { server.release() }
        let observed = AsyncStream<Void>.makeStream()
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.wireObserver = { event in
            if case .body = event { observed.continuation.yield(()) }
        }
        let report = RecoveryLocked<CompletionRecoveryReport?>(nil)
        policy.reportObserver = { value in report.withLock { $0 = value } }
        let gateway = boundary.gateway(server, policy)
        let pause = RecoveryConsumerPause()
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            await withRecoveryStreamCancellation {
                let stream = gateway.streamRecovering(
                    model: "fixture", messages: [], tools: nil, config: .init())
                ready.continuation.yield(())
                await pause.wait()
                return stream
            }
        }
        for await _ in ready.stream { break }
        var signal = observed.stream.makeAsyncIterator()
        _ = await signal.next()
        TestStreamClock.current?.advance(50)
        task.cancel()
        await report.wait { $0 != nil }
        pause.resume()
        let retained = await task.value
        var result = FirstTokenOutcome()
        do {
            for try await event in retained { result.record(event) }
            Issue.record("Retained public stream must deliver typed cancellation")
        } catch let error as RecoveryError {
            #expect(error.outcome == .cancelled)
            #expect(error.failure.category == .cancellation)
            result.evidence = error.evidence
            result.terminal = error.outcome.rawValue
        }
        try assertFirstToken(result, kind: content ? "content" : nil, terminal: "cancelled")
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: StreamingBoundary.withAnthropic, [false, true])
    func cancellationReportRetainsTimingAfterIterationStops(
        _ boundary: StreamingBoundary, _ content: Bool
    ) async throws {
        let body = content ? try boundary.frame(content: "partial") : "\n"
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(body: body, truncated: true, hold: true)
        ])
        defer { server.release() }
        let observed = AsyncStream<Void>.makeStream()
        let reports = AsyncStream<CompletionRecoveryReport>.makeStream()
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.wireObserver = { event in
            if case .body = event { observed.continuation.yield(()) }
        }
        policy.reportObserver = { report in reports.continuation.yield(report) }
        let gateway = boundary.gateway(server, policy)
        let task = Task {
            try await withRecoveryStreamCancellation {
                try await firstTokenOutcome(boundary, gateway: gateway, recovering: true)
            }
        }
        var signal = observed.stream.makeAsyncIterator()
        _ = await signal.next()
        task.cancel()
        _ = try await task.value
        var reported = reports.stream.makeAsyncIterator()
        let report = try #require(await reported.next())
        #expect(report.history.last?.category == .cancellation)
        try assertFirstToken(
            FirstTokenOutcome(evidence: report.evidence, terminal: "cancelled"),
            kind: content ? "content" : nil,
            terminal: "cancelled")
    }

    @Test(arguments: [false, true])
    func argumentFragmentSurvivesFailureBeforeToolAssembly(_ recovery: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: false, openAI: true)
        let prefix =
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\""
            + "t\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\"}}]}}]}\n\n"
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(body: prefix, truncated: true, hold: true)
        ])
        defer { server.release() }
        let task = Task {
            try await firstTokenOutcome(
                boundary,
                gateway: boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil),
                recovering: recovery)
        }
        var arrivals = server.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        await server.deliveries.wait { $0 > 0 }
        TestStreamClock.current?.advance(200)
        server.release()
        let result = try await task.value
        try assertFirstToken(result, kind: "tool_call", terminal: recovery ? "interrupted" : "throw")
        #expect(result.content.isEmpty)
        #expect(result.tools.isEmpty)
        let first = try #require(timingNumber(result.evidence?.metadata?["time_to_first_token_ms"]))
        let duration = try #require(timingNumber(result.evidence?.metadata?["request_duration_ms"]))
        #expect(duration - first == 200)
    }
}
