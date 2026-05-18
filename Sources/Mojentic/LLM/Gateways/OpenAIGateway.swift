import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Gateway for the OpenAI Chat Completions API.
///
/// Targets the `/v1/chat/completions` endpoint. Per-model request shaping
/// (token parameter name, temperature handling, reasoning effort routing,
/// `response_format` shape) is driven by ``OpenAIModelRegistry``. The
/// Responses API is intentionally out of scope for Phase 2 — see
/// `SWIFT.md` for the long-term plan; consumers needing it today should
/// reach for raw `URLSession`.
///
/// > Note: the gateway never reads `OPENAI_API_KEY` from the environment.
/// > Callers must thread the key through their app configuration.
public struct OpenAIGateway: LLMGateway {
    private let baseURL: URL
    private let apiKey: String
    private let client: HTTPClient
    private let registry: OpenAIModelRegistry
    private let logger: Logger

    /// Default OpenAI v1 base URL (`https://api.openai.com/v1`).
    public static let defaultBaseURL: URL = {
        guard let url = URL(string: "https://api.openai.com/v1") else {
            preconditionFailure("Built-in OpenAI base URL must be valid")
        }
        return url
    }()

    /// Create an OpenAI gateway.
    public init(
        apiKey: String,
        baseURL: URL = OpenAIGateway.defaultBaseURL,
        client: HTTPClient = HTTPClient(),
        registry: OpenAIModelRegistry = .shared
    ) {
        precondition(!apiKey.isEmpty, "OpenAI API key must not be empty")
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.client = client
        self.registry = registry
        self.logger = Logger(label: "mojentic.gateway.openai")
    }

    // MARK: - LLMGateway

    /// Run a non-streaming chat completion via `/v1/chat/completions`.
    public func complete(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        let body = buildRequest(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            stream: false,
            responseFormat: nil
        )
        let url = baseURL.appendingPathComponent("chat/completions")
        let response = try await client.postJSON(
            url: url,
            body: body,
            headers: authHeaders(),
            responseType: OpenAIChatResponse.self
        )
        return response.toGatewayResponse()
    }

    /// Run a structured-output completion using `response_format`.
    public func completeJSON(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> JSONValue {
        let capabilities = registry.capabilities(for: model)
        let responseFormat: JSONValue
        if capabilities.supportsJSONSchema {
            responseFormat = [
                "type": "json_schema",
                "json_schema": [
                    "name": "Response",
                    "schema": schema,
                    "strict": true,
                ],
            ]
        } else {
            responseFormat = ["type": "json_object"]
        }
        let body = buildRequest(
            model: model,
            messages: messages,
            tools: nil,
            config: config,
            stream: false,
            responseFormat: responseFormat
        )
        let url = baseURL.appendingPathComponent("chat/completions")
        let response = try await client.postJSON(
            url: url,
            body: body,
            headers: authHeaders(),
            responseType: OpenAIChatResponse.self
        )
        let content = response.firstChoiceContent ?? ""
        guard let data = content.data(using: .utf8) else {
            throw MojenticError.decoding(message: "Empty JSON content from OpenAI")
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw MojenticError.decoding(
                message: "OpenAI returned non-JSON content for structured output: \(content)"
            )
        }
    }

    /// List models available on the OpenAI account (`/v1/models`).
    public func availableModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("models")
        let response = try await client.getJSON(
            url: url,
            headers: authHeaders(),
            responseType: OpenAIModelListResponse.self
        )
        return response.data.map(\.id).sorted()
    }

