import Foundation
import Mojentic

/// Demo of the TellUser tool surfacing a message out-of-band.
@main
struct TellUserExample {
    static func main() async {
        let tool = TellUserTool()
        do {
            _ = try await tool.execute(arguments: ["message": "Hello from the agent."])
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
