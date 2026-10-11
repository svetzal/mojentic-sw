import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct SenderRegistrationCancellationTests {
    private enum RetainedStream: Sendable {
        case gateway(AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error>)
        case relay(AsyncThrowingStream<StreamEvent, any Error>)
        case completion(AsyncStream<RecoveryCompletionStreamEvent>)
    }

    @Test(arguments: StreamingBoundary.all, ["gateway", "broker", "session"])
    func publicHTTPBeforeSenderRegistration(_ boundary: StreamingBoundary, _ path: String) async throws {
        if boundary.single, path == "session" {
            return
        }
        let body = try boundary.frame(
            content: "é", reasoning: boundary.single ? "" : "ré", tool: !boundary.single,
        )
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(
                headers: ["X-Request-ID": "original-header"], body: body, truncated: true, hold: true,
            )
        ])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let report = RecoveryLocked<CompletionRecoveryReport?>(nil)
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { value in report.withLock { $0 = value } }
        let gateway = boundary.gateway(server, policy)
        let broker = LLMBroker(gateway: gateway)
        let chat = ChatSession(broker: broker, model: "fixture")
        let sendCounts = RecoveryLocked<[String: Int]>([:])
        let finished = RecoveryLocked<[String]>([])
        let target = senderType(boundary: boundary, path: path)
        let targetNumber =
            (path == "session" && !boundary.openAI) || (boundary.single && path == "broker") ? 2 : 1
        let retained = RecoveryLocked<RetainedStream?>(nil)
        let arrived = AsyncStream<Void>.makeStream()
        let delivered = AsyncStream<Void>.makeStream()
        let registration = RecoveryConsumerPause()
        let consumer = RecoveryConsumerPause()
        defer {
            registration.resume()
            consumer.resume()
        }
        let onDelivery: @Sendable () -> Void = { delivered.continuation.yield(()) }
        let onFinish: @Sendable (String) -> Void = { type in finished.withLock { $0.append(type) } }
        let onRegistration: @Sendable (String) async -> Void = { type in
            let number = sendCounts.withLock { counts in
                counts[type, default: 0] += 1
                return counts[type]
            }
            if type == target, number == targetNumber {
                arrived.continuation.yield(())
                await registration.wait()
            }
        }
        let task = Task {
            try await RecoveryDeliveryScheduling.$didDeliver.withValue(onDelivery) {
                try await RecoveryDeliveryScheduling.$finished.withValue(onFinish) {
                    try await RecoveryDeliveryScheduling.$beforeSenderRegistration.withValue(onRegistration) {
                        try await withRecoveryStreamCancellation {
                            let stream = try makeStream(
                                boundary: boundary,
                                path: path,
                                gateway: gateway,
                                broker: broker,
                                chat: chat,
                            )
                            retained.withLock { $0 = stream }
                            await consumer.wait()
                        }
                    }
                }
            }
        }
        defer { task.cancel() }
        try #require(await waitForSignals(arrived.stream, count: 1))
        if path != "gateway" {
            try #require(
                await waitForSignals(delivered.stream, count: path == "session" && !boundary.openAI ? 2 : 1)
            )
        }
        // The sender passed its initial check and installed its handler, but has
        // no continuation yet. Neither stream iteration nor fixture release can
        // help cleanup: all three owners are held independently of cancellation.
        task.cancel()
        registration.resume()
        let expectedFinished = path == "gateway" ? 1 : path == "broker" ? 2 : 3
        try await awaitFinished(finished, count: expectedFinished)
        let cleaned = report.withLock { $0 }
        #expect(
            finished.withLock { $0.count } == expectedFinished,
            "All gateway and relay producers must finish while consumer remains paused",
        )
        #expect(cleaned != nil, "Producer must finish before the paused consumer resumes")
        #expect(server.waitForPeerClose(), "Locally owned HTTP must close with the fixture still held")
        assertAttempt(
            recorder: recorder,
            server: server,
            cleaned: cleaned,
            body: body,
            boundary: boundary,
            path: path,
        )
        // Drain only after recording rejecting evidence, so a broken baseline
        // does not leave a stranded continuation in the test process.
        let stream = try #require(retained.withLock { $0 })
        try await consumeTerminal(stream, path: path)
        consumer.resume()
        try await task.value
        if path == "session" {
            #expect(await chat.messages().isEmpty)
        }
    }

    private func senderType(boundary: StreamingBoundary, path: String) -> String {
        if boundary.single {
            return "Mojentic.RecoveryCompletionStreamEvent"
        }
        if path == "gateway" {
            return "Mojentic.RecoveryGatewayStreamEvent"
        }
        return "Mojentic.StreamEvent"
    }

    private func awaitFinished(_ finished: RecoveryLocked<[String]>, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while finished.withLock({ $0.count }) < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForSignals(_ stream: AsyncStream<Void>, count: Int) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                for _ in 0..<count {
                    guard await iterator.next() != nil else { return false }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let ready = await group.next() ?? false
            group.cancelAll()
            return ready
        }
    }

    private func makeStream(
        boundary: StreamingBoundary,
        path: String,
        gateway: any LLMGateway,
        broker: LLMBroker,
        chat: ChatSession,
    ) throws -> RetainedStream {
        if boundary.single {
            return try .completion(
                path == "gateway"
                    ? gateway.completeStreamEventsRecovering(model: "fixture", messages: [], config: .init())
                    : broker.generateRecoveryStreamEvents(model: "fixture", messages: [])
            )
        }
        if path != "gateway" {
            return .relay(
                path == "session" ? chat.stream("fixture") : broker.stream(model: "fixture", messages: [])
            )
        }
        return .gateway(gateway.streamRecovering(model: "fixture", messages: [], tools: nil, config: .init()))
    }

    private func assertAttempt(
        recorder: RecoveryRecorder,
        server: RecoveryLoopback,
        cleaned: CompletionRecoveryReport?,
        body: String,
        boundary: StreamingBoundary,
        path: String,
    ) {
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 1)
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        let fields = requests.first.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.1) }
        #expect(fields?.objectValue?["model"] == "fixture")
        #expect(fields?.objectValue?["stream"] == true)
        let bodies = recorder.wires.withLock { wires in
            wires.compactMap { event -> Data? in
                if case .body(let identity, let bytes) = event {
                    #expect(identity == requests.first?.0)
                    return bytes
                }
                return nil
            }
        }
        #expect(bodies.reduce(into: Data()) { $0.append($1) } == Data(body.utf8))
        #expect(cleaned?.identity == requests.first?.0)
        #expect(cleaned?.logicalID == requests.first?.0.logicalID)
        #expect(cleaned?.identity?.wireNumber == 1)
        #expect(cleaned?.history.count == 1)
        #expect(cleaned?.history.first?.identity == requests.first?.0)
        #expect(cleaned?.history.first?.status == 200)
        #expect(cleaned?.history.first?.category == .cancellation)
        let cause = cleaned?.history.first?.inspectEvidence().cause as? URLError
        #expect(cause?.code == .cancelled)
        #expect(cleaned?.history.first?.inspectEvidence().body == Data(body.utf8))
        #expect(
            cleaned?.history.first?.inspectEvidence().headers.contains {
                $0.key.lowercased() == "x-request-id" && $0.value == "original-header"
            } == true
        )
        #expect(cleaned?.progress.headersReceived == true)
        #expect(cleaned?.progress.rawBytes == body.utf8.count)
        #expect(cleaned?.progress.observed.contentBytes == 2)
        #expect(cleaned?.progress.observed.reasoningBytes == (boundary.single ? 0 : 3))
        #expect(cleaned?.progress.observed.toolFragments == (boundary.single ? 0 : 1))
        #expect(cleaned?.progress.observed.completedToolCalls == (boundary.single || boundary.omlx ? 0 : 1))
        #expect(cleaned?.progress.delivered.completedToolCalls == 0)
        var delivered = RecoverySemanticProgress()
        if path != "gateway" {
            if path == "session" {
                delivered.reasoningBytes = boundary.openAI ? 0 : 3
                delivered.contentBytes = 2
            } else if boundary.omlx, !boundary.single, !boundary.openAI {
                delivered.reasoningBytes = boundary.openAI ? 0 : 3
            } else {
                delivered.contentBytes = 2
            }
        }
        #expect(cleaned?.progress.delivered == delivered)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .cancelled,
            ]
        )
        #expect(recorder.events.withLock { $0.allSatisfy { $0.identity == requests.first?.0 } })
    }

    private func consumeTerminal(_ stream: RetainedStream, path: String) async throws {
        switch stream {
        case .gateway(let stream):
            do {
                for try await _ in stream {
                    Issue.record("Delivery after cancellation")
                }
                Issue.record("Expected terminal cancellation")
            } catch let error as RecoveryError {
                #expect(error.outcome == .cancelled)
                #expect(error.history.count == 1)
            }
        case .completion(let stream):
            var errors = 0
            for await event in stream {
                if case .recoveryFailure(let error) = event {
                    #expect(error.outcome == .cancelled)
                    #expect(error.history.count == 1)
                    errors += 1
                } else if case .error(.cancelled) = event, path == "broker" {
                    errors += 1
                } else {
                    Issue.record("Delivery after cancellation")
                }
            }
            #expect(errors == 1)
        case .relay(let stream):
            do {
                for try await _ in stream {
                    Issue.record("Relay delivery after cancellation")
                }
                Issue.record("Expected relay cancellation")
            } catch let error as RecoveryError {
                #expect(error.outcome == .cancelled)
                #expect(error.history.count == 1)
            } catch MojenticError.cancelled {}
        }
    }
}