    /// Stream a chat completion via SSE; emits normalised
    /// ``GatewayStreamEvent`` values.
    public func stream(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        let body = buildRequest(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            stream: true,
            responseFormat: nil
        )
        let url = baseURL.appendingPathComponent("chat/completions")
        let client = self.client
        let headers = authHeaders()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await client.streamLines(
                        url: url,
                        body: body,
                        headers: headers
                    )
                    var accumulator = OpenAIToolCallAccumulator()
                    var finishReason: FinishReason?
                    var usage: Usage?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        // OpenAI emits SSE `data: ...` lines plus heartbeats.
                        guard let payload = Self.payload(from: line) else { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        let chunk: OpenAIStreamChunk
                        do {
                            chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                        } catch {
                            continue
                        }
                        if let reportedUsage = chunk.usage?.toUsage() {
                            usage = reportedUsage
                        }
                        guard let choice = chunk.choices.first else { continue }
                        if let delta = choice.delta.content, !delta.isEmpty {
                            continuation.yield(.textDelta(delta))
                        }
                        if let toolDeltas = choice.delta.toolCalls {
                            accumulator.absorb(toolDeltas)
                        }
                        if let reason = choice.finishReason {
                            finishReason = FinishReason(rawValue: reason) ?? .other
                        }
                    }
                    for call in accumulator.flushed() {
                        continuation.yield(.toolCallRequest(call))
                    }
                    continuation.yield(.done(finishReason: finishReason, usage: usage))
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

    // MARK: - Helpers

    private func authHeaders() -> [String: String] {
        ["Authorization": "Bearer \(apiKey)"]
    }

    private func buildRequest(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig,
        stream: Bool,
        responseFormat: JSONValue?
    ) -> JSONValue {
        let capabilities = registry.capabilities(for: model)
        var dict: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(OpenAIMessageAdapter.adapt(messages)),
            "stream": .bool(stream),
        ]
        if capabilities.supportsTemperatureControl {
            dict["temperature"] = .number(config.temperature)
        }
        if let topP = config.topP {
            dict["top_p"] = .number(topP)
        }
        if config.maxTokens > 0 {
            dict[capabilities.tokenLimitParameter] = .integer(config.maxTokens)
        }
        if capabilities.supportsReasoningEffort, let effort = config.reasoning {
            dict["reasoning_effort"] = .string(effort.rawValue)
        }
        if let format = responseFormat {
            dict["response_format"] = format
        }
        if let tools, !tools.isEmpty, capabilities.supportsTools {
            dict["tools"] = .array(tools.map(toolDescriptor(for:)))
        }
        for (key, value) in config.extraOptions {
            dict[key] = value
        }
        return .object(dict)
    }

    private func toolDescriptor(for tool: any LLMTool) -> JSONValue {
        [
            "type": "function",
            "function": [
                "name": .string(tool.descriptor.name),
                "description": .string(tool.descriptor.description),
                "parameters": tool.descriptor.parameters,
            ],
        ]
    }

    private static func payload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        return String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Wire decoding

private struct OpenAIChatResponse: Decodable {
    let choices: [Choice]
    let usage: OpenAIUsage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String?
        let toolCalls: [OpenAIToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    var firstChoiceContent: String? {
        choices.first?.message.content
    }

    func toGatewayResponse() -> LLMGatewayResponse {
        let choice = choices.first
        let calls = (choice?.message.toolCalls ?? []).compactMap { raw -> LLMToolCall? in
            let arguments = OpenAIToolCall.decodeArguments(raw.function.arguments)
            return LLMToolCall(id: raw.id, name: raw.function.name, arguments: arguments)
        }
        let finishReason = choice?.finishReason.flatMap { FinishReason(rawValue: $0) ?? .other }
        return LLMGatewayResponse(
            content: choice?.message.content ?? "",
            toolCalls: calls,
            thinking: nil,
            finishReason: finishReason,
            usage: usage?.toUsage()
        )
    }
}

private struct OpenAIToolCall: Decodable {
    let id: String?
    let function: Function

    struct Function: Decodable {
        let name: String
        let arguments: String
    }

    static func decodeArguments(_ raw: String) -> JSONValue {
        guard let data = raw.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .object([:])
        }
        return value
    }
}

private struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    func toUsage() -> Usage {
        Usage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens
        )
    }
}

private struct OpenAIModelListResponse: Decodable {
    let data: [Entry]

    struct Entry: Decodable {
        let id: String
    }
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [StreamChoice]
    let usage: OpenAIUsage?
}

private struct StreamChoice: Decodable {
    let delta: StreamDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct StreamDelta: Decodable {
    let content: String?
    let toolCalls: [StreamToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }
}

private struct StreamToolCallDelta: Decodable {
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
private struct OpenAIToolCallAccumulator {
    private var entries: [Int: Builder] = [:]

    private struct Builder {
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
