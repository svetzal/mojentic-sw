import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Web search tool that queries Serper.dev for organic results.
///
/// API key is injected at init (never read from the environment by library
/// code). Returns the top `maxResults` organic results as a JSON array.
///
/// Reference implementation — consumers can substitute their own search
/// gateway by conforming to ``LLMTool`` and returning the same shape.
public struct WebSearchTool: LLMTool {
    private let apiKey: String
    private let endpoint: URL
    private let client: HTTPClient
    private let maxResults: Int

    /// Default Serper.dev search endpoint.
    public static let defaultEndpoint: URL = {
        guard let url = URL(string: "https://google.serper.dev/search") else {
            preconditionFailure("Built-in Serper endpoint must be valid")
        }
        return url
    }()

    /// Create the tool with a Serper API key.
    public init(
        apiKey: String,
        endpoint: URL = WebSearchTool.defaultEndpoint,
        client: HTTPClient = HTTPClient(),
        maxResults: Int = 10
    ) {
        precondition(!apiKey.isEmpty, "WebSearch API key must not be empty")
        precondition(maxResults > 0, "maxResults must be positive")
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.client = client
        self.maxResults = maxResults
    }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "web_search",
            description: "Search the web for results matching the query.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let query = arguments.objectValue?["query"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "web_search requires 'query'")
        }
        let body = SerperRequest(q: query)
        let response = try await client.postJSON(
            url: endpoint,
            body: body,
            headers: [
                "X-API-KEY": apiKey
            ],
            responseType: SerperResponse.self
        )
        let trimmed = Array(response.organic.prefix(maxResults))
        let encoded = trimmed.map { result -> JSONValue in
            var dict: [String: JSONValue] = [
                "title": .string(result.title),
                "link": .string(result.link),
            ]
            if let snippet = result.snippet {
                dict["snippet"] = .string(snippet)
            }
            return .object(dict)
        }
        return .array(encoded)
    }
}

private struct SerperRequest: Encodable {
    let q: String
}

private struct SerperResponse: Decodable {
    let organic: [SerperResult]
}

private struct SerperResult: Decodable {
    let title: String
    let link: String
    let snippet: String?
}
