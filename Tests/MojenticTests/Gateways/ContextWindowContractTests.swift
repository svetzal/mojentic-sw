import Foundation
@testable import Mojentic
import Testing

// Keep contract row diagnostics in a stable suite order.
@Suite(.serialized)
struct ContextWindowContractTests {
    @Test func exactSelectionThroughHTTP() async throws {
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(
                body:
                    #"""
                    {"data":[{"id":"other","max_model_len":8},
                    {"id":"exact-model","max_model_len":262144}]}
                    """#
            )
        ])
        defer { server.release() }
        let gateway = OMLXGateway(host: server.url, apiKey: "contract-secret")
        let window = try await gateway.modelContextWindow(model: "exact-model")
        #expect(window == ModelContextWindow(maxContextTokens: 262144, field: "max_model_len"))
        #expect(server.requestHeaders.withLock { $0.first }?.contains("GET /v1/models HTTP/1.1") == true)
        #expect(server.requestHeaders.withLock { $0.first }?.contains("Bearer contract-secret") == true)
    }
}

extension ContextWindowContractTests {
    @Test(arguments: try ContextWindowRow.all(), [false, true])
    func sharedProviderAndConsumerRows(row: ContextWindowRow, consumer: Bool) async throws {
        let fields = row.fields
        let provider = try #require(fields["provider"]?.stringValue)
        let model = try #require(fields["model"]?.stringValue)
        let status = try #require(fields["status"]?.intValue)
        let body = try #require(fields["response"]?.stringValue)
        let server = try InProcessHTTPFixture(replies: [RecoveryReply(status: status, body: body)])
        defer { server.release() }
        let authenticated = fields["without_api_key"] != .bool(true)
        let gateway = ContextWindowContract.gateway(provider, server: server, authenticated: authenticated)
        let expected = try #require(fields["expected"]?.objectValue)
        do {
            let actual = try await gateway.modelContextWindow(model: model)
            #expect(expected["error"] == nil)
            let window = try ContextWindowContract.window(expected["window"])
            #expect(actual == window)
            if consumer {
                // Consumer decisions derive from the verified row, never an independent gateway mock.
                #expect(
                    effectiveContextWindow(actual, config: .init(numCtx: nil))
                        == window.map { min($0.maxContextTokens, $0.modelNumCtx ?? $0.maxContextTokens) })
            }
        } catch let error as MojenticError {
            switch error {
            case .http(let actualStatus, let actualBody):
                #expect(expected["error"] == .array(["http_error", .integer(status)]))
                #expect(actualStatus == status)
                #expect(actualBody == body)
            case .decoding:
                #expect(expected["error"] == "invalid_response")
            default:
                Issue.record("Unexpected error for \(row.testDescription): \(error)")
            }
        }
        let request = try #require(fields["request"]?.objectValue)
        let headers = try #require(server.requestHeaders.withLock { $0.first })
        let method = try #require(request["method"]?.stringValue)
        let path = try #require(request["path"]?.stringValue)
        #expect(headers.hasPrefix("\(method) \(path) HTTP/1.1\r\n"))
        let bytes = try #require(server.requests.withLock { $0.first })
        if request["body"] == .null {
            #expect(bytes.isEmpty)
        } else {
            #expect(try JSONDecoder().decode(JSONValue.self, from: bytes) == request["body"])
        }
        if provider == "omlx" {
            #expect(headers.lowercased().contains("authorization:") == authenticated)
            if authenticated {
                #expect(headers.lowercased().contains("authorization: bearer contract-secret"))
            }
        } else {
            #expect(headers.lowercased().contains("x-contract: configured"))
        }
    }

    @Test func effectiveRows() throws {
        for row in try ContextWindowContract().rows("effective_cases") {
            let window = try ContextWindowContract.window(row["window"])
            #expect(
                effectiveContextWindow(window, config: .init(numCtx: row["num_ctx"]?.intValue))
                    == row["expected"]?.intValue)
        }
    }

    @Test func registryRowsNeverRequestHTTP() async throws {
        let server = try InProcessHTTPFixture(replies: [RecoveryReply(status: 418, body: "must not request")])
        defer { server.release() }
        let gateway = ContextWindowContract.gateway("openai", server: server)
        for row in try ContextWindowContract().rows("registry_cases") {
            let result = try await gateway.modelContextWindow(model: #require(row["model"]?.stringValue))
            #expect(result == (try ContextWindowContract.window(row["window"])))
        }
        #expect(server.requests.withLock { $0.isEmpty })
    }
}

extension ContextWindowContractTests {
    @Test(arguments: ["ollama", "omlx"])
    func transportFailureIsAnError(provider: String) async throws {
        let server = try InProcessHTTPFixture(replies: [RecoveryReply(body: "{}", truncated: true)])
        defer { server.release() }
        let gateway = ContextWindowContract.gateway(provider, server: server)
        await #expect { _ = try await gateway.modelContextWindow(model: "exact-model") } throws: { error in
            guard case MojenticError.transport = error else { return false }
            return true
        }
    }
}
