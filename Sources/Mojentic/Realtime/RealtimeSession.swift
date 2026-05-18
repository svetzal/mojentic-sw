import Foundation
import Logging

/// Stateful realtime session.
///
/// Wraps a ``RealtimeTransport``, demultiplexes raw provider events into
/// the vendor-neutral ``RealtimeEvent`` stream, and drives parallel tool
/// execution per turn. Exposes both the neutral ``events()`` stream and a
/// ``rawEvents()`` escape hatch for events outside the neutral union.
public actor RealtimeSession {
    private let transport: any RealtimeTransport
    private let tracer: any Tracer
    private let toolRunner: any ToolRunner
    private let tools: [any LLMTool]
    private let vad: VADMode
    private let logger: Logger

    private var sessionId: String = ""
    private var currentTurnId: String?
    private var pendingCalls: [String: PendingCall] = [:]
    private var dispatchedCalls: Set<String> = []
    private var batchTask: Task<Void, Never>?
    private var closed = false

    private let neutralContinuation: AsyncThrowingStream<RealtimeEvent, any Error>.Continuation
    private let neutralStream: AsyncThrowingStream<RealtimeEvent, any Error>
    private let rawContinuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
    private let rawStream: AsyncThrowingStream<JSONValue, any Error>

    private struct PendingCall {
        let id: String
        let name: String
        var args: String
    }

    /// Construct a session.
    ///
    /// Typically called by ``RealtimeGateway`` implementations; consumers
    /// reach for ``RealtimeVoiceBroker`` to start a session.
    public init(
        transport: any RealtimeTransport,
        tools: [any LLMTool],
        tracer: any Tracer,
        toolRunner: any ToolRunner,
        vad: VADMode
    ) {
        self.transport = transport
        self.tools = tools
        self.tracer = tracer
        self.toolRunner = toolRunner
        self.vad = vad
        self.logger = Logger(label: "mojentic.realtime.session")
        let (neutralStream, neutralContinuation) =
            AsyncThrowingStream<RealtimeEvent, any Error>.makeStream()
        self.neutralStream = neutralStream
        self.neutralContinuation = neutralContinuation
        let (rawStream, rawContinuation) =
            AsyncThrowingStream<JSONValue, any Error>.makeStream()
        self.rawStream = rawStream
        self.rawContinuation = rawContinuation
    }

    /// Start the inbound-event pump.
    ///
    /// The gateway calls this immediately after constructing the session.
    public func start() {
        let transport = self.transport
        let weakSelf = WeakSession(session: self)
        Task {
            do {
                for try await frame in transport.receive() {
                    guard let session = weakSelf.session else { break }
                    if case .text(let text) = frame, let data = text.data(using: .utf8),
                        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
                    {
                        await session.absorb(rawEvent: value)
                    }
                }
                await weakSelf.session?.finalise(reason: .server)
            } catch {
                await weakSelf.session?.finaliseWithError(error)
            }
        }
    }

    // MARK: - Public API

    /// Vendor-neutral event stream.
    public nonisolated func events() -> AsyncThrowingStream<RealtimeEvent, any Error> {
        neutralStream
    }

    /// Raw provider events.
    ///
    /// Use as an escape hatch for events outside the neutral union.
    public nonisolated func rawEvents() -> AsyncThrowingStream<JSONValue, any Error> {
        rawStream
    }

    /// Append one audio frame to the input buffer.
    public func send(audio frame: AudioFrame) async throws {
        let payload = AudioCodec.base64Encode(frame)
        let event: JSONValue = [
            "type": "input_audio_buffer.append",
            "audio": .string(payload),
        ]
        try await sendJSON(event)
    }

    /// Send a text-mode turn (request + response.create).
    public func send(text: String) async throws {
        let userItem: JSONValue = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": .string(text)]
                ],
            ],
        ]
        try await sendJSON(userItem)
        try await sendJSON(["type": "response.create"])
    }

    /// Manual VAD: commit the input buffer and request a response.
    public func commit() async throws {
        try await sendJSON(["type": "input_audio_buffer.commit"])
        try await sendJSON(["type": "response.create"])
    }

    /// Barge-in: cancel any in-flight response and tool batch.
    public func interrupt() async throws {
        if let turnId = currentTurnId {
            neutralContinuation.yield(.interrupted(turnId: turnId, reason: .manual))
        }
        batchTask?.cancel()
        batchTask = nil
        currentTurnId = nil
        pendingCalls.removeAll()
        dispatchedCalls.removeAll()
        try await sendJSON(["type": "response.cancel"])
    }

    /// Send a `session.update` payload — useful immediately after open to
    /// configure instructions, modalities, tools, and turn-detection.
    public func update(session payload: JSONValue) async throws {
        try await sendJSON([
            "type": "session.update",
            "session": payload,
        ])
    }

    /// Gracefully close the session.
    public func close() async {
        guard !closed else { return }
        closed = true
        batchTask?.cancel()
        await transport.close()
        neutralContinuation.yield(.sessionClosed(reason: .client))
        neutralContinuation.finish()
        rawContinuation.finish()
    }

    // MARK: - Internal pump

    func absorb(rawEvent: JSONValue) {
        rawContinuation.yield(rawEvent)
        if let mapped = OpenAIRealtimeEventMapper.map(rawEvent) {
            handle(mapped: mapped, raw: rawEvent)
        }
    }

    func finalise(reason: SessionCloseReason) {
        guard !closed else { return }
        closed = true
        neutralContinuation.yield(.sessionClosed(reason: reason))
        neutralContinuation.finish()
        rawContinuation.finish()
    }

    func finaliseWithError(_ error: any Error) {
        guard !closed else { return }
        closed = true
        neutralContinuation.finish(throwing: error)
        rawContinuation.finish(throwing: error)
    }

    // MARK: - Helpers

    private func handle(mapped event: RealtimeEvent, raw: JSONValue) {
        switch event {
        case .sessionCreated(let id):
            sessionId = id
        case .responseStarted(let turnId):
            currentTurnId = turnId
            pendingCalls.removeAll()
            dispatchedCalls.removeAll()
        case .toolCallStarted(_, let callId, let name):
            pendingCalls[callId] = PendingCall(id: callId, name: name, args: "")
        case .toolCallArgsDelta(let callId, let delta):
            if var call = pendingCalls[callId] {
                call.args += delta
                pendingCalls[callId] = call
            }
        case .responseDone(let turnId, _):
            scheduleToolBatch(turnId: turnId)
        default:
            break
        }
        neutralContinuation.yield(event)
        _ = raw
    }

    private func scheduleToolBatch(turnId: String) {
        guard !pendingCalls.isEmpty else {
            currentTurnId = nil
            return
        }
        let calls = pendingCalls.values.map { call -> ToolCallExecution in
            let parsed: JSONValue
            if let data = call.args.data(using: .utf8),
                let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            {
                parsed = value
            } else {
                parsed = .object([:])
            }
            return ToolCallExecution(id: call.id, name: call.name, arguments: parsed)
        }
        pendingCalls.removeAll()
        let runner = self.toolRunner
        let tools = self.tools
        let tracer = self.tracer
        let neutralContinuation = self.neutralContinuation
        let context = TracerContext(correlationId: UUID(), parentId: nil)
        batchTask = Task { [weak self] in
            do {
                for call in calls {
                    neutralContinuation.yield(
                        .toolCallDispatched(
                            callId: call.id,
                            name: call.name,
                            arguments: call.arguments
                        )
                    )
                }
                let outcomes = try await runner.runBatch(
                    calls,
                    tools: tools,
                    tracer: tracer,
                    context: context
                )
                for outcome in outcomes {
                    switch outcome.kind {
                    case .success(let value):
                        neutralContinuation.yield(
                            .toolCallResult(
                                callId: outcome.id,
                                name: outcome.name,
                                result: value
                            )
                        )
                    case .failure(let message):
                        neutralContinuation.yield(
                            .toolCallFailed(
                                callId: outcome.id,
                                name: outcome.name,
                                message: message
                            )
                        )
                    }
                }
                guard let self else { return }
                await self.submitToolOutputs(outcomes, turnId: turnId)
            } catch is CancellationError {
                // Cancelled — interrupt() already yielded the .interrupted event.
            } catch {
                neutralContinuation.yield(.errorOccurred(String(describing: error)))
            }
        }
    }

    private func submitToolOutputs(_ outcomes: [ToolCallOutcome], turnId: String) async {
        var submitted: [String] = []
        for outcome in outcomes {
            let payload = serialise(outcome: outcome)
            let event: JSONValue = [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": .string(outcome.id),
                    "output": .string(payload),
                ],
            ]
            do {
                try await sendJSON(event)
                submitted.append(outcome.id)
            } catch {
                neutralContinuation.yield(.errorOccurred(String(describing: error)))
            }
        }
        if !submitted.isEmpty {
            neutralContinuation.yield(
                .toolBatchSubmitted(turnId: turnId, callIds: submitted)
            )
            do {
                try await sendJSON(["type": "response.create"])
            } catch {
                neutralContinuation.yield(.errorOccurred(String(describing: error)))
            }
        }
        currentTurnId = nil
    }

    private func sendJSON(_ value: JSONValue) async throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MojenticError.transport(message: "could not utf8-encode realtime payload")
        }
        try await transport.send(text: text)
    }

    private nonisolated func serialise(outcome: ToolCallOutcome) -> String {
        let value: JSONValue
        switch outcome.kind {
        case .success(let result):
            value = result
        case .failure(let message):
            value = ["error": .string(message)]
        }
        guard let data = try? JSONEncoder().encode(value),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}

/// Holds a weak reference to a session so background tasks don't keep it
/// alive past its caller's intent.
private final class WeakSession: @unchecked Sendable {
    weak var session: RealtimeSession?
    init(session: RealtimeSession) {
        self.session = session
    }
}
