import Foundation
import Mojentic
import Testing

// Public API consumption against the versioned wire expectations, using real URLSession.
@Suite(.serialized)
struct RequestFidelityTests {
    @Test func fixedTemperatureUsesOnlyAllowedValue() async throws {
        try await verifyRequestShapes(modelFilter: "o3")
    }

    @Test func unsupportedReasoningIsDropped() async throws {
        _ = RequestFidelityLogCapture.install
        RequestFidelityLogCapture.entries.withLock { $0.removeAll() }
        try await RequestFidelityLogCapture.$recording.withValue(true) {
            try await verifyRequestShapes(modelFilter: "gpt-4o")
        }
        let rows = try requestFidelityRows("cases").filter { $0.objectValue?["model"] == "gpt-4o" }
        let expected = try #require(rows.first?.objectValue?["warning"]?.stringValue)
        let warnings = RequestFidelityLogCapture.entries.withLock { entries in
            entries.filter {
                $0.label == "mojentic.gateway.openai" && $0.level == .warning
                    && $0.message == expected
            }
        }
        #expect(warnings.count == 2, "Each default/explicit request must warn when dropping reasoning")
    }

    @Test func forbiddenTemperatureIsOmitted() async throws {
        try await verifyRequestShapes(modelFilter: "gpt-4o-search-preview")
    }

