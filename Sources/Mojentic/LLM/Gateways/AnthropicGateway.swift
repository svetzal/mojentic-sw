import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if anthropic

    /// Gateway for the Anthropic Messages API.
    ///
    /// Gated on the `anthropic` package trait — consumers opt in by adding
    /// `traits: ["anthropic"]` (or `["full"]`) to their `.package(url:)` entry.
    ///
    /// Targets `POST https://api.anthropic.com/v1/messages`. Highlights:
    /// - `system` is extracted from input messages and passed as a top-level
    ///   field (Anthropic does not have a `system` role).
    /// - `completeJSON` instructs the model to produce JSON matching the
    ///   supplied schema and extracts the JSON from the assistant text. The
    ///   Anthropic API does not (yet) ship a native JSON-schema response
    ///   format.
    /// - `availableModels()` returns the model registry's static list because
    ///   the Anthropic API does not expose a public list endpoint.
    /// - Extended thinking is enabled when ``CompletionConfig/reasoning`` is
    ///   set and the model supports it.
    /// - SSE streaming parses Anthropic's named-event format
    ///   (`event: <name>\ndata: {...}`).
    public struct AnthropicGateway: LLMGateway {
        /// Default Anthropic v1 base URL.
        public static let defaultBaseURL: URL = {
            guard let url = URL(string: "https://api.anthropic.com/v1") else {
                preconditionFailure("Built-in Anthropic base URL must be valid")
            }
            return url
        }()

        /// Default `anthropic-version` header value.
        public static let defaultAPIVersion = "2023-06-01"

        private let baseURL: URL
        private let apiKey: String
        private let apiVersion: String
        private let client: HTTPClient
        private let registry: AnthropicModelRegistry
        private let logger: Logger

        /// Create the gateway.
        public init(
            apiKey: String,
            baseURL: URL = AnthropicGateway.defaultBaseURL,
            apiVersion: String = AnthropicGateway.defaultAPIVersion,
            client: HTTPClient = HTTPClient(),
            registry: AnthropicModelRegistry = .shared
        ) {
            precondition(!apiKey.isEmpty, "Anthropic API key must not be empty")
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.apiVersion = apiVersion
            self.client = client
            self.registry = registry
            self.logger = Logger(label: "mojentic.gateway.anthropic")
        }

        // MARK: - LLMGateway

        /// Run a non-streaming chat completion via `/v1/messages`.
        public func complete(
            model: String,
            messages: [LLMMessage],
            tools: [any LLMTool]?,
            config: CompletionConfig
        ) async throws -> LLMGatewayResponse {
            let body = buildRequest(
                model: model,
                messages: messages,
                tools: tools,
                config: config,
                stream: false,
                extraSystemSuffix: nil
            )
            let response = try await client.postJSON(
                url: baseURL.appendingPathComponent("messages"),
                body: body,
                headers: authHeaders(),
                responseType: AnthropicMessageResponse.self
            )
            return response.toGatewayResponse()
        }

        /// Run a structured-output completion by instructing the model to
        /// produce JSON matching the schema and extracting it from the reply.
        public func completeJSON(
            model: String,
            messages: [LLMMessage],
            schema: JSONValue,
            config: CompletionConfig
        ) async throws -> JSONValue {
            let serialisedSchema: String
            if let data = try? JSONEncoder().encode(schema),
                let text = String(data: data, encoding: .utf8)
            {
                serialisedSchema = text
            } else {
                serialisedSchema = "{}"
            }
            let suffix = """
                Respond with ONLY a single JSON object matching the schema below. \
                Do not include any prose, code fences, or explanation. \
                Schema: \(serialisedSchema)
                """
            let body = buildRequest(
                model: model,
                messages: messages,
                tools: nil,
                config: config,
                stream: false,
                extraSystemSuffix: suffix
            )
            let response = try await client.postJSON(
                url: baseURL.appendingPathComponent("messages"),
                body: body,
                headers: authHeaders(),
                responseType: AnthropicMessageResponse.self
            )
            let text = response.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = Self.extractJSONPayload(from: text)
            guard let data = payload.data(using: .utf8) else {
                throw MojenticError.decoding(
                    message: "Empty JSON content from Anthropic"
                )
            }
            do {
                return try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw MojenticError.decoding(
                    message: "Anthropic returned non-JSON content for structured output: \(text)"
                )
            }
        }

        /// Return the static model registry list (Anthropic has no models
        /// endpoint).
        public func availableModels() async throws -> [String] {
            registry.registeredModels()
        }

        /// Stream a chat completion via Anthropic's SSE named-event format.
        public func stream(
            model: String,
            messages: [LLMMessage],
            tools: [any LLMTool]?,
            config: CompletionConfig
        ) -> AsyncThrowingStream<GatewayStreamEvent, any Error> {
            let body = buildRequest(
                model: model,
                messages: messages,
                tools: tools,
                config: config,
                stream: true,
                extraSystemSuffix: nil
            )
            let url = baseURL.appendingPathComponent("messages")
            let client = self.client
            let headers = authHeaders()

            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let lines = try await client.streamLines(
                            url: url,
                            body: body,
                            headers: headers
                        )
                        var accumulator = AnthropicStreamAccumulator()
                        for try await line in lines {
                            try Task.checkCancellation()
                            // Anthropic SSE emits "event: ..." and "data: ..."
                            // lines plus blank separators. Skip everything but
                            // data payloads; the event name is mirrored inside
                            // the payload's `type` field.
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            guard trimmed.hasPrefix("data:") else { continue }
                            let payload = String(trimmed.dropFirst("data:".count))
                                .trimmingCharacters(in: .whitespaces)
                            if payload.isEmpty || payload == "[DONE]" { continue }
                            guard let data = payload.data(using: .utf8),
                                let value = try? JSONDecoder().decode(JSONValue.self, from: data)
                            else { continue }
                            for event in accumulator.absorb(value) {
                                continuation.yield(event)
                            }
                        }
                        for call in accumulator.finishedToolCalls() {
                            continuation.yield(.toolCallRequest(call))
                        }
                        continuation.yield(
                            .done(
                                finishReason: accumulator.finishReason,
                                usage: accumulator.usage
                            )
                        )
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: MojenticError.cancelled)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // MARK: - Helpers

        private func authHeaders() -> [String: String] {
            [
                "x-api-key": apiKey,
                "anthropic-version": apiVersion,
            ]
        }

        private func buildRequest(
            model: String,
            messages: [LLMMessage],
            tools: [any LLMTool]?,
            config: CompletionConfig,
            stream: Bool,
            extraSystemSuffix: String?
        ) -> JSONValue {
            let capabilities = registry.capabilities(for: model)
            let adapted = AnthropicMessageAdapter.adapt(messages)
            var dict: [String: JSONValue] = [
                "model": .string(model),
                "messages": .array(adapted.messages),
                "max_tokens": .integer(max(1, config.maxTokens)),
                "stream": .bool(stream),
                "temperature": .number(config.temperature),
            ]
            if let topP = config.topP {
                dict["top_p"] = .number(topP)
            }
            var system = adapted.system
            if let suffix = extraSystemSuffix {
                system = [system, suffix].compactMap(\.self).joined(separator: "\n\n")
            }
            if let system, !system.isEmpty {
                dict["system"] = .string(system)
            }
            if let tools, !tools.isEmpty, capabilities.supportsTools {
                dict["tools"] = .array(tools.map(toolDescriptor(for:)))
            }
            if capabilities.supportsExtendedThinking, config.reasoning != nil {
                dict["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": .integer(max(1024, config.maxTokens / 4)),
                ]
            }
            for (key, value) in config.extraOptions {
                dict[key] = value
            }
            return .object(dict)
        }

        private func toolDescriptor(for tool: any LLMTool) -> JSONValue {
            [
                "name": .string(tool.descriptor.name),
                "description": .string(tool.descriptor.description),
                "input_schema": tool.descriptor.parameters,
            ]
        }

        static func extractJSONPayload(from text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip a leading ```json (or plain ```) fence + trailing ```.
            if trimmed.hasPrefix("```") {
                let withoutLeading = trimmed.drop(while: { $0 == "`" })
                let afterFence = withoutLeading.drop(while: { $0 != "\n" })
                let withoutLeadingNewline =
                    afterFence.first == "\n" ? afterFence.dropFirst() : afterFence
                let fenceClosed = withoutLeadingNewline.reversed().drop(while: { $0 == "`" })
                let inner = String(fenceClosed.reversed())
                return inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
    }

    // MARK: - Wire decoding

    private struct AnthropicMessageResponse: Decodable {
        let content: [AnthropicContentBlock]
        let stopReason: String?
        let usage: AnthropicUsage?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case usage
        }

        var combinedText: String {
            content.compactMap(\.text).joined()
        }

        func toGatewayResponse() -> LLMGatewayResponse {
            var calls: [LLMToolCall] = []
            var thinking: String?
            for block in content {
                switch block.type {
                case "tool_use":
                    calls.append(
                        LLMToolCall(
                            id: block.id,
                            name: block.name ?? "",
                            arguments: block.input ?? .object([:])
                        )
                    )
                case "thinking":
                    thinking = (thinking ?? "") + (block.thinking ?? "")
                default:
                    continue
                }
            }
            return LLMGatewayResponse(
                content: combinedText,
                toolCalls: calls,
                thinking: thinking,
                finishReason: Self.mapStopReason(stopReason, hasToolCalls: !calls.isEmpty),
                usage: usage?.toUsage()
            )
        }

        private static func mapStopReason(_ raw: String?, hasToolCalls: Bool) -> FinishReason? {
            if hasToolCalls { return .toolCalls }
            switch raw {
            case "end_turn":
                return .stop
            case "max_tokens":
                return .length
            case nil:
                return nil
            default:
                return .other
            }
        }
    }

    private struct AnthropicContentBlock: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }

    private struct AnthropicUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }

        func toUsage() -> Usage {
            Usage(
                promptTokens: inputTokens,
                completionTokens: outputTokens,
                totalTokens: (inputTokens ?? 0) + (outputTokens ?? 0)
            )
        }
    }

    // MARK: - SSE accumulator

    /// Accumulates Anthropic SSE deltas into normalised gateway stream events.
    ///
    /// Anthropic streams content via `content_block_start`,
    /// `content_block_delta`, `content_block_stop`, `message_delta`, and
    /// `message_stop` events. Tool-use argument fragments arrive as
    /// `input_json_delta` payloads inside `content_block_delta` events.
    private struct AnthropicStreamAccumulator {
        var finishReason: FinishReason?
        var usage: Usage?
        private var pendingTools: [Int: ToolBuilder] = [:]

        struct ToolBuilder {
            var id: String
            var name: String
            var inputBuffer: String = ""
        }

        mutating func absorb(_ value: JSONValue) -> [GatewayStreamEvent] {
            guard let object = value.objectValue,
                let type = object["type"]?.stringValue
            else { return [] }
            switch type {
            case "content_block_start":
                guard let index = object["index"]?.intValue,
                    let block = object["content_block"]?.objectValue
                else { return [] }
                if block["type"]?.stringValue == "tool_use" {
                    pendingTools[index] = ToolBuilder(
                        id: block["id"]?.stringValue ?? "",
                        name: block["name"]?.stringValue ?? ""
                    )
                }
                return []
            case "content_block_delta":
                guard let delta = object["delta"]?.objectValue else { return [] }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    if let text = delta["text"]?.stringValue, !text.isEmpty {
                        return [.textDelta(text)]
                    }
                    return []
                case "thinking_delta":
                    if let thinking = delta["thinking"]?.stringValue, !thinking.isEmpty {
                        return [.thinkingDelta(thinking)]
                    }
                    return []
                case "input_json_delta":
                    if let index = object["index"]?.intValue,
                        var builder = pendingTools[index],
                        let chunk = delta["partial_json"]?.stringValue
                    {
                        builder.inputBuffer += chunk
                        pendingTools[index] = builder
                    }
                    return []
                default:
                    return []
                }
            case "message_delta":
                if let stop = object["delta"]?.objectValue?["stop_reason"]?.stringValue {
                    finishReason = AnthropicStreamAccumulator.mapStop(stop)
                }
                if let usagePayload = object["usage"]?.objectValue {
                    usage = AnthropicStreamAccumulator.mapUsage(usagePayload, previous: usage)
                }
                return []
            case "message_stop":
                return []
            default:
                return []
            }
        }

        func finishedToolCalls() -> [LLMToolCall] {
            pendingTools.keys.sorted().compactMap { index -> LLMToolCall? in
                guard let builder = pendingTools[index] else { return nil }
                let arguments: JSONValue
                if let data = (builder.inputBuffer.isEmpty ? "{}" : builder.inputBuffer)
                    .data(using: .utf8),
                    let value = try? JSONDecoder().decode(JSONValue.self, from: data)
                {
                    arguments = value
                } else {
                    arguments = .object([:])
                }
                return LLMToolCall(id: builder.id, name: builder.name, arguments: arguments)
            }
        }

        private static func mapStop(_ raw: String) -> FinishReason {
            switch raw {
            case "end_turn": return .stop
            case "max_tokens": return .length
            case "tool_use": return .toolCalls
            default: return .other
            }
        }

        private static func mapUsage(_ payload: [String: JSONValue], previous: Usage?) -> Usage {
            let prompt = payload["input_tokens"]?.intValue ?? previous?.promptTokens
            let completion = payload["output_tokens"]?.intValue ?? previous?.completionTokens
            let total: Int? =
                (prompt ?? 0) + (completion ?? 0) > 0 ? (prompt ?? 0) + (completion ?? 0) : nil
            return Usage(
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: total
            )
        }
    }

#endif
