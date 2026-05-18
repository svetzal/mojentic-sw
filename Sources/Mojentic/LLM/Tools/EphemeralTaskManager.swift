import Foundation

/// Status of a managed task.
public enum EphemeralTaskStatus: String, Sendable, Codable, Hashable {
    /// Task has been added but not yet started.
    case pending
    /// Task has been started but is not yet complete.
    case inProgress = "in_progress"
    /// Task has been completed.
    case complete
}

/// Single task tracked by ``EphemeralTaskManager``.
public struct EphemeralTask: Sendable, Codable, Hashable, Identifiable {
    /// Stable identifier (UUID string for portability).
    public let id: String
    /// Short human-readable title.
    public let title: String
    /// Current status.
    public var status: EphemeralTaskStatus

    /// Create a task.
    public init(id: String = UUID().uuidString, title: String, status: EphemeralTaskStatus = .pending) {
        self.id = id
        self.title = title
        self.status = status
    }
}

/// Shared in-memory task list for a cluster of tools.
///
/// `actor` so concurrent tool dispatches against the same list don't race.
/// The cluster ships individual `LLMTool`s (``AppendTaskTool``,
/// ``ListTasksTool``, ``CompleteTaskTool``, ``RemoveTaskTool``,
/// ``ClearTasksTool``) bound to the same manager instance.
public actor EphemeralTaskManager {
    private var tasks: [EphemeralTask] = []

    /// Create an empty manager.
    public init() {}

    /// Append a task.
    public func append(title: String) -> EphemeralTask {
        let task = EphemeralTask(title: title)
        tasks.append(task)
        return task
    }

    /// Return a snapshot of the current task list.
    public func list() -> [EphemeralTask] { tasks }

    /// Mark a task as complete by id.
    public func complete(id: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].status = .complete
        return true
    }

    /// Remove a task by id.
    public func remove(id: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks.remove(at: index)
        return true
    }

    /// Empty the entire list.
    public func clear() { tasks.removeAll() }

    /// Return the bundled tool set bound to this manager.
    public nonisolated func toolBundle() -> [any LLMTool] {
        [
            AppendTaskTool(manager: self),
            ListTasksTool(manager: self),
            CompleteTaskTool(manager: self),
            RemoveTaskTool(manager: self),
            ClearTasksTool(manager: self),
        ]
    }
}

private func encode(_ task: EphemeralTask) -> JSONValue {
    [
        "id": .string(task.id),
        "title": .string(task.title),
        "status": .string(task.status.rawValue),
    ]
}

/// Append a task to the manager.
public struct AppendTaskTool: LLMTool {
    private let manager: EphemeralTaskManager

    /// Create the tool bound to a manager.
    public init(manager: EphemeralTaskManager) { self.manager = manager }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "append_task",
            description: "Append a new task to the in-memory task list.",
            parameters: [
                "type": "object",
                "properties": ["title": ["type": "string"]],
                "required": ["title"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let title = arguments.objectValue?["title"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "append_task requires 'title'")
        }
        let task = await manager.append(title: title)
        return encode(task)
    }
}

/// List all tasks currently tracked by the manager.
public struct ListTasksTool: LLMTool {
    private let manager: EphemeralTaskManager

    /// Create the tool bound to a manager.
    public init(manager: EphemeralTaskManager) { self.manager = manager }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "list_tasks",
            description: "List every task currently tracked by the in-memory task list.",
            parameters: [
                "type": "object",
                "properties": [:],
                "required": [],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments _: JSONValue) async throws -> JSONValue {
        let tasks = await manager.list()
        return .array(tasks.map(encode))
    }
}

/// Mark a task complete by id.
public struct CompleteTaskTool: LLMTool {
    private let manager: EphemeralTaskManager

    /// Create the tool bound to a manager.
    public init(manager: EphemeralTaskManager) { self.manager = manager }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "complete_task",
            description: "Mark a task complete by id.",
            parameters: [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let id = arguments.objectValue?["id"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "complete_task requires 'id'")
        }
        let updated = await manager.complete(id: id)
        return ["updated": .bool(updated)]
    }
}

/// Remove a task by id.
public struct RemoveTaskTool: LLMTool {
    private let manager: EphemeralTaskManager

    /// Create the tool bound to a manager.
    public init(manager: EphemeralTaskManager) { self.manager = manager }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "remove_task",
            description: "Remove a task by id.",
            parameters: [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let id = arguments.objectValue?["id"]?.stringValue else {
            throw MojenticError.invalidArgument(message: "remove_task requires 'id'")
        }
        let removed = await manager.remove(id: id)
        return ["removed": .bool(removed)]
    }
}

/// Empty the task list.
public struct ClearTasksTool: LLMTool {
    private let manager: EphemeralTaskManager

    /// Create the tool bound to a manager.
    public init(manager: EphemeralTaskManager) { self.manager = manager }

    /// Descriptor surfaced to the LLM.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "clear_tasks",
            description: "Empty the in-memory task list.",
            parameters: [
                "type": "object",
                "properties": [:],
                "required": [],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the tool.
    public func execute(arguments _: JSONValue) async throws -> JSONValue {
        await manager.clear()
        return ["cleared": .bool(true)]
    }
}
