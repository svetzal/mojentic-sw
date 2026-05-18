import Foundation
import Mojentic

/// Demo of the AskUser tool requesting a clarifying answer from stdin.
@main
struct AskUserExample {
    static func main() async {
        let tool = AskUserTool()
        do {
            let result = try await tool.execute(arguments: ["question": "What is your name?"])
            print("Got: \(result.objectValue?["answer"]?.stringValue ?? "")")
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
