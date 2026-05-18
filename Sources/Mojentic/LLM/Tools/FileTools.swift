import Foundation

/// Sandbox-rooted filesystem gateway shared by the file-tool cluster.
///
/// All paths supplied by tools are resolved relative to `rootURL`. Any path
/// that resolves outside that root (via `..` segments or absolute paths) is
/// rejected with ``MojenticError/invalidArgument(message:)`` — the sandbox
/// is a security boundary.
public struct FilesystemGateway: Sendable {
    /// Sandbox root every relative path resolves under.
    public let rootURL: URL

    /// Create a gateway rooted at `rootURL`.
    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// Foundation file manager used for I/O.
    ///
    /// Routed through `FileManager.default`, which Foundation documents as
    /// thread-safe for the operations this gateway performs.
    private var manager: FileManager { .default }

    /// Resolve `relativePath` against the sandbox root.
    ///
    /// Throws when the resolved path escapes the sandbox.
    public func resolve(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = rootURL.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw MojenticError.invalidArgument(
                message: "Path '\(relativePath)' escapes the sandbox"
            )
        }
        return candidate
    }

    /// List entries (files + directories) directly under `relativePath`.
    public func list(_ relativePath: String) throws -> [String] {
        let url = try resolve(relativePath)
        let entries = try manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
        return entries.map(\.lastPathComponent).sorted()
    }

    /// Walk `relativePath` recursively, returning every regular file path
    /// relative to the sandbox root.
    public func listAll(_ relativePath: String) throws -> [String] {
        let url = try resolve(relativePath)
        let rootPrefix = rootURL.path + "/"
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: nil)
        else { return [] }
        var results: [String] = []
        for case let entry as URL in enumerator {
            var isDir: ObjCBool = false
            guard manager.fileExists(atPath: entry.path, isDirectory: &isDir), !isDir.boolValue
            else { continue }
            let standardised = entry.standardizedFileURL.path
            if standardised.hasPrefix(rootPrefix) {
                results.append(String(standardised.dropFirst(rootPrefix.count)))
            } else if standardised == rootURL.path {
                results.append("")
            }
        }
        return results.sorted()
    }

    /// Read a UTF-8 text file at `relativePath`.
    public func read(_ relativePath: String) throws -> String {
        let url = try resolve(relativePath)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MojenticError.invalidArgument(
                message: "File '\(relativePath)' is not valid UTF-8"
            )
        }
        return text
    }

    /// Write `content` to `relativePath`, creating parent directories as needed.
    public func write(_ relativePath: String, content: String) throws {
        let url = try resolve(relativePath)
        let parent = url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let data = content.data(using: .utf8) else {
            throw MojenticError.invalidArgument(
                message: "Content for '\(relativePath)' is not encodable as UTF-8"
            )
        }
        try data.write(to: url, options: .atomic)
    }

    /// Delete the file or directory at `relativePath`.
    public func delete(_ relativePath: String) throws {
        let url = try resolve(relativePath)
        try manager.removeItem(at: url)
    }

    /// Move/rename `from` to `to` (both relative to the sandbox root).
    public func move(from: String, to destination: String) throws {
        let fromURL = try resolve(from)
        let toURL = try resolve(destination)
        let parent = toURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        try manager.moveItem(at: fromURL, to: toURL)
    }

    /// Create the directory at `relativePath` (including intermediates).
    public func createDirectory(_ relativePath: String) throws {
        let url = try resolve(relativePath)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Whether anything exists at `relativePath`.
    public func exists(_ relativePath: String) throws -> Bool {
        let url = try resolve(relativePath)
        return manager.fileExists(atPath: url.path)
    }
}

// MARK: - Tools

/// List the non-recursive contents of a directory inside the sandbox.
public struct ListFilesTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "list_files",
            description: "List files and directories directly under the given sandbox path.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        let path = arguments.objectValue?["path"]?.stringValue ?? "."
        let entries = try fs.list(path)
        return .array(entries.map(JSONValue.string))
    }
}

/// Recursively list every file under a sandbox path.
public struct ListAllFilesTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "list_all_files",
            description: "Recursively list every file under the given sandbox path.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        let path = arguments.objectValue?["path"]?.stringValue ?? "."
        let entries = try fs.listAll(path)
        return .array(entries.map(JSONValue.string))
    }
}

/// Read a UTF-8 text file from the sandbox.
public struct ReadFileTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "read_file",
            description: "Read a UTF-8 text file from the sandbox.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let path = arguments.objectValue?["path"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "read_file requires 'path'")
        }
        let content = try fs.read(path)
        return .string(content)
    }
}

/// Write a UTF-8 text file into the sandbox.
public struct WriteFileTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "write_file",
            description: "Write UTF-8 content to a file in the sandbox, creating parents as needed.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "content": ["type": "string"],
                ],
                "required": ["path", "content"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let path = arguments.objectValue?["path"]?.stringValue,
            let content = arguments.objectValue?["content"]?.stringValue
        else {
            throw MojenticError.invalidArgument(message: "write_file requires 'path' and 'content'")
        }
        try fs.write(path, content: content)
        return ["status": "ok", "path": .string(path)]
    }
}

/// Delete a file or directory inside the sandbox.
public struct DeleteFileTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "delete_file",
            description: "Delete a file or directory inside the sandbox.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let path = arguments.objectValue?["path"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "delete_file requires 'path'")
        }
        try fs.delete(path)
        return ["status": "ok"]
    }
}

/// Move or rename a file/directory inside the sandbox.
public struct MoveFileTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "move_file",
            description: "Move or rename a file/directory inside the sandbox.",
            parameters: [
                "type": "object",
                "properties": [
                    "from": ["type": "string"],
                    "to": ["type": "string"],
                ],
                "required": ["from", "to"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let from = arguments.objectValue?["from"]?.stringValue,
            let dest = arguments.objectValue?["to"]?.stringValue
        else {
            throw MojenticError.invalidArgument(message: "move_file requires 'from' and 'to'")
        }
        try fs.move(from: from, to: dest)
        return ["status": "ok"]
    }
}

/// Create a directory inside the sandbox (and any missing parents).
public struct CreateDirectoryTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "create_directory",
            description: "Create a directory inside the sandbox (and any missing parents).",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let path = arguments.objectValue?["path"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "create_directory requires 'path'")
        }
        try fs.createDirectory(path)
        return ["status": "ok"]
    }
}

/// Check whether something exists at a sandbox path.
public struct FileExistsTool: LLMTool {
    private let fs: FilesystemGateway

    /// Create the tool bound to a sandbox gateway.
    public init(fs: FilesystemGateway) { self.fs = fs }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "file_exists",
            description: "Check whether anything exists at a sandbox path.",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let path = arguments.objectValue?["path"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "file_exists requires 'path'")
        }
        let exists = try fs.exists(path)
        return ["exists": .bool(exists)]
    }
}

/// Convenience bundle of every file tool sharing one ``FilesystemGateway``.
public enum FileTools {
    /// Return all eight file tools wired to the supplied gateway.
    public static func bundle(for fs: FilesystemGateway) -> [any LLMTool] {
        [
            ListFilesTool(fs: fs),
            ListAllFilesTool(fs: fs),
            ReadFileTool(fs: fs),
            WriteFileTool(fs: fs),
            DeleteFileTool(fs: fs),
            MoveFileTool(fs: fs),
            CreateDirectoryTool(fs: fs),
            FileExistsTool(fs: fs),
        ]
    }
}
