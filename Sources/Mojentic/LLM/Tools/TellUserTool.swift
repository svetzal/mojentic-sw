import Foundation

/// Surface a message to the end user out-of-band from the assistant turn.
///
/// I/O goes through the injected ``IOGateway`` so tests can substitute a
/// scripted gateway.
public struct TellUserTool: LLMTool {
    private let io: any IOGateway

    /// Create the tool bound to an `IOGateway`.
    public init(io: any IOGateway = StdIOGateway()) {
        self.io = io
    }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "tell_user",
            description: "Surface a message to the end user out-of-band from the assistant turn.",
            parameters: [
                "type": "object",
                "properties": ["message": ["type": "string"]],
                "required": ["message"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let message = arguments.objectValue?["message"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "tell_user requires 'message'")
        }
        await io.print(message)
        return ["delivered": .bool(true)]
    }
}
