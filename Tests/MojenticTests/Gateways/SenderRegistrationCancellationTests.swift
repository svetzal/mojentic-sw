import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite(.serialized)
struct SenderRegistrationCancellationTests {
    enum RetainedStream: Sendable {
        case gateway(AsyncThrowingStream<RecoveryGatewayStreamEvent, any Error>)
        case relay(AsyncThrowingStream<StreamEvent, any Error>)
        case completion(AsyncStream<RecoveryCompletionStreamEvent>)
    }

    /// Bounds waits for signals that must arrive; a successful wait ends early.
    ///
    /// The whole parallel suite shares the cooperative pool, so a tight
    /// deadline turns scheduling delay into a false failure. A missing signal
    /// still fails the test, only later.

    @Test(arguments: StreamingBoundary.withAnthropic, ["gateway", "broker", "session"])
    func publicHTTPBeforeSenderRegistration(_ boundary: StreamingBoundary, _ path: String) async throws {
        let frame = try registrationFrame(boundary)
        try await probe(boundary, path: path, innerFirst: false, releaseSuffix: false, frame: frame)
        try await probe(boundary, path: path, innerFirst: false, releaseSuffix: true, frame: frame)
    }

    @Test(arguments: ["broker", "session"])
    func publicHTTPRegistrationOwnership(_ path: String) async throws {
        try await probe(
            StreamingBoundary(omlx: false, single: path == "broker"), path: path, innerFirst: true)
    }

