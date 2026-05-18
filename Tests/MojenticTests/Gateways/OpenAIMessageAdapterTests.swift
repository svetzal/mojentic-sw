import Foundation
import Testing

@testable import Mojentic

@Suite("OpenAIMessageAdapter")
struct OpenAIMessageAdapterTests {
    @Test("system message becomes role=system + content string")
    func systemMessage() {
        let adapted = OpenAIMessageAdapter.adapt([.system("rules")])
        let first = adapted.first?.objectValue
        #expect(first?["role"]?.stringValue == "system")
        #expect(first?["content"]?.stringValue == "rules")
    }

    @Test("plain user message uses string content shape")
    func userPlain() {
        let adapted = OpenAIMessageAdapter.adapt([.user("hi")])
        let first = adapted.first?.objectValue
        #expect(first?["content"]?.stringValue == "hi")
    }

    @Test("multimodal user message becomes content parts array")
    func userMultimodal() {
        let image = ImageContent(base64: "abc", mimeType: "image/png")
        let adapted = OpenAIMessageAdapter.adapt([
            .user(text: "describe", images: [image])
        ])
        guard let parts = adapted.first?.objectValue?["content"], case .array(let array) = parts else {
            Issue.record("expected content parts array")
            return
        }
        #expect(array.count == 2)
        let imagePart = array.last?.objectValue
        #expect(imagePart?["type"]?.stringValue == "image_url")
        let url = imagePart?["image_url"]?.objectValue?["url"]?.stringValue
        #expect(url?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test("assistant tool calls include id and serialised arguments")
    func assistantToolCalls() {
        let call = LLMToolCall(id: "call_1", name: "echo", arguments: ["v": 1])
        let adapted = OpenAIMessageAdapter.adapt([.assistant(toolCalls: [call])])
        let calls = adapted.first?.objectValue?["tool_calls"]
        guard case .array(let array) = calls ?? .null else {
            Issue.record("expected tool_calls array")
            return
        }
        let first = array.first?.objectValue
        #expect(first?["id"]?.stringValue == "call_1")
        let function = first?["function"]?.objectValue
        #expect(function?["name"]?.stringValue == "echo")
        // arguments are serialised as a JSON string per OpenAI's contract.
        #expect(function?["arguments"]?.stringValue?.contains("\"v\"") == true)
    }

    @Test("tool message carries tool_call_id")
    func toolMessage() {
        let adapted = OpenAIMessageAdapter.adapt([.tool(callId: "call_1", content: "ok")])
        let first = adapted.first?.objectValue
        #expect(first?["role"]?.stringValue == "tool")
        #expect(first?["tool_call_id"]?.stringValue == "call_1")
    }
}
