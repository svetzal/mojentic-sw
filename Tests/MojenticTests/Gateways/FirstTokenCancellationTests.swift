import Foundation
import Mojentic
import Testing

struct FirstTokenCancellationTests {
    @Test(arguments: StreamingBoundary.withAnthropic.filter { !$0.single }, [false, true])
    func cancellationRetainsObservedTimingAndTypedRecovery(
        _ boundary: StreamingBoundary, _ content: Bool
    ) async throws {
        let body = content ? try boundary.frame(content: "partial") : "\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body, truncated: true, hold: true)])
        defer { server.release() }
        let observed = AsyncStream<Void>.makeStream()
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.wireObserver = { event in
            if case .body = event { observed.continuation.yield(()) }
        }
        let gateway = boundary.gateway(server, policy)
        let task = Task {
            try await withRecoveryStreamCancellation {
                try await firstTokenOutcome(
                    boundary,
                    gateway: gateway,
                    recovering: true)
            }
        }
        var signal = observed.stream.makeAsyncIterator()
        _ = await signal.next()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = try await task.value
        try assertFirstToken(
            result,
            kind: content ? "content" : nil,
            terminal: "cancelled")
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: StreamingBoundary.withAnthropic, [false, true])
    func cancellationReportRetainsTimingAfterIterationStops(
        _ boundary: StreamingBoundary, _ content: Bool
    ) async throws {
        let body = content ? try boundary.frame(content: "partial") : "\n"
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body, truncated: true, hold: true)])
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
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: prefix, truncated: true, hold: true)])
        defer { server.release() }
        let task = Task {
            try await firstTokenOutcome(
                boundary,
                gateway: boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil),
                recovering: recovery)
        }
        var arrivals = server.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        try await Task.sleep(for: .milliseconds(200))
        server.release()
        let result = try await task.value
        try assertFirstToken(result, kind: "tool_call", terminal: recovery ? "interrupted" : "throw")
        #expect(result.content.isEmpty)
        #expect(result.tools.isEmpty)
        let first = try #require(timingNumber(result.evidence?.metadata?["time_to_first_token_ms"]))
        let duration = try #require(timingNumber(result.evidence?.metadata?["request_duration_ms"]))
        #expect(duration - first >= 150)
    }
}
