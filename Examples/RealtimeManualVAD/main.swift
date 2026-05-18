import Foundation
import Mojentic

/// Same as `RealtimeBasic` but with manual VAD: the client decides when to
/// commit the input buffer.
@main
struct RealtimeManualVAD {
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
                    vad: .manual,
                    instructions: "Reply with one short sentence."
                )
            )
            // Pretend we have one 20ms frame of silence; in a real app this
            // would be live microphone capture.
            let silence = AudioFrame(samples: Array(repeating: Int16(0), count: 480))
            try await session.send(audio: silence)
            try await session.commit()
            for try await event in session.events() {
                if case .responseDone = event { break }
                if case .textDelta(_, let delta) = event {
                    print(delta, terminator: "")
                }
            }
            print("")
            await session.close()
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
