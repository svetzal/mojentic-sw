import Foundation
import Mojentic

/// Open a realtime session, optionally stream a pre-recorded WAV-derived
/// PCM file into it, and print every neutral event the session emits.
///
/// Audio capture/playback is intentionally out of scope. To actually play
/// the assistant's audio back, wire AVAudioEngine on Apple platforms or
/// ALSA/PulseAudio on Linux against the bytes inside the `.audioDelta`
/// events.
@main
struct RealtimeBasic {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            print("Set OPENAI_API_KEY to run this example.")
            exit(1)
        }
        let arguments = CommandLine.arguments
        let pcmPath = arguments.count >= 2 ? arguments[1] : nil
        let broker = RealtimeVoiceBroker(gateway: OpenAIRealtimeGateway())
        do {
            let session = try await broker.startSession(
                RealtimeSessionConfig(
                    model: "gpt-4o-realtime-preview",
                    apiKey: key,
                    instructions: "Reply briefly when the user speaks."
                )
            )
            if let pcmPath {
                try await streamFile(path: pcmPath, into: session)
            } else {
                try await session.send(text: "Say hello in one short sentence.")
            }
            for try await event in session.events() {
                describe(event)
                if case .responseDone = event { break }
            }
            await session.close()
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    static func streamFile(path: String, into session: RealtimeSession) async throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let samples = data.withUnsafeBytes { buffer -> [Int16] in
            Array(buffer.bindMemory(to: Int16.self))
        }
        // Slice the file into ~20ms frames at 24 kHz (480 samples per frame).
        let frameSize = 480
        var index = 0
        while index < samples.count {
            let end = min(index + frameSize, samples.count)
            let frame = AudioFrame(samples: Array(samples[index..<end]))
            try await session.send(audio: frame)
            index = end
        }
    }

    static func describe(_ event: RealtimeEvent) {
        switch event {
        case .textDelta(_, let delta):
            print(delta, terminator: "")
        case .transcriptDelta(_, let delta):
            print(delta, terminator: "")
        case .responseDone:
            print("")
        default:
            print("[\(event)]")
        }
    }
}
