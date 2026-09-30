import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Gateway for oMLX, an LLM server for Apple Silicon that speaks the OpenAI
/// chat completions protocol.
///
/// See [oMLX on GitHub](https://github.com/jundot/omlx). The gateway reuses the OpenAI message adapter and stream parsers, but not
/// the OpenAI model registry: every request carries the configured
/// parameters unchanged, whatever the model is called. It adds what
/// ``OpenAIGateway`` does not do for a local server:
///
/// - `reasoning_content` becomes ``LLMGatewayResponse/thinking`` and, when
///   streaming, ``GatewayStreamEvent/thinkingDelta(_:)``.
/// - Model load and unload (``loadModel(_:)``, ``unloadModel(_:)``).
/// - Embeddings with one request per text and no client-side chunking.
/// - oMLX's keep-alive stream frames are dropped before parsing.
///
/// ## Configuration
///
/// Each setting takes the explicit value, then the environment, then the
/// default:
///
/// | Setting | Environment | Default |
/// | ------- | ----------- | ------- |
/// | `host` | `OMLX_HOST` | `http://localhost:8000` |
/// | `apiKey` | `OMLX_API_KEY` | none: no `Authorization` header |
/// | `timeout` (seconds) | `OMLX_TIMEOUT` (milliseconds) | 600 seconds |
///
/// The host has no `/v1` suffix; the gateway adds it. One timeout covers
/// every request, including a model load.
///
/// ## Thinking and truncation
///
/// ``CompletionConfig/reasoning`` is sent as `reasoning_effort` and goes to
/// the model's chat template. Its effect depends on the model. `nil` leaves
/// the model's default, and Qwen 3 models think by default.
///
/// When `max_tokens` ends generation during thinking, a non-streaming
/// response carries the partial reasoning in `content`, with `nil` thinking
/// and finish reason ``FinishReason/length``. The gateway maps the fields as
/// they arrive. Content is not an answer when the finish reason is not
/// ``FinishReason/stop``.
///
/// ## Structured output
///
/// oMLX degrades `json_object` and `json_schema` to prompt instructions when
/// it cannot compile a grammar, and says so in a `Warning` response header.
/// When structured output was requested and that header is present, the
/// gateway records its value in ``LLMGatewayResponse/metadata`` under
/// `response_format_warning` and logs a warning. It does not retry or fail.
/// Validate the content yourself.
public struct OMLXGateway: LLMGateway, EmbeddingsGateway {
    private let configuration: OMLXConfiguration
    private let transport: any RequestTransport
    private let lineTransport: any LineStreamingTransport
    private let logger: Logger

    /// Metadata key for the `Warning` header of an unenforced response format.
    public static let responseFormatWarningKey = "response_format_warning"

    /// Create an oMLX gateway.
    ///
    /// - Parameters:
    ///   - host: server address without `/v1`; falls back to `OMLX_HOST`,
    ///     then `http://localhost:8000`.
    ///   - apiKey: bearer token; falls back to `OMLX_API_KEY`. With neither,
    ///     requests carry no `Authorization` header.
    ///   - timeout: idle timeout in seconds for every request; falls back to
    ///     `OMLX_TIMEOUT` (in milliseconds), then 600 seconds.
    ///   - session: the `URLSession` requests go through.
    public init(
        host: URL? = nil,
        apiKey: String? = nil,
        timeout: TimeInterval? = nil,
        session: URLSession = .shared
    ) {
        let configuration = OMLXConfiguration.resolve(
            host: host,
            apiKey: apiKey,
            timeout: timeout,
            environment: ProcessInfo.processInfo.environment
        )
        let client = HTTPClient(session: session, requestTimeout: configuration.timeout)
        self.init(configuration: configuration, transport: client, lineTransport: client)
    }

    /// Create an oMLX gateway over the supplied transports.
    init(
        configuration: OMLXConfiguration,
        transport: any RequestTransport,
        lineTransport: any LineStreamingTransport
    ) {
        self.configuration = configuration
        self.transport = transport
        self.lineTransport = OMLXKeepAliveFilter(base: lineTransport)
        self.logger = Logger(label: "mojentic.gateway.omlx")
    }

    // MARK: - LLMGateway

    /// Run a non-streaming chat completion via `/v1/chat/completions`.
    public func complete(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        let body = Self.chatBody(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            stream: false,
            responseFormat: config.responseFormat.map(OpenAIGateway.responseFormatPayload)
        )
        return try await chat(body: body, structured: config.responseFormat?.isStructured ?? false)
    }

