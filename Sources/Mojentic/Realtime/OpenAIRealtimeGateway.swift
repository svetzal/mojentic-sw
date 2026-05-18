import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// OpenAI Realtime API gateway.
///
/// Opens a WebSocket to `wss://api.openai.com/v1/realtime` with the
/// `OpenAI-Beta: realtime=v1` header, wraps it in a
/// ``URLSessionWebSocketTransport``, hands the transport to a
/// ``RealtimeSession``, and pushes the initial `session.update` payload so
/// the model knows about tools, instructions, and the VAD policy.
public struct OpenAIRealtimeGateway: RealtimeGateway {
    /// Default endpoint base.
    public static let defaultBaseURL: URL = {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime") else {
            preconditionFailure("Built-in OpenAI realtime URL must be valid")
        }
        return url
    }()

    private let baseURL: URL
    private let session: URLSession

    /// Create the gateway.
    public init(baseURL: URL = OpenAIRealtimeGateway.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Open a session against OpenAI Realtime.
    public func openSession(
        _ config: RealtimeSessionConfig,
        tracer: any Tracer,
        toolRunner: any ToolRunner
    ) async throws -> RealtimeSession {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MojenticError.invalidArgument(message: "Realtime base URL is malformed")
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "model", value: config.model))
        components.queryItems = query
        guard let url = components.url else {
            throw MojenticError.invalidArgument(message: "could not assemble realtime URL")
        }
        let transport = URLSessionWebSocketTransport(
            url: url,
            headers: [
                "Authorization": "Bearer \(config.apiKey)",
                "OpenAI-Beta": "realtime=v1",
            ],
            session: session
        )
        let realtimeSession = RealtimeSession(
            transport: transport,
            tools: config.tools,
            tracer: tracer,
            toolRunner: toolRunner,
            vad: config.vad
        )
        await realtimeSession.start()
        try await realtimeSession.update(session: buildSessionUpdate(config: config))
        return realtimeSession
    }

    private func buildSessionUpdate(config: RealtimeSessionConfig) -> JSONValue {
        var session: [String: JSONValue] = [
            "modalities": ["text", "audio"],
            "turn_detection": vadPayload(for: config.vad),
        ]
        if let instructions = config.instructions {
            session["instructions"] = .string(instructions)
        }
        if !config.tools.isEmpty {
            session["tools"] = .array(config.tools.map(toolPayload(for:)))
        }
        return .object(session)
    }

    private func vadPayload(for mode: VADMode) -> JSONValue {
        switch mode {
        case .server:
            return ["type": "server_vad"]
        case .manual:
            return .null
        }
    }

    private func toolPayload(for tool: any LLMTool) -> JSONValue {
        [
            "type": "function",
            "name": .string(tool.descriptor.name),
            "description": .string(tool.descriptor.description),
            "parameters": tool.descriptor.parameters,
        ]
    }
}
