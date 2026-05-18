import Foundation
import Mojentic

/// Wire CurrentDateTimeTool into a realtime session and watch the
/// tool-call lifecycle events fire when the model asks for the time.
@main
struct RealtimeToolCall {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let broker = RealtimeVoiceBroker(gateway: OpenAIRealtimeGateway())
        do {
            let session = try await broker.startSession(
                RealtimeSessionConfig(
                    model: "gpt-4o-realtime-preview",
                    apiKey: key,
                    tools: [CurrentDateTimeTool()],
                    instructions: "When the user asks the time, call the get_current_datetime tool."
                )
            )
            try await session.send(text: "What time is it right now?")
            for try await event in session.events() {
                switch event {
                case .toolCallDispatched(_, let name, _):
                    print("tool dispatched: \(name)")
                case .toolCallResult(_, _, let result):
                    print("tool result: \(result)")
                case .responseDone:
                    await session.close()
                    return
                case .sessionClosed:
                    return
                default:
                    continue
                }
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