    /// Run a structured-output completion with a `json_schema` response format.
    public func completeJSON(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> JSONValue {
        try await completeStructured(model: model, messages: messages, schema: schema, config: config).value
    }

    /// Run a structured-output completion with a `json_schema` response
    /// format, keeping the provider's usage, model, finish reason and metadata.
    ///
    /// Sends `{"type": "json_schema", "json_schema": {"name": "response",
    /// "schema": schema}}` and decodes the content as JSON. A `Warning`
    /// header lands in the response metadata; see ``OMLXGateway``.
    public func completeStructured(
        model: String,
        messages: [LLMMessage],
        schema: JSONValue,
        config: CompletionConfig
    ) async throws -> StructuredGatewayResponse {
        let body = Self.chatBody(
            model: model,
            messages: messages,
            tools: nil,
            config: config,
            stream: false,
            responseFormat: OpenAIGateway.responseFormatPayload(.jsonSchema(schema))
        )
        let response = try await chat(body: body, structured: true)
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(response.content.utf8))
            return StructuredGatewayResponse(value: value, response: response)
        } catch {
            throw MojenticError.decoding(
                message: "oMLX returned non-JSON content for structured output: \(response.content)"
            )
        }
    }

    /// List the models the server can serve (`GET /v1/models`), sorted.
    public func availableModels() async throws -> [String] {
        let response = try await send(TransportRequest(method: "GET", url: url("models")))
        return try Self.decode(OpenAIModelListResponse.self, from: response.body).data.map(\.id).sorted()
    }

    /// Stream a chat completion via SSE; emits normalised
    /// ``GatewayStreamEvent`` values.
    ///
    /// `reasoning_content` deltas arrive as
    /// ``GatewayStreamEvent/thinkingDelta(_:)``. Unlike the non-streaming
    /// response, a stream truncated during thinking keeps the partial
    /// reasoning there.
    public func stream(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        let body = Self.chatBody(
            model: model,
            messages: messages,
            tools: tools,
            config: config,
            stream: true,
            responseFormat: config.responseFormat.map(OpenAIGateway.responseFormatPayload)
        )
        return OpenAILegacyStreaming.events(
            transport: lineTransport,
            url: url("chat/completions"),
            body: body,
            headers: authHeaders(),
            parser: OpenAILegacyStreamParser(surfacesReasoning: true)
        )
    }

    /// Stream one turn with no tools via SSE and report completion evidence.
    ///
    /// Follows the OpenAI completion rules: success requires
    /// `finish_reason: "stop"` and the `data: [DONE]` marker. Requests
    /// `stream_options: {include_usage: true}`. Reasoning deltas produce no
    /// events.
    public func completeStreamEvents(
        model: String,
        messages: [LLMMessage],
        config: CompletionConfig
    ) -> AsyncStream<CompletionStreamEvent> {
        var body = Self.chatBody(
            model: model,
            messages: messages,
            tools: nil,
            config: config,
            stream: true,
            responseFormat: config.responseFormat.map(OpenAIGateway.responseFormatPayload)
        )
        if case .object(var fields) = body {
            fields["stream_options"] = ["include_usage": true]
            body = .object(fields)
        }
        return CompletionEventStreaming.events(
            transport: lineTransport,
            url: url("chat/completions"),
            body: body,
            headers: authHeaders(),
            parser: OpenAICompletionEventParser()
        )
    }

    // MARK: - Models

    /// Load `model` into memory (`POST /v1/models/{model}/load`).
    ///
    /// Blocks until the model is in memory. A chat request loads its model
    /// automatically, so this is for warming a model up ahead of time. oMLX
    /// downloads models only through its admin dashboard; there is no pull.
    ///
    /// - Throws: ``MojenticError/invalidArgument(message:)`` for an empty
    ///   model id, before any request; ``MojenticError/http(status:body:)``
    ///   when oMLX rejects the request.
    public func loadModel(_ model: String) async throws {
        _ = try await send(TransportRequest(method: "POST", url: try modelActionURL(model, action: "load")))
    }

    /// Unload `model` from memory (`POST /v1/models/{model}/unload`).
    ///
    /// - Throws: ``MojenticError/invalidArgument(message:)`` for an empty
    ///   model id, before any request; ``MojenticError/http(status:body:)``
    ///   when oMLX rejects the request, including a 400 when the model is
    ///   not loaded.
    public func unloadModel(_ model: String) async throws {
        _ = try await send(TransportRequest(method: "POST", url: try modelActionURL(model, action: "unload")))
    }

    // MARK: - EmbeddingsGateway

    /// Embed each text with its own `POST /v1/embeddings` request.
    ///
    /// oMLX has no standard embedding model, so `model` is required. The
    /// text is sent whole: there is no client-side chunking or tokenizer.
    ///
    /// - Throws: ``MojenticError/invalidArgument(message:)`` for an empty
    ///   model, before any request; ``MojenticError/http(status:body:)`` when
    ///   oMLX rejects the request, for example a 400 for a chat model.
    public func embed(texts: [String], model: String) async throws -> [[Float]] {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MojenticError.invalidArgument(
                message: "oMLX embeddings require a model; there is no default embedding model"
            )
        }
        var vectors: [[Float]] = []
        for text in texts {
            let request = TransportRequest(
                method: "POST",
                url: url("embeddings"),
                body: ["model": .string(model), "input": .string(text)]
            )
            let response = try await send(request)
            guard let first = try Self.decode(OMLXEmbeddingResponse.self, from: response.body).data.first
            else {
                throw MojenticError.decoding(message: "oMLX returned no embedding")
            }
            vectors.append(first.embedding)
        }
        return vectors
    }

    // MARK: - Helpers

    /// Build a chat completions body from the configuration, with no
    /// per-model adaptation.
    static func chatBody(
        model: String,
        messages: [LLMMessage],
        tools: [any LLMTool]?,
        config: CompletionConfig,
        stream: Bool,
        responseFormat: JSONValue?
    ) -> JSONValue {
        var dict: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(OpenAIMessageAdapter.adapt(messages)),
            "stream": .bool(stream),
            "temperature": .number(config.temperature),
            "max_tokens": .integer(config.maxTokens),
        ]
        if let topP = config.topP {
            dict["top_p"] = .number(topP)
        }
        if let effort = config.reasoning {
            dict["reasoning_effort"] = .string(effort.rawValue)
        }
        if let responseFormat {
            dict["response_format"] = responseFormat
        }
        if let tools, !tools.isEmpty {
            dict["tools"] = .array(tools.map { OpenAIMessageAdapter.tool($0.descriptor) })
        }
        for (key, value) in config.extraOptions {
            dict[key] = value
        }
        return .object(dict)
    }

    private func chat(body: JSONValue, structured: Bool) async throws -> LLMGatewayResponse {
        let response = try await send(
            TransportRequest(method: "POST", url: url("chat/completions"), body: body))
        let wire = try Self.decode(OpenAIChatResponse.self, from: response.body)
        let extras = try Self.decode(OMLXChatExtras.self, from: response.body)
        var metadata = wire.envelope.metadata ?? [:]
        if let usage = extras.usage {
            metadata["usage"] = usage
        }
        let warnings = response.values(for: "Warning")
        if structured, !warnings.isEmpty {
            let warning = warnings.joined(separator: ", ")
            metadata[Self.responseFormatWarningKey] = .string(warning)
            logger.warning("oMLX did not enforce the requested response format: \(warning)")
        }
        let base = wire.toGatewayResponse()
        return LLMGatewayResponse(
            content: base.content,
            toolCalls: base.toolCalls,
            thinking: extras.reasoningContent,
            finishReason: base.finishReason,
            usage: base.usage,
            providerFinishReason: base.providerFinishReason,
            providerModel: base.providerModel,
            metadata: metadata.isEmpty ? nil : metadata
        )
    }

    private func send(_ request: TransportRequest) async throws -> TransportResponse {
        var request = request
        request.headers = authHeaders()
        request.timeout = configuration.timeout
        return try await transport.send(request)
    }

    private func authHeaders() -> [String: String] {
        guard let apiKey = configuration.apiKey else { return [:] }
        return ["Authorization": "Bearer \(apiKey)"]
    }

    private func url(_ path: String) -> URL {
        configuration.baseURL.appendingPathComponent(path)
    }

    /// `/v1/models/{model}/{action}`, with the model id percent-encoded as
    /// one path segment.
    private func modelActionURL(_ model: String, action: String) throws -> URL {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let segment = model.addingPercentEncoding(withAllowedCharacters: Self.unreservedCharacters),
            let url = URL(string: "\(url("models").absoluteString)/\(segment)/\(action)")
        else {
            throw MojenticError.invalidArgument(message: "Invalid oMLX model id: '\(model)'")
        }
        return url
    }

    /// RFC 3986 unreserved characters: everything else in a model id is encoded.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MojenticError.decoding(message: "Failed to decode \(type): \(error.localizedDescription)")
        }
    }
}

