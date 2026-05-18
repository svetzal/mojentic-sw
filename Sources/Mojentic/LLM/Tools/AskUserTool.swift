import Foundation

/// Ask the end user a question and return their typed answer.
///
/// Useful for interactive agents that need clarifying input mid-conversation.
/// I/O is funnelled through an ``IOGateway`` so tests can substitute a
/// scripted gateway.
public struct AskUserTool: LLMTool {
    private let io: any IOGateway

    /// Create the tool bound to an `IOGateway`.
    public init(io: any IOGateway = StdIOGateway()) {
        self.io = io
    }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "ask_user",
            description: "Ask the end user a question and return the line they reply with.",
            parameters: [
                "type": "object",
                "properties": ["question": ["type": "string"]],
                "required": ["question"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let question = arguments.objectValue?["question"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "ask_user requires 'question'")
        }
        let answer = await io.readLine(prompt: question + " ") ?? ""
        return ["answer": .string(answer)]
    }
}