    private func verifyRequestShapes(modelFilter: String) async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "request_fidelity_v1", withExtension: "json", subdirectory: "Fixtures/Contracts")
        )
        let contract = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        #expect(contract.objectValue?["version"] == "request-fidelity-v1")
        guard case .array(let rows) = contract.objectValue?["cases"] else {
            Issue.record("Missing request-fidelity-v1 rows")
            return
        }
        for row in rows {
            let fields = try #require(row.objectValue)
            let model = try #require(fields["model"]?.stringValue)
            guard model == modelFilter else { continue }
            let explicit = fields["explicit"] == true
            let config = CompletionConfig(
                temperature: explicit ? 0 : nil,
                maxTokens: explicit ? 8192 : nil,
                topP: explicit ? 0.8 : nil,
                reasoning: fields["reasoning"] == true ? .high : nil,
                numCtx: explicit ? 8192 : nil)
            let server = try InProcessHTTPFixture(replies: [
                try requestFidelityReply("openai")
            ])
            defer { server.release() }
            let gateway = OpenAIGateway(apiKey: "contract-secret", baseURL: server.url)
            let response = try await gateway.complete(
                model: model, messages: [.user("hello")], tools: nil, config: config)
            #expect(response.content == "answer")
            let bytes = try #require(server.requests.withLock { $0.first })
            let body = try #require(JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
            let expected = try #require(fields["expected"]?.objectValue)
            for key in ["temperature", "max_tokens", "max_completion_tokens", "top_p", "reasoning_effort"] {
                #expect(body[key] == expected[key], "case: \(model), field: \(key)")
            }
            #expect(body["model"] == .string(model))
            #expect(body["num_ctx"] == nil)
            #expect(body["num_predict"] == nil)
        }
    }

    #if anthropic
        @Test(arguments: ["claude-3-7-sonnet-latest", "claude-3-5-sonnet-20241022"], [false, true])
        func documentedLegacyOutputLimit(model: String, explicit: Bool) async throws {
            let server = try InProcessHTTPFixture(replies: [try requestFidelityReply("anthropic")])
            defer { server.release() }
            let config = CompletionConfig(maxTokens: explicit ? 8192 : nil, reasoning: .high)
            let result = try await AnthropicGateway(apiKey: "contract-secret", baseURL: server.url).complete(
                model: model, messages: [.user("hello")], tools: nil, config: config)
            #expect(result.content == "answer")
            let bytes = try #require(server.requests.withLock { $0.first })
            let body = try #require(JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
            let limit = explicit ? 8192 : (model == "claude-3-7-sonnet-latest" ? 64000 : 8192)
            #expect(body["model"] == .string(model))
            #expect(body["max_tokens"] == .integer(limit))
            if model == "claude-3-7-sonnet-latest" {
                #expect(body["thinking"] == ["type": "enabled", "budget_tokens": .integer(limit / 4)])
            }
        }

        @Test(arguments: try requestFidelityRows("anthropic_cases"), [false, true])
        func anthropicRequiredLimitAndThinking(row: JSONValue, explicit: Bool) async throws {
            let fields = try #require(row.objectValue)
            let model = try #require(fields["model"]?.stringValue)
            let server = try InProcessHTTPFixture(replies: [
                try requestFidelityReply("anthropic")
            ])
            defer { server.release() }
            let explicitLimit = try #require(fields["explicit_max_tokens"]?.intValue)
            let config = CompletionConfig(
                temperature: explicit ? 0 : nil,
                maxTokens: explicit ? explicitLimit : nil,
                reasoning: .high)
            let result = try await AnthropicGateway(apiKey: "contract-secret", baseURL: server.url).complete(
                model: model, messages: [.user("hello")], tools: nil, config: config)
            #expect(result.content == "answer")
            let bytes = try #require(server.requests.withLock { $0.first })
            let body = try #require(JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
            let limit = explicit ? explicitLimit : try #require(fields["max_tokens"]?.intValue)
            #expect(body["model"] == .string(model))
            #expect(body["max_tokens"] == .integer(limit), "case: \(model), explicit: \(explicit)")
            #expect(body["temperature"] == (explicit ? .integer(0) : nil))
            if fields["thinking"] == true {
                #expect(
                    body["thinking"] == ["type": "enabled", "budget_tokens": .integer(max(1024, limit / 4))])
            } else {
                #expect(body["thinking"] == nil)
            }
            print("PASS anthropic/\(model)/\(explicit ? "explicit" : "default")")
        }

        @Test func anthropicContractCoversRegisteredModels() throws {
            let covered = try Set(
                requestFidelityRows("anthropic_cases").compactMap { $0.objectValue?["model"]?.stringValue })
            #expect(Set(AnthropicModelRegistry.shared.registeredModels()).isSubset(of: covered))
        }
    #endif

    @Test(arguments: [false, true])
    func sessionReservesOnlyExplicitOutputLimit(explicit: Bool) async throws {
        let reply = try requestFidelityReply("openai")
        let server = try InProcessHTTPFixture(replies: [reply, reply])
        defer { server.release() }
        let gateway = OpenAIGateway(apiKey: "contract-secret", baseURL: server.url)
        let session = ChatSession(
            broker: LLMBroker(gateway: gateway),
            model: "gpt-4o",
            config: CompletionConfig(maxTokens: explicit ? 10 : nil),
            contextWindowManager: TokenBudgetContextWindowManager(
                budget: 10,
                model: "gpt-4o",
                tokenizer: ApproximateTokenizerGateway(charactersPerToken: 1, perMessageOverhead: 0)))
        _ = try await session.send("hi")
        _ = try await session.send("yo")
        let bytes = try #require(server.requests.withLock { $0.last })
        let body = try #require(JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
        let expected: JSONValue =
            explicit
            ? [["role": "user", "content": "yo"]]
            : [
                ["role": "user", "content": "hi"], ["role": "assistant", "content": "answer"],
                ["role": "user", "content": "yo"],
            ]
        #expect(body["messages"] == expected)
        #expect(body["max_tokens"] == (explicit ? .integer(10) : nil))
        #expect(body["temperature"] == nil)
        #expect(body["num_ctx"] == nil)
    }

    @Test func legacyAndSparseCodableConfigurations() throws {
        let legacy = Data(#"{"temperature":1,"maxTokens":16384,"numCtx":32768,"extraOptions":{}}"#.utf8)
        let old = try JSONDecoder().decode(CompletionConfig.self, from: legacy)
        #expect(old.temperature == 1)
        #expect(old.maxTokens == 16384)
        #expect(old.numCtx == 32768)
        for record in [#"{"extraOptions":{}}"#, #"{"temperature":null,"maxTokens":null,"extraOptions":{}}"#] {
            let sparse = try JSONDecoder().decode(CompletionConfig.self, from: Data(record.utf8))
            #expect(sparse.temperature == nil)
            #expect(sparse.maxTokens == nil)
            #expect(sparse.numCtx == nil)
            #expect(
                try JSONDecoder().decode(CompletionConfig.self, from: JSONEncoder().encode(sparse)) == sparse)
        }
        let current = CompletionConfig()
        #expect(
            try JSONDecoder().decode(CompletionConfig.self, from: JSONEncoder().encode(current)) == current)
    }
}

private func requestFidelityRows(_ key: String) throws -> [JSONValue] {
    let url = try #require(
        Bundle.module.url(
            forResource: "request_fidelity_v1", withExtension: "json", subdirectory: "Fixtures/Contracts"))
    let contract = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    guard case .array(let rows) = contract.objectValue?[key] else {
        throw MojenticError.decoding(message: "Missing request-fidelity-v1 rows")
    }
    return rows
}

private func requestFidelityReply(_ provider: String) throws -> RecoveryReply {
    let url = try #require(
        Bundle.module.url(
            forResource: "request_fidelity_v1", withExtension: "json", subdirectory: "Fixtures/Contracts"))
    let contract = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    return RecoveryReply(
        body: try #require(contract.objectValue?["responses"]?.objectValue?[provider]?.stringValue))
}