// MARK: - Configuration

/// Resolved oMLX gateway settings: explicit value, then environment, then default.
struct OMLXConfiguration: Sendable, Equatable {
    /// `http://localhost:8000`.
    static let defaultHost: URL = {
        guard let url = URL(string: "http://localhost:8000") else {
            preconditionFailure("Built-in oMLX host must be valid")
        }
        return url
    }()

    /// Ten minutes, in seconds.
    static let defaultTimeout: TimeInterval = 600

    /// Server address without `/v1`.
    let host: URL
    /// Bearer token; `nil` sends no `Authorization` header.
    let apiKey: String?
    /// Idle timeout in seconds for every request.
    let timeout: TimeInterval

    /// The API root: the host plus `/v1`.
    var baseURL: URL { host.appendingPathComponent("v1") }

    init(host: URL = Self.defaultHost, apiKey: String? = nil, timeout: TimeInterval = Self.defaultTimeout) {
        self.host = host
        self.apiKey = apiKey
        self.timeout = timeout
    }

    /// Resolve each setting from its explicit value, then `environment`,
    /// then the default.
    ///
    /// Empty environment values count as unset. `OMLX_TIMEOUT` is in
    /// milliseconds; a value that is not a positive number falls back to
    /// the default, as does an `OMLX_HOST` that is not a URL.
    static func resolve(
        host: URL?,
        apiKey: String?,
        timeout: TimeInterval?,
        environment: [String: String]
    ) -> OMLXConfiguration {
        func value(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                return nil
            }
            return value
        }
        let environmentHost = value("OMLX_HOST").flatMap { URL(string: $0) }
        let environmentTimeout = value("OMLX_TIMEOUT")
            .flatMap(Double.init)
            .flatMap { $0 > 0 ? $0 / 1000 : nil }
        return OMLXConfiguration(
            host: host ?? environmentHost ?? defaultHost,
            apiKey: apiKey.map { $0.isEmpty ? nil : $0 } ?? value("OMLX_API_KEY"),
            timeout: timeout ?? environmentTimeout ?? defaultTimeout
        )
    }
}

