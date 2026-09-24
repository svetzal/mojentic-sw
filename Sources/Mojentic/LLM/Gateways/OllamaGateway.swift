import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Gateway for the Ollama local LLM server.
///
/// Speaks Ollama's `/api/chat` and `/api/tags` endpoints over HTTP. JSON
/// schema for structured output is forwarded as the `format` field; tools
/// are forwarded as OpenAI-shaped function descriptors; `think: true`
/// enables reasoning traces when `CompletionConfig.reasoning` is set.
public struct OllamaGateway: LLMGateway {
    private let baseURL: URL
    private let client: HTTPClient
    private let lineTransport: any LineStreamingTransport
    private let headers: [String: String]
    private let logger: Logger

    /// Default Ollama endpoint (`http://localhost:11434`).
    public static let defaultBaseURL: URL = {
        // The compile-time literal is known to be a valid URL; we use a
        // precondition rather than force-unwrap to satisfy lint while still
        // surfacing programmer error loudly if it ever changes.
        guard let url = URL(string: "http://localhost:11434") else {
            preconditionFailure("Built-in Ollama base URL must be valid")
        }
        return url
    }()

    /// Create an Ollama gateway pointed at `baseURL`.
    public init(
        baseURL: URL = OllamaGateway.defaultBaseURL,
        client: HTTPClient = HTTPClient(),
        headers: [String: String] = [:]
    ) {
        self.init(baseURL: baseURL, client: client, headers: headers, lineTransport: client)
    }

    /// Create an Ollama gateway whose streaming requests go through `lineTransport`.
    init(
        baseURL: URL = OllamaGateway.defaultBaseURL,
        client: HTTPClient = HTTPClient(),
        headers: [String: String] = [:],
        lineTransport: any LineStreamingTransport
    ) {
        self.baseURL = baseURL
        self.client = client
        self.lineTransport = lineTransport
        self.headers = headers
        self.logger = Logger(label: "mojentic.gateway.ollama")
    }

    // MARK: - LLMGateway

    /// Run a non-streaming chat completion via `/api/chat`.
    public func complete(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        let body = buildChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            stream: false,
            format: Self.formatPayload(config.responseFormat)
        )
        logger.debug("Ollama complete", metadata: ["model": .string(model)])
        let url = baseURL.appendingPathComponent("api/chat")
        let response = try await client.postJSON(
            url: url,
            body: body,
            headers: headers,
            responseType: OllamaChatResponse.self
        )
        return response.toGatewayResponse()
    }

    /// Run a structured-output completion by forwarding `schema` as `format`.
    public func completeJSON(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> JSONValue {
        try await completeStructured(
            model: model,
            messages: messages,
            schema: schema,
            config: config
        ).value
    }

    /// Run a structured-output completion by forwarding `schema` as `format`,
    /// keeping the provider's usage, model, finish reason and metadata.
    public func completeStructured(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> StructuredGatewayResponse {
        let body = buildChatRequest(
            model: model,
            messages: messages,
            tools: nil,
            config: config,
            stream: false,
            format: schema
        )
        let url = baseURL.appendingPathComponent("api/chat")
        let wire = try await client.postJSON(
            url: url,
            body: body,
            headers: headers,
            responseType: OllamaChatResponse.self
        )
        let response = wire.toGatewayResponse()
        let content = response.content
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
            return StructuredGatewayResponse(value: value, response: response)
        } catch {
            throw MojenticError.decoding(
                message: "Ollama returned non-JSON content for structured output: \(content)"
            )
        }
    }

    /// List models available on the Ollama server (`/api/tags`).
    public func availableModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let response = try await client.getJSON(
            url: url,
            headers: headers,
            responseType: OllamaTagsResponse.self
        )
        return response.models.map(\.name).sorted()
    }

    /// Streams a chat completion as normalised gateway stream events parsed from NDJSON.
    public func stream(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        let body = buildChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            stream: true,
            format: Self.formatPayload(config.responseFormat)
        )
        let url = baseURL.appendingPathComponent("api/chat")
        let transport = lineTransport
        let headers = self.headers

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lines = try await transport.streamLines(
                        url: url,
                        body: body,
                        headers: headers
                    )
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8) else { continue }
                        let chunk: OllamaStreamChunk
                        do {
                            chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)
                        } catch {
                            continue
                        }
                        for event in chunk.toEvents() {
                            continuation.yield(event)
                        }
                        if chunk.done == true {
                            continuation.yield(
                                .done(
                                    finishReason: chunk.toFinishReason(),
                                    usage: chunk.evidence.usage
                                )
                            )
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MojenticError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request building

    /// Map a configured ``ResponseFormat`` onto Ollama's `format` field.
    ///
    /// Plain text is Ollama's default, so it omits the field.
    static func formatPayload(_ format: ResponseFormat?) -> JSONValue? {
        switch format {
        case nil, .text:
            return nil
        case .jsonObject:
            return "json"
        case .jsonSchema(let schema):
            return schema
        }
    }

    private func buildChatRequest(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig,
        stream: Bool,
        format: JSONValue?
    ) -> OllamaChatRequest {
        var options = OllamaOptions(
            temperature: config.temperature,
            numCtx: config.numCtx,
            topP: config.topP,
            numPredict: config.maxTokens > 0 ? config.maxTokens : nil
        )
        // Forward unknown extras verbatim via the rawOptions catch-all.
        options.rawOptions = config.extraOptions.isEmpty ? nil : config.extraOptions
        return OllamaChatRequest(
            model: model,
            messages: messages.map(OllamaMessage.init(from:)),
            options: options,
            stream: stream,
            think: config.reasoning != nil ? true : nil,
            format: format,
            tools: tools?.map(OllamaToolDescriptor.init(tool:))
        )
    }
}

