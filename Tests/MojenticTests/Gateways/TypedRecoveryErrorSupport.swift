import Foundation
@testable import Mojentic
import Testing

struct TypedRecoveryBoundary: Sendable, CustomStringConvertible {
    enum Path: String, CaseIterable, Sendable {
        case gateway, structured, json, broker, brokerJSON, brokerResponse, session, sessionImages
        case gatewayStream, brokerStream, sessionStream, gatewaySingle, brokerSingle

        var streaming: Bool { rawValue.contains("Stream") || rawValue.contains("Single") }
        var single: Bool { self == .gatewaySingle || self == .brokerSingle }
    }

    let provider: RecoveryBoundary
    let path: Path
    var description: String { "\(provider)/\(path.rawValue)" }
    static var all: [Self] {
        RecoveryBoundary.all.filter { !$0.structured }.flatMap { provider in
            Path.allCases.map { Self(provider: provider, path: $0) }
        }
    }

    var stream: StreamingBoundary {
        .init(
            omlx: provider.omlx, single: path.single, openAI: provider.openAI, anthropic: provider.anthropic)
    }

    func reply(length: Bool) throws -> RecoveryReply {
        let reason = provider.anthropic ? "max_tokens" : "length"
        if path.streaming {
            return try RecoveryReply(
                headers: ["X-Request-ID": "typed-response", "request-id": "typed-response"],
                body: stream.frame(content: "é", done: true, reason: length ? reason : "stop", metrics: true),
            )
        }
        var root: JSONValue
        if provider.anthropic {
            root = [
                "id": "typed-message", "model": "served", "role": "assistant", "type": "message",
                "content": [["type": "text", "text": "é"]],
                "stop_reason": .string(length ? reason : "end_turn"),
                "usage": ["input_tokens": 3, "output_tokens": 12],
            ]
        } else if provider.omlx {
            root = [
                "id": "typed-message", "model": "served",
                "choices": [
                    [
                        "message": ["role": "assistant", "content": "é"],
                        "finish_reason": .string(length ? reason : "stop"),
                    ]
                ],
                "usage": ["prompt_tokens": 3, "completion_tokens": 12, "total_tokens": 15],
            ]
        } else {
            root = [
                "model": "served", "message": ["role": "assistant", "content": "é"],
                "done": true, "done_reason": .string(length ? reason : "stop"),
                "prompt_eval_count": 3, "eval_count": 12, "eval_duration": 6_000_000_000,
                "created_at": "typed-time",
            ]
        }
        return try RecoveryReply(
            headers: ["X-Request-ID": "typed-response", "request-id": "typed-response"],
            body: #require(String(data: JSONEncoder().encode(root), encoding: .utf8)),
        )
    }

    func failure(
        gateway: any LLMGateway,
        session: ChatSession,
        broker: LLMBroker,
        tool: RecoveryCountingTool,
        delivered: RecoveryLocked<Int>,
    ) async throws -> any Error {
        do {
            switch path {
            case .gateway:
                _ = try await gateway.complete(
                    model: "fixture", messages: [.user("question")], tools: [tool], config: .init())
            case .structured:
                _ = try await gateway.completeStructured(
                    model: "fixture", messages: [], schema: ["type": "object"], config: .init())
            case .json:
                _ = try await gateway.completeJSON(
                    model: "fixture", messages: [], schema: ["type": "object"], config: .init())
            case .broker:
                _ = try await broker.complete(model: "fixture", messages: [.user("question")], tools: [tool])
            case .brokerJSON:
                _ = try await broker.completeJSON(
                    model: "fixture",
                    messages: [.user("question")],
                    responseType: TypedRecoveryProjection.self)
            case .brokerResponse:
                _ = try await broker.generateResponse(
                    model: "fixture", messages: [.user("question")], tools: [tool])
            case .sessionImages:
                _ = try await session.send(
                    text: "question",
                    images: [ImageContent(base64: typedRecoveryImageBase64, mimeType: "image/png")])
            case .session:
                _ = try await session.send("question")
            default:
                return try await streamingFailure(
                    gateway: gateway, session: session, broker: broker, tool: tool, delivered: delivered)
            }
        } catch { return error }
        Issue.record("Expected public typed failure")
        throw MojenticError.invalidArgument(message: "Missing failure")
    }

