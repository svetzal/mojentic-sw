import Foundation
import Testing

@testable import Mojentic

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Serves the oMLX fixtures over a real `URLSession`, with real HTTP status
/// codes and headers, so tests exercise ``HTTPClient`` rather than a
/// replaced transport.
///
/// Stateless: the reply depends only on the request, so parallel tests
/// cannot interfere. Requests without `Authorization: Bearer stub-key` get
/// a 401.
final class OMLXStubURLProtocol: URLProtocol {
    static let apiKey = "stub-key"

    override static func canInit(with _: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.route(request)
        do {
            let body = try OMLXFixture.data(reply.fixture)
            guard
                let url = request.url,
                let response = HTTPURLResponse(
                    url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private struct Reply {
        let status: Int
        let fixture: String
        var headers = ["Content-Type": "application/json"]
    }

    private static func route(_ request: URLRequest) -> Reply {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)" else {
            return Reply(status: 401, fixture: "error_model_not_found.json")
        }
        switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
        case ("GET", "/v1/models"):
            return Reply(status: 200, fixture: "models.json")
        case ("POST", "/v1/chat/completions"):
            var reply = Reply(status: 200, fixture: "chat_json_schema.json")
            reply.headers["Warning"] = #"199 omlx "grammar not enforced""#
            return reply
        case ("POST", "/v1/models/\(omlxFixtureModel)/unload"):
            return Reply(status: 400, fixture: "error_model_not_loaded.json")
        default:
            return Reply(status: 404, fixture: "error_model_not_found.json")
        }
    }
}

@Suite("oMLX gateway over a real URLSession")
struct OMLXURLSessionTests {
    private let host = "http://omlx.test:8000"

    private func gateway(apiKey: String = OMLXStubURLProtocol.apiKey) throws -> OMLXGateway {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OMLXStubURLProtocol.self]
        return OMLXGateway(
            host: try #require(URLComponents(string: host)?.url),
            apiKey: apiKey,
            timeout: 5,
            session: URLSession(configuration: configuration)
        )
    }

    @Test("the models list decodes from a JSON response")
    func availableModels() async throws {
        #expect(try await gateway().availableModels() == [omlxFixtureModel])
    }

    @Test("a structured response decodes and its real Warning header lands in metadata")
    func structuredWithWarning() async throws {
        let response = try await gateway().completeStructured(
            model: omlxFixtureModel,
            messages: [.user("Ada, 36")],
            schema: ["type": "object"],
            config: CompletionConfig()
        )
        #expect(response.value == ["name": "Ada", "age": .integer(36)])
        #expect(response.response.metadata?["response_format_warning"] == #"199 omlx "grammar not enforced""#)
        #expect(response.response.usage == Usage(promptTokens: 63, completionTokens: 19, totalTokens: 82))
    }

    @Test("a 400 from unload is an HTTP error carrying the body")
    func unloadNotLoaded() async throws {
        let gateway = try gateway()
        let failure = await httpFailure { try await gateway.unloadModel(omlxFixtureModel) }
        #expect(failure?.status == 400)
        #expect(failure?.body.contains("Model not loaded") == true)
    }

    @Test("a wrong API key is an HTTP 401")
    func wrongKey() async throws {
        let gateway = try gateway(apiKey: "wrong")
        let failure = await httpFailure { _ = try await gateway.availableModels() }
        #expect(failure?.status == 401)
    }
}
