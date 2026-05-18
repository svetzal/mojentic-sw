import Foundation
import Testing

@testable import Mojentic

private func makeSandbox() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mojentic-sandbox-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("FilesystemGateway and file tools")
struct FileToolsTests {
    @Test("rejects paths that escape the sandbox via ..")
    func sandboxEscape() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemGateway(rootURL: root)
        do {
            _ = try fs.resolve("../escape.txt")
            Issue.record("expected sandbox escape to throw")
        } catch let error as MojenticError {
            if case .invalidArgument = error { return }
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("write/read/list/delete round trip succeeds")
    func crudRoundTrip() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemGateway(rootURL: root)

        let writer = WriteFileTool(fs: fs)
        _ = try await writer.execute(
            arguments: ["path": "notes/hello.txt", "content": "hi from mojentic"]
        )

        let lister = ListAllFilesTool(fs: fs)
        let listed = try await lister.execute(arguments: ["path": "."])
        if case .array(let items) = listed {
            #expect(items.contains(where: { $0.stringValue == "notes/hello.txt" }))
        } else {
            Issue.record("expected list result")
        }

        let reader = ReadFileTool(fs: fs)
        let content = try await reader.execute(arguments: ["path": "notes/hello.txt"])
        #expect(content.stringValue == "hi from mojentic")

        let exists = FileExistsTool(fs: fs)
        let existsResult = try await exists.execute(arguments: ["path": "notes/hello.txt"])
        #expect(existsResult.objectValue?["exists"] == .bool(true))

        let mover = MoveFileTool(fs: fs)
        _ = try await mover.execute(
            arguments: ["from": "notes/hello.txt", "to": "notes/renamed.txt"]
        )

        let deleter = DeleteFileTool(fs: fs)
        _ = try await deleter.execute(arguments: ["path": "notes/renamed.txt"])
        let after = try await exists.execute(arguments: ["path": "notes/renamed.txt"])
        #expect(after.objectValue?["exists"] == .bool(false))
    }

    @Test("createDirectory + ListFilesTool returns the directory contents")
    func listFiles() async throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemGateway(rootURL: root)
        let mkdir = CreateDirectoryTool(fs: fs)
        _ = try await mkdir.execute(arguments: ["path": "subdir"])
        let writer = WriteFileTool(fs: fs)
        _ = try await writer.execute(arguments: ["path": "subdir/a.txt", "content": "a"])
        _ = try await writer.execute(arguments: ["path": "subdir/b.txt", "content": "b"])
        let lister = ListFilesTool(fs: fs)
        let result = try await lister.execute(arguments: ["path": "subdir"])
        guard case .array(let items) = result else {
            Issue.record("expected list")
            return
        }
        let names = items.compactMap(\.stringValue)
        #expect(names == ["a.txt", "b.txt"])
    }
}
