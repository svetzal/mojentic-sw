import Foundation
@testable import Mojentic
import Testing

struct ScopedRecoveryRelayTests {
    @Test(arguments: [false, true], [false, true])
    func retainedRelayPreservesCancellationError(_ omlx: Bool, _ session: Bool) async throws {
        let boundary = StreamingBoundary(omlx: omlx, single: false)
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: "\n", truncated: true, hold: true)])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let cleaned = RecoveryLocked<CompletionRecoveryReport?>(nil)
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { report in cleaned.withLock { $0 = report } }
        let wireReady = AsyncStream<Void>.makeStream()
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if case .body = event {
                wireReady.continuation.yield(())
            }
        }
        let broker = LLMBroker(gateway: boundary.gateway(server, policy))
        let chat = ChatSession(broker: broker, model: "fixture")
        let pause = RecoveryConsumerPause()
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            await withRecoveryStreamCancellation {
                let stream = session ? chat.stream("fixture") : broker.stream(model: "fixture", messages: [])
                var arrivals = wireReady.stream.makeAsyncIterator()
                _ = await arrivals.next()
                ready.continuation.yield(())
                await pause.wait()
                return stream
            }
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        task.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while cleaned.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cleaned.withLock { $0 } != nil)
        #expect(server.waitForPeerClose())
        pause.resume()
        let retained = await task.value
        do {
            for try await _ in retained {
                Issue.record("Unexpected delivery after cancellation")
            }
            Issue.record("Expected cancellation error")
        } catch let failure as RecoveryError {
            #expect(failure.outcome == .cancelled)
            #expect(failure.history.count == 1)
        } catch MojenticError.cancelled {
            // Relay cancellation retains the existing public error case.
        }
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted, .attemptFailed, .cancelled,
            ]
        )
        if session {
            #expect(await chat.messages().isEmpty)
        }
    }
}
