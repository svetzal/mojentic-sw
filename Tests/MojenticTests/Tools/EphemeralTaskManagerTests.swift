import Foundation
import Testing

@testable import Mojentic

@Suite("EphemeralTaskManager")
struct EphemeralTaskManagerTests {
    @Test("append + list returns the new task")
    func appendAndList() async throws {
        let manager = EphemeralTaskManager()
        let appender = AppendTaskTool(manager: manager)
        let added = try await appender.execute(arguments: ["title": "buy milk"])
        let id = added.objectValue?["id"]?.stringValue
        #expect(id != nil)
        let lister = ListTasksTool(manager: manager)
        let listed = try await lister.execute(arguments: .object([:]))
        if case .array(let items) = listed {
            #expect(items.count == 1)
            #expect(items.first?.objectValue?["title"]?.stringValue == "buy milk")
        } else {
            Issue.record("expected array")
        }
    }

    @Test("complete and remove update the underlying list")
    func completeAndRemove() async throws {
        let manager = EphemeralTaskManager()
        let appender = AppendTaskTool(manager: manager)
        let added = try await appender.execute(arguments: ["title": "task"])
        guard let id = added.objectValue?["id"]?.stringValue else {
            Issue.record("missing id")
            return
        }
        let complete = CompleteTaskTool(manager: manager)
        let completion = try await complete.execute(arguments: ["id": .string(id)])
        #expect(completion.objectValue?["updated"] == .bool(true))

        let remove = RemoveTaskTool(manager: manager)
        let removal = try await remove.execute(arguments: ["id": .string(id)])
        #expect(removal.objectValue?["removed"] == .bool(true))

        let list = ListTasksTool(manager: manager)
        let listed = try await list.execute(arguments: .object([:]))
        if case .array(let items) = listed {
            #expect(items.isEmpty)
        } else {
            Issue.record("expected array")
        }
    }

    @Test("clear empties the entire list")
    func clear() async throws {
        let manager = EphemeralTaskManager()
        let append = AppendTaskTool(manager: manager)
        _ = try await append.execute(arguments: ["title": "one"])
        _ = try await append.execute(arguments: ["title": "two"])
        let clear = ClearTasksTool(manager: manager)
        _ = try await clear.execute(arguments: .object([:]))
        let listed = await manager.list()
        #expect(listed.isEmpty)
    }
}
