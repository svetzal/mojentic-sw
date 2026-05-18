import Foundation
import Testing

@testable import Mojentic

private actor RecordingGatewayState {
    var observed: (any Tracer)?
    var observedRunner: (any ToolRunner)?

    func capture(tracer: any Tracer, runner: any ToolRunner) {
        observed = tracer
        observedRunner = runner
    }
}

private struct RecordingGateway: RealtimeGateway {
    let state: RecordingGatewayState

    func openSession(
        _ config: RealtimeSessionConfig,
        tracer: any Tracer,
        toolRunner: any ToolRunner
    ) async throws -> RealtimeSession {
        await state.capture(tracer: tracer, runner: toolRunner)
        // Return a no-op session against a closed fake transport.
        let dummyState = DummyTransportState()
        return RealtimeSession(
            transport: DummyTransport(state: dummyState),
            tools: config.tools,
            tracer: tracer,
            toolRunner: toolRunner,
            vad: config.vad
        )
    }
}

private actor DummyTransportState {
    var continuation: AsyncThrowingStream<TransportFrame, any Error>.Continuation?
    func setContinuation(
        _ continuation: AsyncThrowingStream<TransportFrame, any Error>.Continuation
    ) {
        self.continuation = continuation
    }
    func close() { continuation?.finish() }
}

private struct DummyTransport: RealtimeTransport {
    let state: DummyTransportState
    func send(text _: String) async throws {}
    func send(data _: Data) async throws {}
    func receive() -> AsyncThrowingStream<TransportFrame, any Error> {
        let state = self.state
        return AsyncThrowingStream { continuation in
            Task { await state.setContinuation(continuation) }
        }
    }
    func close() async { await state.close() }
}

@Suite("RealtimeVoiceBroker")
struct RealtimeVoiceBrokerTests {
    @Test("broker hands its tracer and (parallel-by-default) runner to the gateway")
    func defaultsArePassedThrough() async throws {
        let state = RecordingGatewayState()
        let store = EventStore()
        let tracer = EventStoreTracer(store: store)
        let broker = RealtimeVoiceBroker(
            gateway: RecordingGateway(state: state),
            tracer: tracer
        )
        _ = try await broker.startSession(
            RealtimeSessionConfig(model: "m", apiKey: "k")
        )
        let observedTracer = await state.observed
        let observedRunner = await state.observedRunner
        #expect(observedTracer is EventStoreTracer)
        #expect(observedRunner is ParallelToolRunner)
    }

    @Test("a custom tool runner overrides the parallel default")
    func customRunner() async throws {
        let state = RecordingGatewayState()
        let broker = RealtimeVoiceBroker(
            gateway: RecordingGateway(state: state),
            toolRunner: SerialToolRunner()
        )
        _ = try await broker.startSession(
            RealtimeSessionConfig(model: "m", apiKey: "k")
        )
        let observedRunner = await state.observedRunner
        #expect(observedRunner is SerialToolRunner)
    }
}