    private func probe(
        _ boundary: StreamingBoundary,
        path: String,
        innerFirst: Bool,
        releaseSuffix: Bool? = nil,
        frame: String? = nil
    ) async throws {
        if boundary.single, path == "session" {
            return
        }
        let body = try frame ?? registrationFrame(boundary)
        let prefixCount = try #require(Data(body.utf8).firstIndex(of: 10))
        let server = try framingServer(body: body, prefixCount: prefixCount, releaseSuffix: releaseSuffix)
        defer { server.release() }
        let mode = releaseSuffix.map { $0 ? "framed" : "incomplete" } ?? "ownership"
        server.trace.record("call", "sender/\(boundary)/\(path)/\(mode)")
        server.trace.record("fixture.body.scripted", bytes: Data(body.utf8))
        let recorder = RecoveryRecorder()
        let report = RecoveryLocked<CompletionRecoveryReport?>(nil)
        let prefixArrived = AsyncStream<Void>.makeStream()
        let policy = registrationPolicy(
            recorder: recorder,
            report: report,
            prefixArrived: prefixArrived.continuation,
            prefixCount: prefixCount,
            splitFrame: releaseSuffix != nil,
        )
        let gateway = boundary.gateway(server, policy)
        let broker = LLMBroker(gateway: gateway)
        let chat = ChatSession(broker: broker, model: "fixture")
        let schedule = SenderRegistrationSchedule(
            trace: server.trace,
            path: path,
            target: senderType(boundary: boundary, path: path),
            innerFirst: innerFirst,
        )
        let registration = schedule.registration
        let retained = RecoveryLocked<RetainedStream?>(nil)
        let consumer = RecoveryConsumerPause()
        defer {
            registration.resume()
            consumer.resume()
            schedule.innerReady.resume()
        }
        let task = pausedStream(schedule: schedule, consumer: consumer, retained: retained) {
            try makeStream(boundary: boundary, path: path, gateway: gateway, broker: broker, chat: chat)
        }
        defer { cancel(task, trace: server.trace) }
        if let releaseSuffix {
            try #require(await waitForSignals(prefixArrived.stream, count: 1))
            server.trace.record("framing.prefix.received", bytes: Data(body.utf8).prefix(prefixCount))
            #expect(schedule.heldRole.withLock { $0 } == nil)
            guard releaseSuffix else {
                server.release()
                try await beforeFraming(
                    boundary,
                    path: path,
                    server: server,
                    recorder: recorder,
                    schedule: schedule,
                    report: report,
                    body: Data(body.utf8).prefix(prefixCount))
                try await finishTransport(
                    task: task,
                    schedule: schedule,
                    consumer: consumer,
                    retained: retained,
                    server: server,
                    path: path,
                    boundary: boundary)
                if path == "session" { #expect(await chat.messages().isEmpty) }
                return
            }
            server.releaseSuffix()
        }
        try await awaitRegistration(
            schedule: schedule,
            path: path,
            innerFirst: innerFirst,
            trace: server.trace,
            boundary: boundary)
        try await finishCancellation(
            task: task,
            schedule: schedule,
            consumer: consumer,
            retained: retained,
            server: server,
            path: path
        ) {
            let cleaned = report.withLock { $0 }
            let completedHTTP = schedule.completed.withLock { $0 }
            #expect(completedHTTP.first?.0 == recorder.requests.withLock { $0.first?.0 })
            #expect(completedHTTP.first?.1 == Data(body.utf8))
            #expect(cleaned != nil, "Producer must finish before the paused consumer resumes")
            assertAttempt(
                recorder: recorder,
                server: server,
                cleaned: cleaned,
                body: body,
                boundary: boundary,
                path: path)
        }
        if path == "session" {
            #expect(await chat.messages().isEmpty)
        }
    }

    private func registrationFrame(_ boundary: StreamingBoundary) throws -> String {
        try boundary.frame(content: "é", reasoning: boundary.single ? "" : "ré", tool: !boundary.single)
    }

    private func framingServer(
        body: String, prefixCount: Int, releaseSuffix: Bool?
    ) throws -> InProcessHTTPFixture {
        try InProcessHTTPFixture(replies: [
            RecoveryReply(
                headers: ["X-Request-ID": "original-header"],
                body: body,
                truncated: true,
                hold: true,
                splitAt: releaseSuffix == nil ? nil : prefixCount,
                holdSuffix: releaseSuffix != nil,
            )
        ])
    }

    private func pausedStream(
        schedule: SenderRegistrationSchedule,
        consumer: RecoveryConsumerPause,
        retained: RecoveryLocked<RetainedStream?>,
        create: @escaping @Sendable () throws -> RetainedStream,
    ) -> Task<Void, any Error> {
        Task {
            try await schedule.run {
                try await withRecoveryStreamCancellation {
                    let stream = try create()
                    retained.withLock { $0 = stream }
                    await consumer.wait()
                }
            }
        }
    }

    private func awaitRegistration(
        schedule: SenderRegistrationSchedule,
        path: String,
        innerFirst: Bool,
        trace: RecoveryCallTrace,
        boundary: StreamingBoundary,
    ) async throws {
        let ready = await waitForSignals(schedule.arrived.stream, count: 1)
        trace.record("registration.readiness", ready ? "ready" : "expired")
        try #require(ready)
        if path != "gateway" {
            try #require(
                await waitForSignals(
                    schedule.delivered.stream, count: path == "session" && !boundary.openAI ? 2 : 1)
            )
        }
        if innerFirst {
            #expect(
                schedule.heldRole.withLock { $0 } == path,
                "The named public relay must own the held registration")
        }
    }

    private func registrationPolicy(
        recorder: RecoveryRecorder,
        report: RecoveryLocked<CompletionRecoveryReport?>,
        prefixArrived: AsyncStream<Void>.Continuation,
        prefixCount: Int,
        splitFrame: Bool,
    ) -> CompletionRecoveryPolicy {
        var policy = recoveryPolicy(recorder)
        if splitFrame { policy.maximumAttempts = 1 }
        let bytesReceived = RecoveryLocked<Int>(0)
        let observe = policy.wireObserver
        policy.wireObserver = { event in
            try observe?(event)
            if case .body(_, let bytes) = event {
                let count = bytesReceived.withLock {
                    $0 += bytes.count
                    return $0
                }
                if count == prefixCount { prefixArrived.yield(()) }
            }
        }
        policy.reportObserver = { value in report.withLock { $0 = value } }
        return policy
    }

    private func finishCancellation(
        task: Task<Void, any Error>,
        schedule: SenderRegistrationSchedule,
        consumer: RecoveryConsumerPause,
        retained: RecoveryLocked<RetainedStream?>,
        server: InProcessHTTPFixture,
        path: String,
        verify: () -> Void
    ) async throws {
        // The sender installed its cancellation handler but has no continuation.
        // Registration, consumer and fixture are independently held.
        server.trace.record("caller.cancel")
        task.cancel()
        schedule.registration.resume()
        let count = path == "gateway" ? 1 : path == "broker" ? 2 : 3
        try await awaitFinished(schedule.finished, count: count)
        try await awaitFinished(schedule.producersCompleted, count: count)
        #expect(
            schedule.finished.withLock { $0.count } == count,
            "All gateway and relay producers must finish while consumer remains paused")
        #expect(schedule.producersCompleted.withLock { $0.count } == count)
        #expect(
            schedule.completed.withLock { $0.count } == 1,
            "HTTP delegate completion must precede consumer resumption")
        let peerClosed = server.waitForPeerClose()
        #expect(peerClosed, "Locally owned HTTP must close with the fixture still held")
        server.trace.record("boundary.peer.closed", "\(peerClosed)")
        verify()
        // Drain only after asserting cleanup, so rejection cannot strand a sender.
        try await consumeTerminal(try #require(retained.withLock { $0 }), path: path)
        server.trace.record("consumer.resume")
        consumer.resume()
        try await task.value
    }

    private func cancel(_ task: Task<Void, any Error>, trace: RecoveryCallTrace) {
        trace.record("caller.exit.cancel")
        task.cancel()
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

    func awaitFinished(_ finished: RecoveryLocked<[String]>, count: Int) async throws {
        await finished.wait { $0.count >= count }
    }

    private func waitForSignals(_ stream: AsyncStream<Void>, count: Int) async -> Bool {
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<count {
            guard await iterator.next() != nil else { return false }
        }
        return true
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
