import Foundation
import Mojentic

/// List a directory and read one of the files via the file tools.
@main
struct FileToolExample {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("Usage: FileTool <sandbox-root> [path-to-read]")
            exit(1)
        }
        let root = URL(fileURLWithPath: arguments[1])
        let fs = FilesystemGateway(rootURL: root)
        let lister = ListFilesTool(fs: fs)
        do {
            let entries = try await lister.execute(arguments: ["path": "."])
            print("entries: \(entries)")
            if arguments.count >= 3 {
                let reader = ReadFileTool(fs: fs)
                let content = try await reader.execute(arguments: ["path": .string(arguments[2])])
                print("--- content of \(arguments[2]) ---")
                if let text = content.stringValue {
                    print(text)
                }
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