// MARK: - Keep-alive frames

/// Drops oMLX keep-alive frames from a line stream before any parser sees them.
///
/// oMLX opens every chat stream with a `data:` frame whose `model` is
/// `keepalive`, and sends more during long prefill. Left in, it would report
/// `keepalive` as the provider model. The base transport already yields
/// whole lines, so each line is judged on its own.
struct OMLXKeepAliveFilter: LineStreamingTransport {
    /// The transport that performs the request.
    let base: any LineStreamingTransport

    func streamLines(
        url: URL,
        body: some Encodable,
        headers: [String: String]
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let lines = try await base.streamLines(url: url, body: body, headers: headers)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines where !Self.isKeepAlive(line) {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether `line` is a `data:` line whose JSON `model` is exactly `keepalive`.
    static func isKeepAlive(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:"), trimmed.contains("keepalive") else { return false }
        let payload = trimmed.dropFirst("data:".count)
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else {
            return false
        }
        return frame.objectValue?["model"] == .string("keepalive")
    }
}

// MARK: - Wire decoding

extension ResponseFormat {
    /// Whether this format asks for JSON output.
    fileprivate var isStructured: Bool {
        switch self {
        case .text: return false
        case .jsonObject, .jsonSchema: return true
        }
    }
}

/// The fields of an oMLX chat response that the OpenAI decoding drops.
private struct OMLXChatExtras: Decodable {
    /// `choices[0].message.reasoning_content`.
    let reasoningContent: String?
    /// `usage` exactly as reported, including oMLX's own fields.
    let usage: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case choices
        case usage
    }

    private struct Choice: Decodable {
        let message: Message?
    }

    private struct Message: Decodable {
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case reasoningContent = "reasoning_content"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let choices = try container.decodeIfPresent([Choice].self, forKey: .choices)
        reasoningContent = choices?.first?.message?.reasoningContent
        usage = try container.decodeIfPresent(JSONValue.self, forKey: .usage)
    }
}

private struct OMLXEmbeddingResponse: Decodable {
    let data: [Entry]

    struct Entry: Decodable {
        let embedding: [Float]
    }
}
