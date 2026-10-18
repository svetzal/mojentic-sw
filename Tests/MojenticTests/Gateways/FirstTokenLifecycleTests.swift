import Foundation
import Mojentic
import Testing

struct FirstTokenLifecycleTests {
    @Test(arguments: [false, true])
    func firstArgumentFragmentPrecedesTerminalAssembly(_ recovery: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: false, openAI: true)
        let prefix =
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\""
            + "t\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\"}}]}}]}\n\n"
        let suffix =
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"functio"
            + "n\":{\"arguments\":\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\nda"
            + "ta: [DONE]\n\n"
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(
                body: prefix + suffix, splitAt: prefix.utf8.count, holdSuffix: true)
        ])
        defer { server.release() }
        let gateway = boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil)
        let task = Task {
            try await firstTokenOutcome(
                boundary,
                gateway: gateway,
                recovering: recovery)
        }
        var arrival = server.arrivals.makeAsyncIterator()
        #expect(await arrival.next() == 1)
        try await Task.sleep(for: .milliseconds(200))
        server.releaseSuffix()
        let result = try await task.value
        try assertFirstToken(result, kind: "tool_call", terminal: "done")
        let metadata = try #require(result.evidence?.metadata)
        let first = try #require(timingNumber(metadata["time_to_first_token_ms"]))
        let duration = try #require(timingNumber(metadata["request_duration_ms"]))
        #expect(duration - first >= 150)
    }

    @Test(arguments: StreamingBoundary.withAnthropic)
    func delayedCaptureIsOutsideFirstDispatch(_ boundary: StreamingBoundary) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: boundary.frame(content: "answer", done: true))
        ])
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.wireObserver = { event in
            if case .request = event { Thread.sleep(forTimeInterval: 0.2) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await firstTokenOutcome(
            boundary,
            gateway: boundary.gateway(server, policy),
            recovering: true)
        let elapsed = start.duration(to: clock.now).components
        let wall = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        try assertFirstToken(result, kind: "content", terminal: boundary.single ? "completed" : "done")
        let duration = try #require(timingNumber(result.evidence?.metadata?["request_duration_ms"]))
        #expect(wall - duration >= 180)
    }

    @Test(arguments: StreamingBoundary.all.filter { !$0.single }, [false, true])
    func brokerAndSessionToolContinuationsUseFreshClocks(
        _ boundary: StreamingBoundary, _ session: Bool
    ) async throws {
        let firstBody = try boundary.frame(tool: true, done: true)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: firstBody),
            RecoveryReply(body: boundary.frame(content: "answer", done: true)),
        ])
        let broker = LLMBroker(gateway: boundary.gateway(server, recoveryPolicy(RecoveryRecorder())))
        let chat = ChatSession(broker: broker, model: "fixture", tools: [TimingTool()])
        let start = ContinuousClock.now
        var completions: [CompletionEvidence] = []
        var final: LLMResponse?
        let stream =
            session
            ? chat.stream("hello")
            : broker.stream(model: "fixture", messages: [.user("hello")], tools: [TimingTool()])
        for try await event in stream {
            if case .metrics(let evidence) = event { completions.append(evidence) }
            if case .done(let response) = event { final = response }
        }
        let elapsed = start.duration(to: .now).components
        let total = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        #expect(completions.count == 2)
        let first = try #require(completions.first)
        let last = try #require(completions.last)
        #expect(first.metadata?["first_token_kind"] == .string("tool_call"))
        #expect(last.metadata?["first_token_kind"] == .string("content"))
        let firstDuration = try #require(timingNumber(first.metadata?["request_duration_ms"]))
        let lastDuration = try #require(timingNumber(last.metadata?["request_duration_ms"]))
        #expect(total - firstDuration - lastDuration >= 150)
        #expect(final?.content == "answer")
        #expect(final?.metadata == last.metadata)
        #expect(server.requests.withLock { $0.count } == 2)
        if session { #expect(await chat.messages().map(\.role) == [.user, .assistant]) }
    }

    @Test(arguments: [false, true])
    func failedToolContinuationHasFreshTimingAndNoReplay(_ session: Bool) async throws {
        let boundary = StreamingBoundary(omlx: true, single: false, openAI: true)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: boundary.frame(tool: true, done: true)),
            RecoveryReply(body: boundary.frame(content: "partial"), truncated: true),
        ])
        let broker = LLMBroker(gateway: boundary.gateway(server, recoveryPolicy(RecoveryRecorder())))
        let chat = ChatSession(broker: broker, model: "fixture", tools: [TimingTool()])
        let start = ContinuousClock.now
        var first: CompletionEvidence?
        var failure: RecoveryError?
        var tools = 0
        let stream =
            session
            ? chat.stream("hello")
            : broker.stream(
                model: "fixture", messages: [.user("hello")], tools: [TimingTool()])
        do {
            for try await event in stream {
                if case .metrics(let evidence) = event { first = evidence }
                if case .toolCallResult = event { tools += 1 }
                if case .done = event { Issue.record("Partial continuation must not complete") }
            }
        } catch let error as RecoveryError { failure = error }
        let error = try #require(failure)
        #expect(error.outcome == .interrupted)
        #expect(error.failure.progress.observed.contentBytes == 7)
        #expect(tools == 1)
        #expect(server.requests.withLock { $0.count } == 2)
        try assertFirstToken(
            FirstTokenOutcome(evidence: error.evidence, terminal: "interrupted"),
            kind: "content",
            terminal: "interrupted")
        #expect(first?.metadata?["first_token_kind"] == .string("tool_call"))
        let firstDuration = try #require(timingNumber(first?.metadata?["request_duration_ms"]))
        let failedDuration = try #require(timingNumber(error.evidence?.metadata?["request_duration_ms"]))
        let elapsed = start.duration(to: .now).components
        let total = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        #expect(total - firstDuration - failedDuration >= 150)
        if session { #expect(await chat.messages().isEmpty) }
    }

    @Test
    func concurrentCompletionsNeverShareOriginsOrKinds() async throws {
        let slowBoundary = StreamingBoundary(omlx: false, single: true)
        let fastBoundary = StreamingBoundary(omlx: true, single: true)
        let slowBody = try slowBoundary.frame(reasoning: "thought", done: true)
        let slow = try RecoveryLoopback(replies: [RecoveryReply(body: slowBody, splitAt: 0, holdSuffix: true)]
        )
        let fast = try RecoveryLoopback(replies: [
            RecoveryReply(body: fastBoundary.frame(content: "answer", done: true))
        ])
        defer { slow.release() }
        let pending = Task {
            try await firstTokenOutcome(
                slowBoundary,
                gateway: slowBoundary.gateway(slow, recoveryPolicy(RecoveryRecorder())),
                recovering: true)
        }
        var arrivals = slow.arrivals.makeAsyncIterator()
        _ = await arrivals.next()
        let fastResult = try await firstTokenOutcome(
            fastBoundary,
            gateway: fastBoundary.gateway(fast, nil),
            recovering: false)
        try await Task.sleep(for: .milliseconds(150))
        slow.releaseSuffix()
        let slowResult = try await pending.value
        try assertFirstToken(fastResult, kind: "content", terminal: "completed")
        try assertFirstToken(slowResult, kind: "thinking", terminal: "completed", minimum: 150)
        let fastDuration = try #require(timingNumber(fastResult.evidence?.metadata?["request_duration_ms"]))
        let slowFirst = try #require(timingNumber(slowResult.evidence?.metadata?["time_to_first_token_ms"]))
        #expect(slowFirst - fastDuration >= 100)
    }
}

private struct TimingTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "resolve_date", description: "Resolve a date", parameters: ["type": "object"])
    func execute(arguments _: JSONValue) async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(200))
        return ["date": "tomorrow"]
    }
}
