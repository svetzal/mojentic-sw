import Foundation
import Testing

@testable import Mojentic

private func openAIChunk(_ choices: String, extra: String = "") -> String {
    #"data: {"id":"chatcmpl-9","created":1700000000,"model":"gpt-4o-2024-08-06","#
        + extra + #""choices":"# + choices + "}"
}

private let openAIUsageChunk = openAIChunk(
    "[]",
    extra: #""usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7},"#
)

private let openAIMetadata: [String: JSONValue] = [
    "id": "chatcmpl-9",
    "created": .integer(1_700_000_000),
]

private func openAIEvidence(_ reason: String) -> CompletionEvidence {
    CompletionEvidence(
        finishReason: reason,
        usage: Usage(promptTokens: 5, completionTokens: 2, totalTokens: 7),
        providerModel: "gpt-4o-2024-08-06",
        metadata: openAIMetadata
    )
}

@Suite("OpenAI completion event parser")
struct OpenAICompletionEventParserTests {
    private func parse(_ lines: [String]) -> [SeenEvent] {
        MojenticTests.parse(lines, with: OpenAICompletionEventParser())
    }

    @Test("content then stop then DONE yields content events then completed")
    func completes() {
        let seen = parse([
            ": keep-alive",
            openAIChunk(#"[{"index":0,"delta":{"role":"assistant","content":"Hel"},"finish_reason":null}]"#),
            "",
            openAIChunk(#"[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]"#),
            openAIChunk(#"[{"index":0,"delta":{},"finish_reason":"stop"}]"#),
            openAIUsageChunk,
            "data: [DONE]",
        ])
        #expect(seen == [.content("Hel"), .content("lo"), .completed(openAIEvidence("stop"))])
    }

    @Test("DONE with finish reason length is an incomplete completion carrying evidence")
    func length() {
        let seen = parse([
            openAIChunk(#"[{"index":0,"delta":{"content":"Partial"},"finish_reason":null}]"#),
            openAIChunk(#"[{"index":0,"delta":{},"finish_reason":"length"}]"#),
            openAIUsageChunk,
            "data: [DONE]",
        ])
        #expect(seen == [.content("Partial"), .incompleteCompletion(openAIEvidence("length"))])
    }

    @Test("stop without DONE produces no terminal event and keeps partial evidence")
    func stopWithoutDone() {
        var parser = OpenAICompletionEventParser()
        #expect(parser.partialEvidence == nil)
        _ = parser.consume(line: openAIChunk(#"[{"index":0,"delta":{},"finish_reason":"stop"}]"#))
        _ = parser.consume(line: openAIUsageChunk)
        #expect(!parser.isTerminal)
        #expect(parser.partialEvidence == openAIEvidence("stop"))
    }

    @Test("a tool-call delta is an unexpected-tool-calls error")
    func toolCalls() {
        let seen = parse([
            openAIChunk(
                #"[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","#
                    + #""function":{"name":"f","arguments":""}}]},"finish_reason":null}]"#
            ),
            "data: [DONE]",
        ])
        #expect(seen == [.unexpectedToolCalls])
    }

    @Test("a provider error frame is a provider error")
    func providerError() {
        let seen = parse([#"data: {"error":{"message":"overloaded","type":"server_error"}}"#])
        #expect(
            seen == [.providerError(status: nil, detail: ["message": "overloaded", "type": "server_error"])])
    }

    @Test("a malformed frame is an invalid-stream-event error")
    func malformed() {
        #expect(parse(["data: {not json"]) == [.invalidStreamEvent])
        #expect(parse([#"data: {"object":"chat.completion.chunk"}"#]) == [.invalidStreamEvent])
        #expect(parse([openAIChunk(#"[{"index":0,"delta":{"content":42}}]"#)]) == [.invalidStreamEvent])
    }

    @Test("nothing is produced after a terminal event")
    func nothingAfterTerminal() {
        var parser = OpenAICompletionEventParser()
        _ = parser.consume(line: "data: [DONE]")
        #expect(parser.consume(line: openAIChunk(#"[{"index":0,"delta":{"content":"late"}}]"#)).isEmpty)
    }
}

private let ollamaFinal =
    #"{"model":"qwen3:8b","created_at":"2026-09-24T00:00:00Z","#
    + #""message":{"role":"assistant","content":""},"done":true,"done_reason":"%@","#
    + #""total_duration":100,"load_duration":10,"prompt_eval_count":5,"#
    + #""prompt_eval_duration":20,"eval_count":3,"eval_duration":30}"#

private func ollamaFinalFrame(_ reason: String) -> String {
    ollamaFinal.replacingOccurrences(of: "%@", with: reason)
}

private func ollamaEvidence(_ reason: String) -> CompletionEvidence {
    CompletionEvidence(
        finishReason: reason,
        usage: Usage(promptTokens: 5, completionTokens: 3, totalTokens: 8),
        providerModel: "qwen3:8b",
        metadata: [
            "created_at": "2026-09-24T00:00:00Z",
            "total_duration": .integer(100),
            "load_duration": .integer(10),
            "prompt_eval_duration": .integer(20),
            "eval_duration": .integer(30),
        ]
    )
}

private func ollamaContent(_ text: String) -> String {
    #"{"model":"qwen3:8b","message":{"role":"assistant","content":"# + "\"\(text)\"" + #"},"done":false}"#
}

@Suite("Ollama completion event parser")
struct OllamaCompletionEventParserTests {
    private func parse(_ lines: [String]) -> [SeenEvent] {
        MojenticTests.parse(lines, with: OllamaCompletionEventParser())
    }

    @Test("content then a done frame with stop yields content events then completed")
    func completes() {
        let seen = parse([ollamaContent("Hel"), "", ollamaContent("lo"), ollamaFinalFrame("stop")])
        #expect(seen == [.content("Hel"), .content("lo"), .completed(ollamaEvidence("stop"))])
    }

    @Test("a done frame with done_reason length is an incomplete completion carrying evidence")
    func length() {
        let seen = parse([ollamaContent("Partial"), ollamaFinalFrame("length")])
        #expect(seen == [.content("Partial"), .incompleteCompletion(ollamaEvidence("length"))])
    }

    @Test("frames without done produce no terminal event and keep the reported model")
    func withoutDone() {
        var parser = OllamaCompletionEventParser()
        #expect(parser.partialEvidence == nil)
        _ = parser.consume(line: ollamaContent("Hi"))
        #expect(!parser.isTerminal)
        #expect(parser.partialEvidence == CompletionEvidence(providerModel: "qwen3:8b"))
    }

    @Test("a done frame without done_reason is an incomplete completion")
    func withoutDoneReason() {
        let seen = parse([#"{"model":"qwen3:8b","message":{"content":"Hi"},"done":true}"#])
        #expect(
            seen == [.content("Hi"), .incompleteCompletion(CompletionEvidence(providerModel: "qwen3:8b"))])
    }

    @Test("a tool call in the stream is an unexpected-tool-calls error")
    func toolCalls() {
        let seen = parse([
            #"{"message":{"role":"assistant","content":"","#
                + #""tool_calls":[{"function":{"name":"f","arguments":{}}}]},"done":false}"#,
            ollamaFinalFrame("stop"),
        ])
        #expect(seen == [.unexpectedToolCalls])
    }

    @Test("a provider error frame is a provider error")
    func providerError() {
        #expect(
            parse([#"{"error":"model not found"}"#]) == [
                .providerError(status: nil, detail: "model not found")
            ])
    }

    @Test("a malformed frame is an invalid-stream-event error")
    func malformed() {
        #expect(parse(["{not json"]) == [.invalidStreamEvent])
        #expect(parse([#"{"message":{"content":42},"done":false}"#]) == [.invalidStreamEvent])
    }
}
