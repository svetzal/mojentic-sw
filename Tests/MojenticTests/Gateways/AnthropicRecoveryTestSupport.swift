import Foundation
@testable import Mojentic
import Testing

extension StreamingBoundary {
    /// Real named-event fixtures; no OpenAI vocabulary reaches the Anthropic decoder.
    func anthropicFrame(
        content: String, reasoning: String, tool: Bool, done: Bool, reason: String, metrics: Bool,
    ) throws -> String {
        var frames: [JSONValue] = [
            [
                "type": "message_start",
                "message": [
                    "role": "assistant", "model": "payload-sentinel", "id": "credential-sentinel",
                    "content": [],
                    "usage": ["input_tokens": 3, "output_tokens": 0],
                ],
            ]
        ]
        var index = 0
        for (kind, text) in [("thinking", reasoning), ("text", content)] where !text.isEmpty {
            frames += [
                [
                    "type": "content_block_start",
                    "index": .integer(index),
                    "content_block": ["type": .string(kind), .init(kind): ""],
                ],
                [
                    "type": "content_block_delta",
                    "index": .integer(index),
                    "delta": [
                        "type": .string(kind == "text" ? "text_delta" : "thinking_delta"),
                        .init(kind): .string(text),
                    ],
                ],
                ["type": "content_block_stop", "index": .integer(index)],
            ]
            index += 1
        }
        if tool {
            frames.append([
                "type": "content_block_start",
                "index": .integer(index),
                "content_block": [
                    "type": "tool_use",
                    "id": "original-tool",
                    "name": "resolve_date",
                    "input": ["relative": "tomorrow"],
                ],
            ])
            if done {
                frames.append(["type": "content_block_stop", "index": .integer(index)])
            }
        }
        if done {
            frames += [
                [
                    "type": "message_delta",
                    "delta": [
                        "stop_reason": .string(
                            reason == "stop" || reason == "end_turn"
                                ? (tool ? "tool_use" : "end_turn") : reason
                        )
                    ],
                    "usage": ["output_tokens": .integer(metrics ? 12 : 4)],
                ],
                ["type": "message_stop"],
            ]
        }
        return try frames.map { value in
            let type = try #require(value.objectValue?["type"]?.stringValue)
            let encoded = try #require(String(data: JSONEncoder().encode(value), encoding: .utf8))
            return "event: \(type)\ndata: \(encoded)\n\n"
        }
        .joined()
    }
}
