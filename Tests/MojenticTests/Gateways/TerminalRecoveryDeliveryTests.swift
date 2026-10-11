import Foundation
@testable import Mojentic
import Testing

struct TerminalRecoveryDeliveryTests {
    @Test(
        arguments: StreamingBoundary.withAnthropic,
        [
            ("gateway", false), ("gateway", true), ("broker", false), ("broker", true),
            ("session", false), ("session", true),
        ],
    )
    func terminalAcceptanceOwnsAttempt(
        _ boundary: StreamingBoundary, _ scenario: (String, Bool),
    ) async throws {
        let (path, cancel) = scenario
        if boundary.single, path == "session" {
            return
        }
        let body = try boundary.frame(content: "é", reasoning: "ré", done: true, metrics: true)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(headers: ["X-Request-ID": "terminal-original"], body: body)
        ])
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { value in reports.withLock { $0.append(value) } }
        let gateway = boundary.gateway(server, policy)
        let broker = LLMBroker(gateway: gateway)
        let session = ChatSession(broker: broker, model: "fixture")
        let expected = boundary.terminalOrder(path: path)
        let registrations = RecoveryLocked<Int>(0)
        let terminalReady = AsyncStream<Void>.makeStream()
        let ready = AsyncStream<Void>.makeStream()
        let pause = RecoveryConsumerPause()
        let type = boundary.terminalElementType(path: path)
        let layers = path == "session" || (boundary.single && path == "broker") ? 2 : 1
        let beforeRegistration: @Sendable (String) async -> Void = { element in
            if element == type {
                let count = registrations.withLock {
                    $0 += 1
                    return $0
                }
                if count == layers * (expected.count + 1) {
                    terminalReady.continuation.yield(())
                }
            }
        }
        let task = Task {
            try await withRecoveryStreamCancellation {
                try await RecoveryDeliveryScheduling.$beforeSenderRegistration.withValue(beforeRegistration) {
                    let consumer = try makeConsumer(boundary, path, gateway, broker, session)
                    var seen: [String] = []
                    for _ in expected {
                        try seen.append(#require(await consumer.next()))
                    }
                    #expect(seen == expected)
                    var terminal = terminalReady.stream.makeAsyncIterator()
                    _ = await terminal.next()
                    ready.continuation.yield(())
                    await pause.wait()
                    if !cancel {
                        #expect(try await consumer.next() == "terminal")
                        #expect(try await consumer.next() == nil)
                    }
                    return consumer
                }
            }
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        #expect(reports.withLock { $0.isEmpty })
        #expect(recorder.events.withLock { $0.map(\.transition) } == [.attemptStarted])
        if cancel {
            task.cancel()
            try await awaitReport(reports)
            #expect(reports.withLock { $0.count } == 1)
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [
                    .attemptStarted, .attemptFailed, .cancelled,
                ]
            )
            if path == "session" {
                #expect(await session.messages().isEmpty)
            }
        }
        pause.resume()
        let consumer = try await task.value
        if cancel {
            try await verifyPublicTerminalCancellation(consumer, reports, body: body)
            if boundary.single {
                #expect(try await consumer.next() == nil)
            }
        } else {
            try await awaitReport(reports)
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [.attemptStarted, .attemptSucceeded]
            )
            if path == "session" {
                #expect(await session.messages().map(\.role) == [.user, .assistant])
            }
        }
        try verifyTerminalEvidence(boundary, body, server, recorder, reports, cancel: cancel)
        let telemetry = consumer.metrics.withLock { $0 }
        if expected.contains("metrics") {
            #expect(telemetry.last?.usage?.promptTokens == 3)
            #expect(telemetry.last?.usage?.completionTokens == 12)
            if boundary.anthropic {
                #expect(telemetry.first?.usage?.completionTokens == 0)
            }
        } else {
            #expect(telemetry.isEmpty)
        }
    }

    private func makeConsumer(
        _ boundary: StreamingBoundary,
        _ path: String,
        _ gateway: any LLMGateway,
        _ broker: LLMBroker,
        _ session: ChatSession,
    ) throws -> TerminalRecoveryConsumer {
        if boundary.single {
            return try TerminalRecoveryConsumer(
                path == "gateway"
                    ? gateway.completeStreamEventsRecovering(model: "fixture", messages: [], config: .init())
                    : broker.generateRecoveryStreamEvents(model: "fixture", messages: [])
            )
        }
        if path == "gateway" {
            return TerminalRecoveryConsumer(
                gateway.streamRecovering(
                    model: "fixture", messages: [], tools: nil, config: .init(),
                )
            )
        }
        return TerminalRecoveryConsumer(
            path == "session"
                ? session.stream("payload-sentinel") : broker.stream(model: "fixture", messages: [])
        )
    }

    private func awaitReport(_ reports: RecoveryLocked<[CompletionRecoveryReport]>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reports.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!reports.withLock { $0.isEmpty })
    }
}
