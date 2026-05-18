import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Thin `URLSession` wrapper used by gateway implementations.
///
/// Boring on purpose: no retries, no connection pooling beyond what
/// `URLSession` already does, no logging. Surface a typed error and let the
/// caller decide what to do.
public struct HTTPClient: Sendable {
    private let session: URLSession

    /// Create a client that issues requests through the supplied session.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Issue a JSON POST and return the decoded response body.
    public func postJSON<Response: Decodable>(
        url: URL,
        body: some Encodable,
        headers: [String: String] = [:],
        responseType: Response.Type
    ) async throws -> Response {
        let data = try await postRaw(url: url, body: body, headers: headers)
        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw MojenticError.decoding(
                message: "Failed to decode \(responseType): \(error.localizedDescription)"
            )
        }
    }

    /// Issue a JSON POST and return raw response bytes.
    public func postRaw(
        url: URL,
        body: some Encodable,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
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
        responseType: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data = try await execute(request: request)
        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
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
        headers: [String: String] = [:]
    ) async throws -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
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
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        #endif
    }

    #if canImport(FoundationNetworking)
        /// Yield buffered bytes line by line.
        ///
        /// Used only on Linux where `URLSession.bytes(for:)` is unavailable.
        private static func linesStream(from data: Data) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let text = String(bytes: data, encoding: .utf8) ?? ""
                    for line in text.split(
                        omittingEmptySubsequences: false,
                        whereSeparator: { $0.isNewline }
                    ) {
                        if Task.isCancelled { break }
                        continuation.yield(String(line))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    #endif

    private func execute(request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try assertSuccess(response: response, sampleBody: data)
            return data
        } catch let error as MojenticError {
            throw error
        } catch is CancellationError {
            throw MojenticError.cancelled
        } catch {
            throw MojenticError.transport(message: error.localizedDescription)
        }
    }

    private func assertSuccess(response: URLResponse, sampleBody: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MojenticError.transport(message: "Non-HTTP response: \(type(of: response))")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: sampleBody, encoding: .utf8) ?? ""
            throw MojenticError.http(status: http.statusCode, body: body)
        }
    }
}
