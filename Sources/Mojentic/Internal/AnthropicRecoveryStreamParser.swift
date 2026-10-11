import Foundation

/// Messages SSE state owned by one recovery attempt, independent of legacy parsing.
struct AnthropicRecoveryStreamParser {
    var observed = RecoverySemanticProgress()
    private var finishReason: String?
    private var usage: Usage?
    private var providerModel: String?
    private var metadata: [String: JSONValue]?
    var evidence: CompletionEvidence {
        CompletionEvidence(
            finishReason: finishReason, usage: usage, providerModel: providerModel, metadata: metadata,
        )
    }

    var terminal = false
    private var started = false
    private var stopped = false
    private var blocks: [Int: Block] = [:]

    private struct Block {
        let type: String
        var id: String?
        var name: String?
        var input: JSONValue?
        var arguments = ""
        var closed = false
    }

    mutating func consume(
        _ object: [String: JSONValue], singleTurn: Bool,
    ) throws -> [RecoveryGatewayStreamEvent] {
        guard let type = object["type"]?.stringValue else { throw malformed() }
        switch type {
        case "ping": return []
        case "message_start":
            guard
                !started,
                let message = object["message"]?.objectValue,
                message["role"]?.stringValue == "assistant"
            else { throw malformed() }
            started = true
            providerModel = message["model"]?.stringValue
            metadata = message["id"].map { ["id": $0] }
            try updateUsage(message["usage"])
            return [.metrics(evidence)]
        case "content_block_start": return try startBlock(object, singleTurn: singleTurn)
        case "content_block_delta": return try delta(object)
        case "content_block_stop":
            guard let index = object["index"]?.intValue, var block = blocks[index], !block.closed else {
                throw malformed()
            }
            if block.type == "tool_use" {
                if !block.arguments.isEmpty {
                    block.input = try JSONDecoder().decode(JSONValue.self, from: Data(block.arguments.utf8))
                }
                guard block.input?.objectValue != nil else { throw malformed() }
                observed.completedToolCalls += 1
            }
            block.closed = true
            blocks[index] = block
            return []
        case "message_delta":
            guard
                started,
                !stopped,
                blocks.values.allSatisfy(\.closed),
                let reason = object["delta"]?.objectValue?["stop_reason"]?.stringValue
            else { throw malformed() }
            finishReason = reason
            stopped = true
            try updateUsage(object["usage"])
            return [.metrics(evidence)]
        case "message_stop":
            guard stopped else { throw malformed() }
            terminal = true
            guard finishReason == "end_turn" || finishReason == "stop_sequence" || finishReason == "tool_use"
            else {
                throw MojenticError.incompleteCompletion(evidence)
            }
            return try blocks.keys.sorted().compactMap { index in
                guard let block = blocks[index], block.type == "tool_use" else { return nil }
                guard let name = block.name, let input = block.input else { throw malformed() }
                return .toolCallRequest(LLMToolCall(id: block.id, name: name, arguments: input))
            }
        default: throw malformed()
        }
    }

    private mutating func startBlock(
        _ object: [String: JSONValue], singleTurn: Bool,
    ) throws -> [RecoveryGatewayStreamEvent] {
        guard
            started,
            !stopped,
            let index = object["index"]?.intValue,
            index >= 0,
            blocks[index] == nil,
            let block = object["content_block"]?.objectValue,
            let kind = block["type"]?.stringValue,
            ["text", "thinking", "redacted_thinking", "tool_use"].contains(kind)
        else { throw malformed() }
        blocks[index] = Block(
            type: kind,
            id: block["id"]?.stringValue,
            name: block["name"]?.stringValue,
            input: block["input"],
        )
        switch kind {
        case "text":
            guard let text = block["text"]?.stringValue else { throw malformed() }
            return observeText(text, thinking: false)
        case "thinking":
            guard let text = block["thinking"]?.stringValue else { throw malformed() }
            return observeText(text, thinking: true)
        case "tool_use":
            observed.toolFragments += 1
            guard
                let id = block["id"]?.stringValue,
                !id.isEmpty,
                let name = block["name"]?.stringValue,
                !name.isEmpty,
                block["input"]?.objectValue != nil
            else { throw malformed() }
            if singleTurn {
                throw MojenticError.unexpectedToolCalls
            }
            return []
        default: return []
        }
    }

    private mutating func delta(_ object: [String: JSONValue]) throws -> [RecoveryGatewayStreamEvent] {
        guard
            !stopped,
            let index = object["index"]?.intValue,
            var block = blocks[index],
            !block.closed,
            let delta = object["delta"]?.objectValue
        else { throw malformed() }
        switch delta["type"]?.stringValue {
        case "text_delta":
            guard block.type == "text", let text = delta["text"]?.stringValue else { throw malformed() }
            return observeText(text, thinking: false)
        case "thinking_delta":
            guard block.type == "thinking", let text = delta["thinking"]?.stringValue else {
                throw malformed()
            }
            return observeText(text, thinking: true)
        case "signature_delta":
            guard block.type == "thinking", delta["signature"]?.stringValue != nil else { throw malformed() }
            return []
        case "input_json_delta":
            guard block.type == "tool_use", let fragment = delta["partial_json"]?.stringValue else {
                throw malformed()
            }
            observed.toolFragments += 1
            block.arguments += fragment
            blocks[index] = block
            return []
        default: throw malformed()
        }
    }

    private mutating func observeText(_ text: String, thinking: Bool) -> [RecoveryGatewayStreamEvent] {
        guard !text.isEmpty else { return [] }
        if thinking {
            observed.reasoningBytes += text.utf8.count
        } else {
            observed.contentBytes += text.utf8.count
        }
        return [thinking ? .thinkingDelta(text) : .textDelta(text)]
    }

    private mutating func updateUsage(_ value: JSONValue?) throws {
        guard let value else { return }
        guard let fields = value.objectValue else { throw malformed() }
        let input = fields["input_tokens"]?.intValue ?? evidence.usage?.promptTokens
        let output = fields["output_tokens"]?.intValue ?? evidence.usage?.completionTokens
        for key in ["input_tokens", "output_tokens"] {
            if let count = fields[key] {
                guard let number = count.intValue, number >= 0 else { throw malformed() }
            }
        }
        guard !(input ?? 0).addingReportingOverflow(output ?? 0).overflow else { throw malformed() }
        usage = Usage(
            promptTokens: input,
            completionTokens: output,
            totalTokens: input.flatMap { prompt in output.map { prompt + $0 } },
        )
    }

    private func malformed() -> MojenticError {
        .invalidStreamEvent(message: "Malformed Anthropic Messages frame")
    }
}
