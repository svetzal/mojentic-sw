import Foundation
@testable import Mojentic
import Testing

// Bound socket usage while the repository's recovery matrices run in parallel.
@Suite(.serialized)
struct ContextWindowJourneyTests {
    @Test(arguments: ["ollama", "omlx", "openai"], ["ordinary", "json", "structured", "stream", "events"])
    func discoveryPreservesCompletion(provider: String, route: String) async throws {
        try await verifyDiscovery(provider: provider, route: route, explicit: false)
        try await verifyDiscovery(provider: provider, route: route, explicit: true)
    }

    private func verifyDiscovery(provider: String, route: String, explicit: Bool) async throws {
        let contract = try ContextWindowContract()
        let row = try #require(
            contract.rows("cases").first {
                $0["provider"] == .string(provider == "openai" ? "omlx" : provider)
                    && $0["name"] == .string(provider == "ollama" ? "model-num-ctx" : "exact-selection")
            })
        let streaming = route == "stream" || route == "events"
        let structured = route == "json" || route == "structured"
        let content = structured ? #"{\"answer\":7}"# : "answer"
        let ollama = provider == "ollama"
        let message = "{\"content\":\"\(content)\"}"
        let response =
            ollama
            ? "{\"message\":{\"content\":\"\(content)\"},\"done\":true,\"done_reason\":\"stop\"}"
            : "{\"choices\":[{\"\(streaming ? "delta" : "message")\":\(message),"
                + "\"finish_reason\":\"stop\"}]}"
        let reply = RecoveryReply(
            body: streaming ? (ollama ? response + "\n" : "data: \(response)\n\ndata: [DONE]\n\n") : response)
        let discovery = RecoveryReply(body: try #require(row["response"]?.stringValue))
        let server = try RecoveryLoopback(
            replies: provider == "openai" ? [reply, reply] : [reply, discovery, reply])
        defer { server.release() }
        let gateway = ContextWindowContract.gateway(provider, server: server)
        let model = provider == "openai" ? "gpt-4o" : try #require(row["model"]?.stringValue)
        let config =
            explicit
            ? CompletionConfig(temperature: 0, maxTokens: 512, topP: 0.8, numCtx: 8192) : CompletionConfig()
        try await complete(gateway, model: model, route: route, config: config)
        let window = try await gateway.modelContextWindow(model: model)
        #expect(window != nil)
        #expect(config.numCtx == (explicit ? 8192 : nil))
        try await complete(gateway, model: model, route: route, config: config)
        let requests = server.requests.withLock { $0 }
        #expect(requests.count == (provider == "openai" ? 2 : 3))
        #expect(try #require(requests.first) == #require(requests.last))
        let firstValue = try JSONDecoder().decode(JSONValue.self, from: #require(requests.first))
        let lastValue = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last))
        #expect(firstValue == lastValue)
        let body = try #require(firstValue.objectValue)
        let options = ollama ? try #require(body["options"]?.objectValue) : body
        #expect(options["temperature"] == (explicit ? .integer(0) : nil))
        #expect(options[ollama ? "num_predict" : "max_tokens"] == (explicit ? .integer(512) : nil))
        if ollama { #expect(options["num_ctx"] == (explicit ? .integer(8192) : nil)) }
        #expect(options["top_p"] == (explicit ? .number(0.8) : nil))
        #expect(body["stream"] == .bool(streaming))
        #expect(body["think"] == nil)
        #expect(body["reasoning_effort"] == nil)
        let first = try #require(requests.first)
        #expect(try JSONDecoder().decode(JSONValue.self, from: first).objectValue?["model"] == .string(model))
        let headers = server.requestHeaders.withLock { $0 }
        // Header ordering belongs to URLSession; compare exact lines without imposing their order.
        #expect(
            headers.first?.components(separatedBy: "\r\n").sorted()
                == headers.last?.components(separatedBy: "\r\n").sorted())
    }

    private func complete(
        _ gateway: any LLMGateway, model: String, route: String, config: CompletionConfig
    ) async throws {
        let messages: [LLMMessage] = [.user("unchanged")]
        let schema: JSONValue = ["type": "object", "properties": ["answer": ["type": "integer"]]]
        switch route {
        case "json":
            #expect(
                try await gateway.completeJSON(
                    model: model, messages: messages, schema: schema, config: config)
                    == ["answer": 7])
        case "structured":
            let result = try await gateway.completeStructured(
                model: model, messages: messages, schema: schema, config: config)
            #expect(result.value == ["answer": 7])
        case "stream":
            var text = ""
            for try await event in gateway.stream(
                model: model, messages: messages, tools: nil, config: config)
            {
                if case .textDelta(let delta) = event { text += delta }
            }
            #expect(text == "answer")
        case "events":
            var text = ""
            for await event in try gateway.completeStreamEvents(
                model: model, messages: messages, config: config)
            {
                if case .content(let delta) = event { text += delta }
            }
            #expect(text == "answer")
        default:
            let response = try await gateway.complete(
                model: model, messages: messages, tools: nil, config: config)
            #expect(response.content == "answer")
        }
    }

    @Test func configuredLookupKeepsExistingSwiftOrder() async throws {
        for row in try ContextWindowContract().rows("lookup_cases") {
            let provider = try #require(row["provider"]?.stringValue)
            let response = try #require(row["response"])
            let bytes = try JSONEncoder().encode(response)
            let server = try RecoveryLoopback(replies: [
                RecoveryReply(body: try #require(String(bytes: bytes, encoding: .utf8)))
            ])
            defer { server.release() }
            let names = try await ContextWindowContract.gateway(provider, server: server).availableModels()
            #expect(names == ["a", "b"])
            // Shared Ollama lookup row expects [b, a]; retain Swift's established sorted order.
            if provider == "ollama" {
                #expect(row["names"] == ["b", "a"])
                #expect(JSONValue.array(names.map(JSONValue.string)) != row["names"])
            } else {
                #expect(JSONValue.array(names.map(JSONValue.string)) == row["names"])
            }
            let path = try #require(row["path"]?.stringValue)
            let headers = try #require(server.requestHeaders.withLock { $0.first })
            #expect(headers.hasPrefix("GET \(path) HTTP/1.1\r\n"))
            #expect(server.requests.withLock { $0.first?.isEmpty } == true)
            #expect(
                headers.lowercased().contains(
                    provider == "ollama" ? "x-contract: configured" : "authorization: bearer contract-secret")
            )
        }
    }

    @Test func legacyGatewayHasNoWindow() async throws {
        let gateway: any LLMGateway = LegacyMetadataGateway()
        #expect(try await gateway.modelContextWindow(model: "exact-model") == nil)
    }
}

/// An unchanged legacy conformance implements only the pre-metadata requirements.
private struct LegacyMetadataGateway: LLMGateway {
    func complete(
        model: String, messages: [LLMMessage], tools: [any LLMTool]?, config: CompletionConfig
    ) async throws -> LLMGatewayResponse {
        throw MojenticError.invalidArgument(message: "Unused legacy completion")
    }
    func completeJSON(
        model: String, messages: [LLMMessage], schema: JSONValue, config: CompletionConfig
    ) async throws -> JSONValue {
        throw MojenticError.invalidArgument(message: "Unused legacy structured completion")
    }
    func availableModels() async throws -> [String] { [] }
    func stream(
        model: String, messages: [LLMMessage], tools: [any LLMTool]?, config: CompletionConfig
    ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
