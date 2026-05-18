import Foundation
import Testing

@testable import Mojentic

/// Test-only transport that records outbound traffic and exposes a hook
/// for tests to push inbound JSON events.
/// Tiny actor-isolated boolean for tests crossing concurrency boundaries.
private actor SeenFlag {
    var value = false
    func mark() { value = true }
}

private actor FakeTransportState {
    var outbound: [String] = []
    var continuation: AsyncThrowingStream<TransportFrame, any Error>.Continuation?
    var pending: [JSONValue] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    var closed = false

    func send(_ text: String) {
        outbound.append(text)
    }

    func setContinuation(_ continuation: AsyncThrowingStream<TransportFrame, any Error>.Continuation) {
        self.continuation = continuation
        for event in pending {
            yield(event)
        }
        pending.removeAll()
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func push(_ json: JSONValue) {
        if continuation != nil {
            yield(json)
        } else {
            pending.append(json)
        }
    }

    func waitForContinuation() async {
        if continuation != nil { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            waiters.append(waiter)
        }
    }

    private func yield(_ json: JSONValue) {
        guard let data = try? JSONEncoder().encode(json),
            let text = String(data: data, encoding: .utf8)
        else { return }
        continuation?.yield(.text(text))
    }

    func close() {
        closed = true
        continuation?.finish()
    }

    func sentEvents() -> [String] { outbound }
}

private struct FakeTransport: RealtimeTransport {
    let state: FakeTransportState

    func send(text: String) async throws {
        await state.send(text)
    }

    func send(data _: Data) async throws {}

    func receive() -> AsyncThrowingStream<TransportFrame, any Error> {
        // Build the stream synchronously and hand the continuation to the
        // state actor in a fire-and-forget task. Tests that need the
        // continuation to be live before pushing should `await
        // state.waitForContinuation()` first.
        let state = self.state
        return AsyncThrowingStream { continuation in
            Task { await state.setContinuation(continuation) }
        }
    }

    func close() async {
        await state.close()
    }
}

private struct SleepyTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "slow_tool",
        description: "sleep",
        parameters: ["type": "object"]
    )

    func execute(arguments _: JSONValue) async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(200))
        return ["slept": true]
    }
}

@Suite("RealtimeSession")
struct RealtimeSessionTests {
    @Test("manual commit() sends both commit and response.create frames")
    func manualCommit() async throws {
        let state = FakeTransportState()
        let session = RealtimeSession(
            transport: FakeTransport(state: state),
            tools: [],
            tracer: NullTracer(),
            toolRunner: SerialToolRunner(),
            vad: .manual
        )
        await session.start()
        try await session.commit()
        // Give the pump task a tick to drain.
        try await Task.sleep(for: .milliseconds(50))
        let outbound = await state.sentEvents()
        #expect(outbound.contains { $0.contains("\"input_audio_buffer.commit\"") })
        #expect(outbound.contains { $0.contains("\"response.create\"") })
        await session.close()
    }

    @Test("interrupt() emits interrupted event and cancels in-flight tool batch")
    func interruptCancelsBatch() async throws {
        let state = FakeTransportState()
        let session = RealtimeSession(
            transport: FakeTransport(state: state),
            tools: [SleepyTool()],
            tracer: NullTracer(),
            toolRunner: SerialToolRunner(),
            vad: .server
        )
        await session.start()
        await state.waitForContinuation()

        // Subscribe to events BEFORE we push anything, so the AsyncStream
        // doesn't drop events that arrive before the iterator exists.
        let flag = SeenFlag()
        let stream = session.events()
        let consumer = Task { @Sendable in
            var iterator = stream.makeAsyncIterator()
            for _ in 0..<40 {
                guard let event = try await iterator.next() else { break }
                if case .interrupted = event {
                    await flag.mark()
                    return
                }
            }
        }

        // Push a synthetic turn that requests slow_tool and completes.
        await state.push([
            "type": "response.created",
            "response": ["id": "turn_1"],
        ])
        await state.push([
            "type": "response.output_item.added",
            "response_id": "turn_1",
            "item": [
                "type": "function_call",
                "call_id": "call_1",
                "name": "slow_tool",
            ],
        ])
        await state.push([
            "type": "response.function_call_arguments.delta",
            "call_id": "call_1",
            "delta": "{}",
        ])
        await state.push([
            "type": "response.done",
            "response": ["id": "turn_1"],
        ])

        // Give the session a tick to start the tool batch, then interrupt.
        try await Task.sleep(for: .milliseconds(50))
        try await session.interrupt()
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        #expect(await flag.value)
        await session.close()
    }

    @Test("send(audio:) emits an input_audio_buffer.append payload")
    func sendAudio() async throws {
        let state = FakeTransportState()
        let session = RealtimeSession(
            transport: FakeTransport(state: state),
            tools: [],
            tracer: NullTracer(),
            toolRunner: SerialToolRunner(),
            vad: .server
        )
        await session.start()
        try await session.send(audio: AudioFrame(samples: [1, 2, 3]))
        try await Task.sleep(for: .milliseconds(50))
        let outbound = await state.sentEvents()
        #expect(outbound.contains { $0.contains("\"input_audio_buffer.append\"") })
        await session.close()
    }
}
