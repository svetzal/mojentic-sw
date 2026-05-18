import Foundation
import Testing

@testable import Mojentic

@Suite("AnthropicMessageAdapter")
struct AnthropicMessageAdapterTests {
    @Test("system messages are extracted into the top-level `system` field")
    func systemExtraction() {
        let adapted = AnthropicMessageAdapter.adapt([
            .system("be brief"),
            .system("be polite"),
            .user("hi"),
        ])
        #expect(adapted.system == "be brief\n\npolite" || adapted.system == "be brief\n\nbe polite")
        #expect(adapted.messages.count == 1)
        #expect(adapted.messages.first?.objectValue?["role"]?.stringValue == "user")
    }

    @Test("plain user message uses string content")
    func plainUser() {
        let adapted = AnthropicMessageAdapter.adapt([.user("hello")])
        let first = adapted.messages.first?.objectValue
        #expect(first?["role"]?.stringValue == "user")
        #expect(first?["content"]?.stringValue == "hello")
    }

    @Test("multimodal user message becomes a content blocks array with image source")
    func multimodalUser() {
        let image = ImageContent(base64: "abc", mimeType: "image/png")
        let adapted = AnthropicMessageAdapter.adapt([
            .user(text: "describe", images: [image])
        ])
        guard case .array(let blocks) = adapted.messages.first?.objectValue?["content"] ?? .null
        else {
            Issue.record("expected content blocks array")
            return
        }
        #expect(blocks.count == 2)
        let imageBlock = blocks.last?.objectValue
        #expect(imageBlock?["type"]?.stringValue == "image")
        let source = imageBlock?["source"]?.objectValue
        #expect(source?["type"]?.stringValue == "base64")
        #expect(source?["media_type"]?.stringValue == "image/png")
        #expect(source?["data"]?.stringValue == "abc")
    }

    @Test("assistant tool calls become tool_use content blocks")
    func assistantToolCalls() {
        let call = LLMToolCall(id: "call_1", name: "lookup", arguments: ["q": "swift"])
        let adapted = AnthropicMessageAdapter.adapt([.assistant(toolCalls: [call])])
        guard case .array(let blocks) = adapted.messages.first?.objectValue?["content"] ?? .null
        else {
            Issue.record("expected content blocks array")
            return
        }
        let toolBlock = blocks.first { block in
            block.objectValue?["type"]?.stringValue == "tool_use"
        }
        #expect(toolBlock?.objectValue?["id"]?.stringValue == "call_1")
        #expect(toolBlock?.objectValue?["name"]?.stringValue == "lookup")
        let input = toolBlock?.objectValue?["input"]?.objectValue
        #expect(input?["q"]?.stringValue == "swift")
    }

    @Test("tool result messages become role=user with tool_result block")
    func toolResultRewriting() {
        let adapted = AnthropicMessageAdapter.adapt([
            .tool(callId: "call_1", content: "the answer is 42")
        ])
        let first = adapted.messages.first?.objectValue
        #expect(first?["role"]?.stringValue == "user")
        guard case .array(let blocks) = first?["content"] ?? .null else {
            Issue.record("expected content blocks array")
            return
        }
        let toolResult = blocks.first?.objectValue
        #expect(toolResult?["type"]?.stringValue == "tool_result")
        #expect(toolResult?["tool_use_id"]?.stringValue == "call_1")
        #expect(toolResult?["content"]?.stringValue == "the answer is 42")
    }

    @Test("missing system messages produce nil top-level system")
    func noSystemMessages() {
        let adapted = AnthropicMessageAdapter.adapt([.user("hi")])
        #expect(adapted.system == nil)
    }
}
