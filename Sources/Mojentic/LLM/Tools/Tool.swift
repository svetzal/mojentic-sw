/// Describes a tool to the LLM.
///
/// Mirrors the `function` half of an OpenAI/Ollama tool descriptor.
public struct ToolDescriptor: Sendable, Codable, Hashable {
    /// Tool name.
    ///
    /// Must be stable — the LLM will refer back to it.
    public let name: String

    /// Human-readable description shown to the model.
    ///
    /// Be specific about when to call the tool.
    public let description: String

    /// JSON Schema describing the tool's argument shape.
    public let parameters: JSONValue

    /// Create a descriptor surfaced to the model.
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Protocol every tool surfaced to an LLM must conform to.
///
/// Conforming types are typically value types or actors that wrap an
/// external capability. Implementations should honour `Task.checkCancellation()`
/// before and during any long-running work.
public protocol LLMTool: Sendable {
    /// Static description of the tool surfaced to the LLM.
    var descriptor: ToolDescriptor { get }

    /// Execute the tool against the supplied JSON-shaped arguments and
    /// return a JSON-shaped result.
    func execute(arguments: JSONValue) async throws -> JSONValue
}

extension LLMTool {
    /// Tool name (delegates to `descriptor.name`).
    public var name: String { descriptor.name }

    /// Returns `true` when this tool answers to the given name.
    public func matches(_ name: String) -> Bool { self.name == name }
}
