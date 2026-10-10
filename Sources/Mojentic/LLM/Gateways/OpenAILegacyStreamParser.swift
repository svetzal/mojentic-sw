import Foundation

/// Translates OpenAI-compatible chat-completion SSE lines into legacy
/// ``GatewayStreamEvent`` values.
///
/// A pure state machine: text deltas pass through as they arrive, tool-call
/// fragments accumulate until ``finish()``, and malformed frames are skipped.
/// The `data: [DONE]` marker sets ``isDone``.
struct OpenAILegacyStreamParser {
    private let surfacesReasoning: Bool
    private var accumulator = OpenAIToolCallAccumulator()
    private var finishReason: FinishReason?
    private var usage: Usage?

    /// Whether the `data: [DONE]` marker has arrived.
    private(set) var isDone = false

    /// Create a parser.
    ///
    /// - Parameter surfacesReasoning: when `true`, `delta.reasoning_content`
    ///   becomes ``GatewayStreamEvent/thinkingDelta(_:)``. OpenAI leaves it
    ///   off; OpenAI-compatible servers that stream reasoning turn it on.
    init(surfacesReasoning: Bool = false) {
        self.surfacesReasoning = surfacesReasoning
    }

    /// Consume one line of the response and return the events it produces.
    mutating func consume(line: String) -> [GatewayStreamEvent] {
        // OpenAI emits SSE `data: ...` lines plus heartbeats.
        guard !isDone, let payload = Self.payload(from: line) else { return [] }
        if payload == "[DONE]" {
            isDone = true
            return []
        }
        guard let data = payload.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
        else {
            return []
        }
        if let reportedUsage = chunk.usage?.toUsage() {
            usage = reportedUsage
        }
        guard let choice = chunk.choices.first else { return [] }
        var events: [GatewayStreamEvent] = []
        if surfacesReasoning, let reasoning = choice.delta.reasoningContent, !reasoning.isEmpty {
            events.append(.thinkingDelta(reasoning))
        }
        if let delta = choice.delta.content, !delta.isEmpty {
            events.append(.textDelta(delta))
        }
        if let toolDeltas = choice.delta.toolCalls {
            accumulator.absorb(toolDeltas)
        }
        if let reason = choice.finishReason {
            finishReason = FinishReason(rawValue: reason) ?? .other
        }
        return events
    }

    /// The events that close the stream: assembled tool calls, then `done`.
    func finish() -> [GatewayStreamEvent] {
        accumulator.flushed().map(GatewayStreamEvent.toolCallRequest)
            + [.done(finishReason: finishReason, usage: usage)]
    }

    private static func payload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        return String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Runs one legacy streaming request through an ``OpenAILegacyStreamParser``.
enum OpenAILegacyStreaming {
    /// Issue one streaming request and translate its lines into gateway events.
    ///
    /// Terminating the returned stream cancels the request.
    static func events(
        transport: any LineStreamingTransport,
        url: URL,
        body: JSONValue,
        headers: [String: String],
        parser initial: OpenAILegacyStreamParser
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lines = try await transport.streamLines(url: url, body: body, headers: headers)
                    var parser = initial
                    for try await line in lines {
                        try Task.checkCancellation()
                        for event in parser.consume(line: line) {
                            continuation.yield(event)
                        }
                        if parser.isDone { break }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
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
}

// MARK: - Wire decoding

struct OpenAIStreamChunk: Decodable {
    let choices: [StreamChoice]
    let usage: OpenAIUsage?
}

struct StreamChoice: Decodable {
    let delta: StreamDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

struct StreamDelta: Decodable {
    let content: String?
    let reasoningContent: String?
    let toolCalls: [StreamToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }
}

struct StreamToolCallDelta: Decodable {
    let index: Int
    let id: String?
    let function: FunctionDelta?

    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }
}

/// Accumulates per-chunk tool-call deltas from OpenAI's streaming format
/// into complete ``LLMToolCall`` values.
struct OpenAIToolCallAccumulator {
    private var entries: [Int: Builder] = [:]

    struct Builder {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    mutating func absorb(_ deltas: [StreamToolCallDelta]) {
        for delta in deltas {
            var builder = entries[delta.index] ?? Builder()
            if let id = delta.id { builder.id = id }
            if let name = delta.function?.name { builder.name = name }
            if let chunk = delta.function?.arguments { builder.arguments += chunk }
            entries[delta.index] = builder
        }
    }

    func flushed() -> [LLMToolCall] {
        entries.keys.sorted().compactMap { index -> LLMToolCall? in
            guard let builder = entries[index], let name = builder.name else { return nil }
            let arguments = OpenAIToolCall.decodeArguments(
                builder.arguments.isEmpty ? "{}" : builder.arguments
            )
            return LLMToolCall(id: builder.id, name: name, arguments: arguments)
        }
    }
}
