import Foundation
import Mojentic

/// Search the web for the user's query via Serper.dev.
///
/// Skips gracefully when SERPER_API_KEY is not configured — useful for CI
/// builds that exercise the binary without making outbound calls.
@main
struct WebSearchExample {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["SERPER_API_KEY"] else {
            print("SERPER_API_KEY not set — skipping web search example.")
            return
        }
        let arguments = CommandLine.arguments
        let query = arguments.count >= 2 ? arguments[1] : "Mojentic Swift"
        let tool = WebSearchTool(apiKey: key, maxResults: 5)
        do {
            let results = try await tool.execute(arguments: ["query": .string(query)])
            if case .array(let entries) = results {
                for entry in entries {
                    let title = entry.objectValue?["title"]?.stringValue ?? "(no title)"
                    let link = entry.objectValue?["link"]?.stringValue ?? "(no link)"
                    print("- \(title)\n  \(link)")
                }
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
