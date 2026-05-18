import Foundation

/// Returns the current local date and time as ISO-8601 with timezone offset.
///
/// Reference implementation of an `LLMTool` that lets models read the
/// current wall clock. Injectable clock + timezone for deterministic tests.
public struct CurrentDateTimeTool: LLMTool {
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    /// Create the tool, optionally injecting a clock and timezone for tests.
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.now = now
        self.timeZone = timeZone
    }

    /// Descriptor surfaced to the LLM for this tool.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "get_current_datetime",
            description:
                "Get the current local date and time as ISO-8601 with timezone offset.",
            parameters: [
                "type": "object",
                "properties": [:],
                "required": [],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool, returning the current local datetime.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        let current = now()
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        let iso = formatter.string(from: current)
        return [
            "current_datetime": .string(iso),
            "timestamp": .number(current.timeIntervalSince1970),
            "timezone": .string(timeZone.identifier),
        ]
    }
}
