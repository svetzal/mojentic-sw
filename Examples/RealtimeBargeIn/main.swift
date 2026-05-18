import Foundation
import Mojentic

/// Start a turn, sleep briefly, then call `interrupt()` to demonstrate
/// barge-in. The session emits a `.interrupted` event and clears any
/// in-flight tool batch.
@main
struct RealtimeBargeIn {
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
                    instructions: "Recite the alphabet slowly."
                )
            )
            try await session.send(text: "Please recite the alphabet slowly.")

            // Watch events in the background; main task triggers barge-in.
            let consumer = Task {
                for try await event in session.events() {
                    print("[event] \(event)")
                    if case .sessionClosed = event { break }
                }
            }
            try await Task.sleep(for: .seconds(1))
            try await session.interrupt()
            try await Task.sleep(for: .seconds(1))
            await session.close()
            _ = await consumer.result
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