    private func streamingFailure(
        gateway: any LLMGateway,
        session: ChatSession,
        broker: LLMBroker,
        tool: RecoveryCountingTool,
        delivered: RecoveryLocked<Int>,
    ) async throws -> any Error {
        switch path {
        case .gatewayStream:
            let upstream = gateway.streamRecovering(
                model: "fixture", messages: [], tools: [tool], config: .init())
            return try await collectTypedFailure(upstream) { event in
                if case .textDelta(let text) = event { delivered.withLock { $0 += text.utf8.count } }
                if case .done = event { Issue.record("Unexpected success terminal") }
            }
        case .brokerStream, .sessionStream:
            let upstream =
                path == .brokerStream
                ? broker.stream(model: "fixture", messages: [.user("question")], tools: [tool])
                : session.stream("question")
            return try await collectTypedFailure(upstream) { event in
                if case .textDelta(let text) = event { delivered.withLock { $0 += text.utf8.count } }
                if case .done = event { Issue.record("Unexpected success terminal") }
                if case .toolCallResult = event { Issue.record("Unexpected tool execution") }
            }
        case .gatewaySingle, .brokerSingle:
            let upstream =
                try path == .gatewaySingle
                ? gateway.completeStreamEventsRecovering(model: "fixture", messages: [], config: .init())
                : broker.generateRecoveryStreamEvents(model: "fixture", messages: [])
            var iterator = upstream.makeAsyncIterator()
            var terminal: (any Error)?
            while let event = await iterator.next() {
                #expect(terminal == nil)
                switch event {
                case .content(let text): delivered.withLock { $0 += text.utf8.count }
                case .error(let error): terminal = error
                case .recoveryFailure(let error): terminal = error
                case .completed: Issue.record("Unexpected success terminal")
                default: break
                }
            }
            #expect(await iterator.next() == nil)
            return try #require(terminal)
        default:
            throw MojenticError.invalidArgument(message: "Expected streaming boundary")
        }
    }

}

// A length or capture failure must reach the caller before this Codable projection.
struct TypedRecoveryProjection: Codable, Sendable, JSONSchemaProviding {
    let answer: Int
    static var jsonSchema: JSONValue {
        [
            "type": "object", "properties": ["answer": ["type": "integer"]], "required": ["answer"],
            "additionalProperties": false,
        ]
    }
}

struct TypedCaptureCause: Error, Sendable {
    let stage: String
    let sequence: Int
}

private func collectTypedFailure<Element: Sendable>(
    _ stream: AsyncThrowingStream<Element, any Error>,
    inspect: (Element) -> Void,
) async throws -> any Error {
    var iterator = stream.makeAsyncIterator()
    do {
        while let event = try await iterator.next() { inspect(event) }
    } catch {
        #expect(try await iterator.next() == nil)
        return error
    }
    Issue.record("Expected exactly one failure terminal")
    throw MojenticError.invalidArgument(message: "Missing stream failure")
}

// A synthetic one-pixel PNG, carried inline through each provider's real encoder.
let typedRecoveryImageBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

func assertTypedImageRequest(_ bytes: Data, provider: RecoveryBoundary) throws {
    let root = try JSONDecoder().decode(JSONValue.self, from: bytes)
    let value = try #require(root.objectValue?["messages"])
    guard case .array(let messages) = value else {
        Issue.record("Missing outbound messages")
        return
    }
    let user = try #require(messages.last?.objectValue)
    #expect(user["role"] == .string("user"))
    if !provider.omlx {
        #expect(user["content"] == .string("question"))
        #expect(user["images"] == .array([.string(typedRecoveryImageBase64)]))
    } else {
        let image: JSONValue =
            provider.anthropic
            ? [
                "type": "image",
                "source": [
                    "type": "base64", "media_type": "image/png", "data": .string(typedRecoveryImageBase64),
                ],
            ]
            : [
                "type": "image_url",
                "image_url": [
                    "url": .string("data:image/png;base64,\(typedRecoveryImageBase64)")
                ],
            ]
        #expect(user["content"] == .array([["type": "text", "text": "question"], image]))
    }
}
