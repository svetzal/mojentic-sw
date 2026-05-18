import Foundation
import Testing

@testable import Mojentic

@Suite("LLMMessage composer factories")
struct MessagesTests {
    @Test("system() builds a system message")
    func systemMessage() {
        let message = LLMMessage.system("be brief")
        #expect(message.role == .system)
        #expect(message.content == "be brief")
        #expect(message.toolCalls == nil)
        #expect(message.toolCallId == nil)
    }

    @Test("user() builds a user message")
    func userMessage() {
        let message = LLMMessage.user("hi")
        #expect(message.role == .user)
        #expect(message.content == "hi")
    }

    @Test("assistant() can carry tool calls without content")
    func assistantWithToolCalls() {
        let call = LLMToolCall(id: "1", name: "echo", arguments: ["text": "hi"])
        let message = LLMMessage.assistant(toolCalls: [call])
        #expect(message.role == .assistant)
        #expect(message.content == nil)
        #expect(message.toolCalls?.count == 1)
        #expect(message.toolCalls?.first?.name == "echo")
    }

    @Test("tool() captures the call id and content")
    func toolMessage() {
        let message = LLMMessage.tool(callId: "abc", content: "{\"ok\":true}")
        #expect(message.role == .tool)
        #expect(message.toolCallId == "abc")
        #expect(message.content == "{\"ok\":true}")
    }

    @Test("messages round-trip via Codable")
    func codableRoundTrip() throws {
        let original = LLMMessage(
            role: .assistant,
            content: "ok",
            toolCalls: [LLMToolCall(id: "x", name: "y", arguments: ["a": 1])]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMMessage.self, from: data)
        #expect(decoded == original)
    }
}
