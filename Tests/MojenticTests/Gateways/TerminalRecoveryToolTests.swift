import Foundation
@testable import Mojentic
import Testing

struct TerminalRecoveryToolTests {
    @Test(arguments: StreamingBoundary.withAnthropic.filter { !$0.single }, [false, true])
    func completedToolRunsOnceBeforeCancelledFinalDelivery(
        _ boundary: StreamingBoundary, _ useSession: Bool,
    ) async throws {
        let toolBody = try boundary.frame(tool: true, done: true)
        let finalBody = try boundary.frame(content: "é", done: true, metrics: true)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: toolBody),
            RecoveryReply(headers: ["X-Request-ID": "terminal-original"], body: finalBody),
        ])
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { value in reports.withLock { $0.append(value) } }
        let calls = RecoveryToolCounter()
        let tools: [any LLMTool] = [RecoveryCountingTool(calls: calls)]
        let broker = LLMBroker(gateway: boundary.gateway(server, policy))
        let session = ChatSession(broker: broker, model: "fixture", tools: tools)
        let registrations = RecoveryLocked<Int>(0)
        let terminalReady = AsyncStream<Void>.makeStream()
        let ready = AsyncStream<Void>.makeStream()
        let pause = RecoveryConsumerPause()
        let beforeRegistration: @Sendable (String) async -> Void = { type in
            if type == "Mojentic.StreamEvent" {
                let count = registrations.withLock {
                    $0 += 1
                    return $0
                }
                if count == (useSession ? 8 : 4) {
                    terminalReady.continuation.yield(())
                }
            }
        }
        let task = Task {
            try await withRecoveryStreamCancellation {
                try await RecoveryDeliveryScheduling.$beforeSenderRegistration.withValue(beforeRegistration) {
                    let stream = toolStream(broker, session, tools: tools, useSession: useSession)
                    let consumer = TerminalRecoveryConsumer(stream)
                    let seen = try await [
                        consumer.next(), consumer.next(), consumer.next(),
                    ]
                    #expect(seen == ["tool", "tool-result", "content:é"])
                    var terminal = terminalReady.stream.makeAsyncIterator()
                    _ = await terminal.next()
                    ready.continuation.yield(())
                    await pause.wait()
                    return consumer
                }
            }
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        #expect(calls.value.withLock { $0 } == 1)
        #expect(reports.withLock { $0.count } == 1)
        task.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reports.withLock({ $0.count < 2 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reports.withLock { $0.count } == 2)
        if useSession {
            #expect(await session.messages().isEmpty)
        }
        pause.resume()
        let consumer = try await task.value
        do {
            _ = try await consumer.next()
            Issue.record("Expected final delivery cancellation")
        } catch let failure as RecoveryError {
            #expect(failure.outcome == .cancelled)
            #expect(failure.history.count == 1)
            #expect(failure.failure.inspectEvidence().body == Data(finalBody.utf8))
            #expect(failure.failure.inspectEvidence().cause is CancellationError)
        }
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        #expect(requests[0].0.logicalID != requests[1].0.logicalID)
        #expect(requests[0].0.attemptID != requests[1].0.attemptID)
        #expect(requests.allSatisfy { $0.0.wireNumber == 1 })
        let lifecycle = recorder.events.withLock { $0 }
        #expect(
            lifecycle.map(\.transition) == [
                .attemptStarted, .attemptSucceeded, .attemptStarted, .attemptFailed, .cancelled,
            ]
        )
        #expect(lifecycle.prefix(2).allSatisfy { $0.identity == requests[0].0 })
        #expect(lifecycle.suffix(3).allSatisfy { $0.identity == requests[1].0 })
        let report = try #require(reports.withLock { $0.last })
        #expect(report.history.first?.identity == requests[1].0)
        #expect(report.progress.observed.contentBytes == 2)
        #expect(report.progress.delivered.contentBytes == 2)
        #expect(report.progress.delivered.completedToolCalls == 0)
        #expect(calls.value.withLock { $0 } == 1)
        let payload = try #require(String(data: requests[1].1, encoding: .utf8))
        #expect(payload.contains("tool-sentinel"))
        #expect(payload.contains("resolve_date"))
        if boundary.omlx {
            #expect(payload.contains("original-tool"))
        }
    }

    private func toolStream(
        _ broker: LLMBroker, _ session: ChatSession, tools: [any LLMTool], useSession: Bool,
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        if useSession {
            return session.stream("original-user")
        }
        return broker.stream(model: "fixture", messages: [.user("original-user")], tools: tools)
    }
}