// MARK: - Wire format

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let options: OllamaOptions
    let stream: Bool
    let think: Bool?
    let format: JSONValue?
    let tools: [OllamaToolDescriptor]?
}

private struct OllamaOptions: Encodable {
    let temperature: Double
    let numCtx: Int?
    let topP: Double?
    let numPredict: Int?
    var rawOptions: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case temperature
        case numCtx = "num_ctx"
        case topP = "top_p"
        case numPredict = "num_predict"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(temperature, forKey: DynamicKey(stringValue: "temperature"))
        if let numCtx {
            try container.encode(numCtx, forKey: DynamicKey(stringValue: "num_ctx"))
        }
        if let topP {
            try container.encode(topP, forKey: DynamicKey(stringValue: "top_p"))
        }
        if let numPredict {
            try container.encode(numPredict, forKey: DynamicKey(stringValue: "num_predict"))
        }
        if let extras = rawOptions {
            for (key, value) in extras {
                try container.encode(value, forKey: DynamicKey(stringValue: key))
            }
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct OllamaMessage: Encodable {
    let role: String
    let content: String
    let toolCalls: [OllamaToolCallEnvelope]?
    let images: [String]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case images
    }

    init(from message: LLMMessage) {
        switch message.role {
        case .system:
            self.role = "system"
            self.content = message.content ?? ""
            self.toolCalls = nil
            self.images = nil
        case .user:
            self.role = "user"
            self.content = message.content ?? ""
            self.toolCalls = nil
            self.images = OllamaMessage.encodeImages(message.images)
        case .assistant:
            self.role = "assistant"
            self.content = message.content ?? ""
            self.toolCalls = message.toolCalls.map { calls in
                calls.map(OllamaToolCallEnvelope.init(call:))
            }
            self.images = nil
        case .tool:
            self.role = "tool"
            self.content = message.content ?? ""
            self.toolCalls = nil
            self.images = nil
        }
    }

    private static func encodeImages(_ images: [ImageContent]?) -> [String]? {
        guard let images, !images.isEmpty else { return nil }
        var encoded: [String] = []
        for image in images {
            switch image.source {
            case .data(let base64, _):
                encoded.append(base64)
            case .url:
                // Ollama only accepts inline base64; remote URL images are
                // not supported by the chat endpoint, so we skip them and
                // expect the caller to download/encode first.
                continue
            }
        }
        return encoded.isEmpty ? nil : encoded
    }
}

private struct OllamaToolCallEnvelope: Encodable {
    let type: String
    let function: OllamaToolFunctionCall

    init(call: LLMToolCall) {
        self.type = "function"
        self.function = OllamaToolFunctionCall(name: call.name, arguments: call.arguments)
    }
}

private struct OllamaToolFunctionCall: Encodable {
    let name: String
    let arguments: JSONValue
}

private struct OllamaToolDescriptor: Encodable {
    let type: String
    let function: OllamaToolFunction

    init(tool: any LLMTool) {
        self.type = "function"
        self.function = OllamaToolFunction(
            name: tool.descriptor.name,
            description: tool.descriptor.description,
            parameters: tool.descriptor.parameters
        )
    }
}

private struct OllamaToolFunction: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

/// Provider evidence Ollama reports on a response or final stream frame.
struct OllamaResponseEvidence: Decodable {
    let model: String?
    let createdAt: String?
    let promptEvalCount: Int?
    let evalCount: Int?
    let totalDuration: Int?
    let loadDuration: Int?
    let promptEvalDuration: Int?
    let evalDuration: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalDuration = "prompt_eval_duration"
        case evalDuration = "eval_duration"
    }

