import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Boundary for line-oriented streaming HTTP requests.
///
/// Gateways reach the network for streaming through this seam so tests can
/// substitute a scripted transport. ``HTTPClient`` is the production
/// conformance. Terminating the returned stream (the consumer stops
/// iterating or its task is cancelled) must cancel the underlying request.
protocol LineStreamingTransport: Sendable {
    /// POST `body` as JSON and stream the response line by line.
    func streamLines(
        url: URL,
        body: some Encodable,
        headers: [String: String],
    ) async throws -> AsyncThrowingStream<String, any Error>
}

/// One HTTP response header as received.
struct HTTPHeader: Sendable, Hashable {
    /// Header name as the server sent it.
    let name: String
    /// Header value as the server sent it.
    let value: String
}

/// A buffered request for ``RequestTransport``.
struct TransportRequest: Sendable {
    /// HTTP method, for example `GET` or `POST`.
    let method: String
    /// Absolute request URL.
    let url: URL
    /// JSON body; `nil` sends no body.
    var body: JSONValue?
    /// Request headers.
    var headers: [String: String] = [:]
    /// Idle timeout for this request; `nil` uses the transport's default.
    var timeout: TimeInterval?
}

/// A successful buffered response from ``RequestTransport``.
struct TransportResponse: Sendable {
    /// Response body bytes.
    let body: Data
    /// Response headers, in the order received.
    var headers: [HTTPHeader] = []

    /// Every value of the header `name`, compared case-insensitively.
    func values(for name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

/// Boundary for buffered HTTP requests whose response headers matter.
///
/// ``HTTPClient`` is the production conformance. A non-2xx status throws
/// ``MojenticError/http(status:body:)``.
protocol RequestTransport: Sendable {
    /// Send `request` and return the buffered response.
    func send(_ request: TransportRequest) async throws -> TransportResponse
}

/// Thin `URLSession` wrapper used by gateway implementations.
///
/// Boring on purpose: no retries, no connection pooling beyond what
/// `URLSession` already does, no logging. Surface a typed error and let the
/// caller decide what to do.
public struct HTTPClient: Sendable, LineStreamingTransport, RequestTransport {
    private let session: URLSession
    private let requestTimeout: TimeInterval?

    /// Create a client that issues requests through the supplied session.
    public init(session: URLSession = .shared) {
        self.init(session: session, requestTimeout: nil)
    }

    /// Create a client whose requests use `requestTimeout` as their idle
    /// timeout; `nil` keeps the `URLRequest` default.
    init(session: URLSession = .shared, requestTimeout: TimeInterval?) {
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// Preserve the caller's idle-timeout configuration on the isolated recovery session.
    var bufferedRequestTimeout: TimeInterval {
        requestTimeout ?? session.configuration.timeoutIntervalForRequest
    }

    /// Issue a JSON POST and return the decoded response body.
    public func postJSON<Response: Decodable>(
        url: URL,
        body: some Encodable,
        headers: [String: String] = [:],
        responseType: Response.Type,
    ) async throws -> Response {
        let data = try await postRaw(url: url, body: body, headers: headers)
        do { return try JSONDecoder().decode(responseType, from: data) } catch {
            throw MojenticError.decoding(
                message: "Failed to decode \(responseType): \(error.localizedDescription)"
            )
        }
    }

    /// Issue a JSON POST and return raw response bytes.
    public func postRaw(
        url: URL, body: some Encodable, headers: [String: String] = [:],
    ) async throws
        -> Data
    {
        var request = makeRequest(url: url, method: "POST", headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(body) } catch {
            throw MojenticError.transport(
                message: "Failed to encode request body: \(error.localizedDescription)"
            )
        }
        return try await execute(request: request)
    }

    /// Issue a GET and return decoded JSON.
    public func getJSON<Response: Decodable>(
        url: URL,
        headers: [String: String] = [:],
        responseType: Response.Type,
    ) async throws -> Response {
        let data = try await execute(request: makeRequest(url: url, method: "GET", headers: headers))
        do { return try JSONDecoder().decode(responseType, from: data) } catch {
            throw MojenticError.decoding(
                message: "Failed to decode \(responseType): \(error.localizedDescription)"
            )
        }
    }

    /// Stream lines from a JSON POST as an `AsyncThrowingStream<String, Error>`.
    ///
    /// Apple platforms get real progressive streaming via
    /// `URLSession.bytes(for:)`. Linux (swift-corelibs-foundation) lacks
    /// `URLSession.AsyncBytes`, so this falls back to buffering the full
    /// response and yielding lines from it. The line-iterating contract is
    /// identical; only the back-pressure characteristics differ.
    public func streamLines(
        url: URL,
        body: some Encodable,
        headers: [String: String] = [:],
    ) async throws -> AsyncThrowingStream<String, any Error> {
        var request = makeRequest(url: url, method: "POST", headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONEncoder().encode(body) } catch {
            throw MojenticError.transport(
                message: "Failed to encode streaming body: \(error.localizedDescription)"
            )
        }
        #if canImport(FoundationNetworking)
            let (data, response) = try await session.data(for: request)
            try assertSuccess(response: response, sampleBody: data)
            return Self.linesStream(from: data)
        #else
            let (bytes, response) = try await session.bytes(for: request)
            try assertSuccess(response: response, sampleBody: Data())
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        #endif
    }

    #if canImport(FoundationNetworking)
        /// Yield buffered bytes line by line.
        ///
        /// Used only on Linux where `URLSession.bytes(for:)` is unavailable.
        private static func linesStream(from data: Data) -> AsyncThrowingStream<String, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let text = String(bytes: data, encoding: .utf8) ?? ""
                    for line in text.split(
                        omittingEmptySubsequences: false,
                        whereSeparator: { $0.isNewline },
                    ) {
                        if Task.isCancelled {
                            break
                        }
                        continuation.yield(String(line))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    #endif

    /// Send a buffered request and return the body with the response headers.
    func send(_ request: TransportRequest) async throws -> TransportResponse {
        var urlRequest = makeRequest(url: request.url, method: request.method, headers: request.headers)
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        if let body = request.body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { urlRequest.httpBody = try JSONEncoder().encode(body) } catch {
                throw MojenticError.transport(
                    message: "Failed to encode request body: \(error.localizedDescription)"
                )
            }
        }
        let (data, response) = try await perform(request: urlRequest)
        let headers = response.allHeaderFields.compactMap { key, value -> HTTPHeader? in
            guard let name = key as? String, let value = value as? String else { return nil }
            return HTTPHeader(name: name, value: value)
        }
        return TransportResponse(body: data, headers: headers)
    }

    private func makeRequest(url: URL, method: String, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let requestTimeout {
            request.timeoutInterval = requestTimeout
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func execute(request: URLRequest) async throws -> Data {
        try await perform(request: request).0
    }

    private func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            let http = try assertSuccess(response: response, sampleBody: data)
            return (data, http)
        } catch let error as MojenticError { throw error } catch is CancellationError {
            throw MojenticError.cancelled
        } catch { throw MojenticError.transport(message: error.localizedDescription) }
    }

    @discardableResult
    private func assertSuccess(
        response: URLResponse,
        sampleBody: Data,
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw MojenticError.transport(message: "Non-HTTP response: \(type(of: response))")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: sampleBody, encoding: .utf8) ?? ""
            throw MojenticError.http(status: http.statusCode, body: body)
        }
        return http
    }
}
