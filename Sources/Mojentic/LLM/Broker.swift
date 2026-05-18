import Foundation
import Logging

/// Broker-level streaming event surfaced to library consumers.
public enum StreamEvent: Sendable {
    /// A delta of assistant text content.
    case textDelta(String)

    /// A delta of model reasoning trace.
    case thinkingDelta(String)

    /// The model has requested a tool call. The broker will dispatch it and
    /// follow up with `.toolCallResult`.
    case toolCallRequested(LLMToolCall)

    /// The result of a previously-requested tool call.
    case toolCallResult(callId: String, result: JSONValue)

    /// Final assistant response. Always the last event in a successful stream.
    case done(LLMResponse)
}

/// Coordinates LLM completions, recursive tool-call execution, and
/// (eventually) tracer + chat-session orchestration.
///
/// `LLMBroker` is an `actor` because it owns shared state across concurrent
/// invocations (the tool runner instance, the tracer write path). Each
/// `complete` / `completeJSON` / `stream` call is independent — the broker
/// does not retain conversation history; callers (typically `ChatSession`
/// in Phase 2) hold the message list.
public actor LLMBroker {
    private let gateway: any LLMGateway
    private let tracer: any Tracer
    private let toolRunner: any ToolRunner
    private let logger: Logger

    /// Create a broker around a gateway, with an optional tracer and tool runner.
    public init(
        gateway: any LLMGateway,
        tracer: any Tracer = NullTracer(),
        toolRunner: any ToolRunner = SerialToolRunner()
    ) {
        self.gateway = gateway
        self.tracer = tracer
        self.toolRunner = toolRunner
        self.logger = Logger(label: "mojentic.broker")
    }

    // MARK: - Non-streaming completion

    /// Run a chat completion, dispatching tool calls and recursing until the
    /// model produces a tool-call-free response or the iteration budget is
    /// exhausted.
    public func complete(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool] = [],
        config: CompletionConfig = CompletionConfig()
    ) async throws -> LLMResponse {
        try await completeRecursive(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            remaining: config.maxToolIterations
        )
    }

    private func completeRecursive(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool],
        config: CompletionConfig,
        remaining: Int
    ) async throws -> LLMResponse {
        guard remaining > 0 else {
            throw MojenticError.toolDepthExceeded(limit: config.maxToolIterations)
        }
        try Task.checkCancellation()
        await tracer.recordLLMCall(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools.map(\.descriptor.name)
        )
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await gateway.complete(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            config: config
        )
        let duration = start.duration(to: clock.now)
        await tracer.recordLLMResponse(model: model, response: response, duration: duration)

        if !response.toolCalls.isEmpty && !tools.isEmpty {
            let dispatched = try await dispatch(toolCalls: response.toolCalls, tools: tools)
            let nextMessages = appendToolExchange(
                to: messages,
                pairs: dispatched
            )
            return try await completeRecursive(
                model: model,
                messages: nextMessages,
                tools: tools,
                config: config,
                remaining: remaining - 1
            )
        }
        return LLMResponse(
            content: response.content,
            thinking: response.thinking,
            finishReason: response.finishReason,
            usage: response.usage
        )
    }

    // MARK: - Structured output

    /// Run a structured-output completion against the supplied type.
    ///
    /// The type's JSON Schema is derived via `JSONSchemaGenerator`; the
    /// gateway is responsible for funnelling the schema to the provider.
    public func completeJSON<T: Codable & Sendable>(
        model: String,
        messages: [LLMMessage],
        responseType: T.Type,
        config: CompletionConfig = CompletionConfig()
    ) async throws -> T {
        try Task.checkCancellation()
        let schema = try JSONSchemaGenerator.schema(for: responseType)
        await tracer.recordLLMCall(model: model, messages: messages, tools: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let raw = try await gateway.completeJSON(
            model: model,
            messages: messages,
            schema: schema,
            config: config
        )
        let duration = start.duration(to: clock.now)
        await tracer.recordLLMResponse(
            model: model,
            response: LLMGatewayResponse(content: ""),
            duration: duration
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(raw)
        } catch {
            throw MojenticError.structuredDecoding(
                typeName: String(describing: responseType),
                message: "Could not re-encode JSON for decoding: \(error.localizedDescription)"
            )
        }
        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw MojenticError.structuredDecoding(
                typeName: String(describing: responseType),
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Streaming

    /// Streaming variant of `complete`.
    ///
    /// Yields normalised broker events, dispatching tool calls and continuing
    /// the stream into the follow-up assistant turn until the model finishes
    /// without tool calls or the iteration budget is exhausted.
    public nonisolated func stream(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool] = [],
        config: CompletionConfig = CompletionConfig()
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamRecursive(
                        model: model,
                        messages: messages,
                        tools: tools,
                        config: config,
                        remaining: config.maxToolIterations,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MojenticError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamRecursive(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool],
        config: CompletionConfig,
        remaining: Int,
        continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async throws {
        guard remaining > 0 else {
            throw MojenticError.toolDepthExceeded(limit: config.maxToolIterations)
        }
        try Task.checkCancellation()
        await tracer.recordLLMCall(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools.map(\.descriptor.name)
        )
        var accumulatedContent = ""
        var accumulatedThinking = ""
        var accumulatedCalls: [LLMToolCall] = []
        var finishReason: FinishReason?
        var usage: Usage?

        let upstream = gateway.stream(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            config: config
        )
        for try await event in upstream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                accumulatedContent += delta
                continuation.yield(.textDelta(delta))
            case .thinkingDelta(let delta):
                accumulatedThinking += delta
                continuation.yield(.thinkingDelta(delta))
            case .toolCallRequest(let call):
                accumulatedCalls.append(call)
                continuation.yield(.toolCallRequested(call))
            case .done(let reason, let reportedUsage):
                finishReason = reason
                usage = reportedUsage
            }
        }

        if !accumulatedCalls.isEmpty && !tools.isEmpty {
            let dispatched = try await dispatch(toolCalls: accumulatedCalls, tools: tools)
            for (call, outcome) in dispatched {
                let result: JSONValue
                switch outcome.kind {
                case .success(let value):
                    result = value
                case .failure(let message):
                    result = ["error": .string(message)]
                }
                continuation.yield(.toolCallResult(callId: call.id ?? outcome.id, result: result))
            }
            let nextMessages = appendToolExchange(to: messages, pairs: dispatched)
            try await streamRecursive(
                model: model,
                messages: nextMessages,
                tools: tools,
                config: config,
                remaining: remaining - 1,
                continuation: continuation
            )
            return
        }

        let response = LLMResponse(
            content: accumulatedContent,
            thinking: accumulatedThinking.isEmpty ? nil : accumulatedThinking,
            finishReason: finishReason,
            usage: usage
        )
        continuation.yield(.done(response))
    }

    // MARK: - Tool dispatch

    private func dispatch(
        toolCalls: [LLMToolCall],
        tools: [any LLMTool]
    ) async throws -> [(LLMToolCall, ToolCallOutcome)] {
        var executions: [ToolCallExecution] = []
        var dispatched: [LLMToolCall] = []
        for (index, call) in toolCalls.enumerated() {
            guard tools.contains(where: { $0.matches(call.name) }) else {
                logger.warning(
                    "Tool not found",
                    metadata: ["name": .string(call.name)]
                )
                continue
            }
            let id = call.id ?? "call-\(index)"
            dispatched.append(call)
            executions.append(
                ToolCallExecution(id: id, name: call.name, arguments: call.arguments)
            )
        }
        guard !executions.isEmpty else { return [] }
        let outcomes = try await toolRunner.runBatch(executions, tools: tools)
        for outcome in outcomes {
            await tracer.recordToolResult(outcome: outcome, duration: .zero)
        }
        return Array(zip(dispatched, outcomes))
    }

    private func appendToolExchange(
        to messages: [LLMMessage],
        pairs: [(LLMToolCall, ToolCallOutcome)]
    ) -> [LLMMessage] {
        var next = messages
        for (call, outcome) in pairs {
            next.append(LLMMessage.assistant(toolCalls: [call]))
            let payload = serialise(outcome: outcome)
            next.append(LLMMessage.tool(callId: call.id ?? outcome.id, content: payload))
        }
        return next
    }

    private func serialise(outcome: ToolCallOutcome) -> String {
        let value: JSONValue
        switch outcome.kind {
        case .success(let result):
            value = result
        case .failure(let message):
            value = ["error": .string(message)]
        }
        do {
            let data = try JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "{}"
        }
    }
}