    /// Reported token counts; `nil` when Ollama reported neither.
    var usage: Usage? {
        guard promptEvalCount != nil || evalCount != nil else { return nil }
        return Usage(
            promptTokens: promptEvalCount,
            completionTokens: evalCount,
            totalTokens: (promptEvalCount ?? 0) + (evalCount ?? 0)
        )
    }

    /// Reported timestamps and durations; `nil` when none were reported.
    var metadata: [String: JSONValue]? {
        var fields: [String: JSONValue] = [:]
        if let createdAt { fields["created_at"] = .string(createdAt) }
        if let totalDuration { fields["total_duration"] = .integer(totalDuration) }
        if let loadDuration { fields["load_duration"] = .integer(loadDuration) }
        if let promptEvalDuration { fields["prompt_eval_duration"] = .integer(promptEvalDuration) }
        if let evalDuration { fields["eval_duration"] = .integer(evalDuration) }
        return fields.isEmpty ? nil : fields
    }
}

struct OllamaChatResponse: Decodable {
    let message: OllamaResponseMessage
    let done: Bool?
    let doneReason: String?
    let evidence: OllamaResponseEvidence

    enum CodingKeys: String, CodingKey {
        case message
        case done
        case doneReason = "done_reason"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(OllamaResponseMessage.self, forKey: .message)
        done = try container.decodeIfPresent(Bool.self, forKey: .done)
        doneReason = try container.decodeIfPresent(String.self, forKey: .doneReason)
        evidence = try OllamaResponseEvidence(from: decoder)
    }

    func toGatewayResponse() -> LLMGatewayResponse {
        let calls = (message.toolCalls ?? []).map { envelope -> LLMToolCall in
            LLMToolCall(
                id: envelope.id,
                name: envelope.function.name,
                arguments: envelope.function.arguments ?? .object([:])
            )
        }
        return LLMGatewayResponse(
            content: message.content ?? "",
            toolCalls: calls,
            thinking: message.thinking,
            finishReason: mapFinishReason(doneReason, hasToolCalls: !calls.isEmpty),
            usage: evidence.usage,
            providerModel: evidence.model,
            metadata: evidence.metadata
        )
    }
}

struct OllamaResponseMessage: Decodable {
    let role: String?
    let content: String?
    let thinking: String?
    let toolCalls: [OllamaResponseToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case thinking
        case toolCalls = "tool_calls"
    }
}

struct OllamaResponseToolCall: Decodable {
    let id: String?
    let function: OllamaResponseToolFunction
}

struct OllamaResponseToolFunction: Decodable {
    let name: String
    let arguments: JSONValue?
}

private struct OllamaStreamChunk: Decodable {
    let message: OllamaResponseMessage?
    let done: Bool?
    let doneReason: String?
    let evidence: OllamaResponseEvidence

    enum CodingKeys: String, CodingKey {
        case message
        case done
        case doneReason = "done_reason"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(OllamaResponseMessage.self, forKey: .message)
        done = try container.decodeIfPresent(Bool.self, forKey: .done)
        doneReason = try container.decodeIfPresent(String.self, forKey: .doneReason)
        evidence = try OllamaResponseEvidence(from: decoder)
    }

    func toEvents() -> [GatewayStreamEvent] {
        guard let message else { return [] }
        var events: [GatewayStreamEvent] = []
        if let content = message.content, !content.isEmpty {
            events.append(.textDelta(content))
        }
        if let thinking = message.thinking, !thinking.isEmpty {
            events.append(.thinkingDelta(thinking))
        }
        if let calls = message.toolCalls {
            for (index, call) in calls.enumerated() {
                events.append(
                    .toolCallRequest(
                        LLMToolCall(
                            id: call.id ?? "call-\(index)",
                            name: call.function.name,
                            arguments: call.function.arguments ?? .object([:])
                        )
                    )
                )
            }
        }
        return events
    }

    func toFinishReason() -> FinishReason? {
        mapFinishReason(doneReason, hasToolCalls: message?.toolCalls?.isEmpty == false)
    }
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaTagEntry]
}

private struct OllamaTagEntry: Decodable {
    let name: String
}

private func mapFinishReason(_ raw: String?, hasToolCalls: Bool) -> FinishReason? {
    if hasToolCalls { return .toolCalls }
    switch raw {
    case "stop", nil:
        return raw == nil ? nil : .stop
    case "length":
        return .length
    default:
        return .other
    }
}
