import Foundation

/// Compute embedding vectors for one or more texts via a provider's
/// embeddings API.
///
/// Embeddings are independent of the chat broker — consumers wire up an
/// embeddings gateway directly and use it for retrieval, semantic search, or
/// clustering. Phase 2 ships two implementations:
/// ``OllamaEmbeddingsGateway`` (`/api/embed`) and ``OpenAIEmbeddingsGateway``
/// (`/v1/embeddings`).
public protocol EmbeddingsGateway: Sendable {
    /// Embed `texts` against `model`.
    ///
    /// Returns one vector per input, in input order.
    func embed(texts: [String], model: String) async throws -> [[Float]]
}

extension EmbeddingsGateway {
    /// Convenience overload for embedding a single text.
    public func embed(text: String, model: String) async throws -> [Float] {
        let vectors = try await embed(texts: [text], model: model)
        guard let first = vectors.first else {
            throw MojenticError.decoding(message: "Embeddings gateway returned no vectors")
        }
        return first
    }
}

/// Embeddings gateway against a local Ollama server's `/api/embed` endpoint.
public struct OllamaEmbeddingsGateway: EmbeddingsGateway {
    private let baseURL: URL
    private let client: HTTPClient
    private let headers: [String: String]

    /// Create a gateway pointed at `baseURL` (defaults to Ollama's standard
    /// `http://localhost:11434`).
    public init(
        baseURL: URL = OllamaGateway.defaultBaseURL,
        client: HTTPClient = HTTPClient(),
        headers: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.client = client
        self.headers = headers
    }

    /// Embed `texts` against an Ollama embedding model.
    public func embed(texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let url = baseURL.appendingPathComponent("api/embed")
        let body = OllamaEmbedRequest(model: model, input: texts)
        let response = try await client.postJSON(
            url: url,
            body: body,
            headers: headers,
            responseType: OllamaEmbedResponse.self
        )
        return response.embeddings
    }
}

private struct OllamaEmbedRequest: Encodable {
    let model: String
    let input: [String]
}

private struct OllamaEmbedResponse: Decodable {
    let embeddings: [[Float]]
}

/// Embeddings gateway against the OpenAI `/v1/embeddings` endpoint.
public struct OpenAIEmbeddingsGateway: EmbeddingsGateway {
    private let baseURL: URL
    private let apiKey: String
    private let client: HTTPClient

    /// Create a gateway with an explicit API key.
    ///
    /// The gateway never reads environment variables — pass the key in from
    /// your app's configuration boundary.
    public init(
        apiKey: String,
        baseURL: URL = OpenAIGateway.defaultBaseURL,
        client: HTTPClient = HTTPClient()
    ) {
        precondition(!apiKey.isEmpty, "OpenAI API key must not be empty")
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.client = client
    }

    /// Embed `texts` against an OpenAI embedding model.
    public func embed(texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let url = baseURL.appendingPathComponent("embeddings")
        let body = OpenAIEmbedRequest(model: model, input: texts)
        let response = try await client.postJSON(
            url: url,
            body: body,
            headers: [
                "Authorization": "Bearer \(apiKey)"
            ],
            responseType: OpenAIEmbedResponse.self
        )
        // OpenAI returns entries unordered in theory; sort by `index` to be
        // sure we hand them back in input order.
        let ordered = response.data.sorted { $0.index < $1.index }
        return ordered.map(\.embedding)
    }
}

private struct OpenAIEmbedRequest: Encodable {
    let model: String
    let input: [String]
}

private struct OpenAIEmbedResponse: Decodable {
    let data: [Entry]

    struct Entry: Decodable {
        let index: Int
        let embedding: [Float]
    }
}
