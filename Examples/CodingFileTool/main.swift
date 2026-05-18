import Foundation
import Mojentic

/// Use the broker + file tools to read a source file and ask the model to
/// summarise it in plain English.
@main
struct CodingFileTool {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("Usage: CodingFileTool <sandbox-root> <relative-file-path>")
            exit(1)
        }
        let root = URL(fileURLWithPath: arguments[1])
        let path = arguments[2]
        let fs = FilesystemGateway(rootURL: root)
        let tools = FileTools.bundle(for: fs)
        let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
        do {
            let response = try await broker.complete(
                model: "gpt-4o-mini",
                messages: [
                    .system(
                        "You are a code-reading assistant. Use the available file tools to read the file the user names, "
                        + "then summarise what it does in 3 sentences."
                    ),
                    .user("Summarise the file at '\(path)' relative to the sandbox."),
                ],
                tools: tools
            )
            print(response.content)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
