import Foundation

/// Single chunk of PCM audio exchanged with a realtime session.
///
/// `AudioFrame` carries little-endian signed 16-bit mono PCM samples at
/// `sampleRate` Hz. The OpenAI Realtime API expects 24 kHz by default —
/// `sampleRate` is exposed so other providers (or future configurations)
/// can carry different rates.
///
/// > Note: Mojentic deliberately does NOT ship audio capture or playback.
/// > Wire `AVAudioEngine` (Apple) or ALSA/PulseAudio (Linux) at your app
/// > boundary; this library only encodes / decodes the wire bytes.
public struct AudioFrame: Sendable, Hashable {
    /// PCM samples (little-endian signed 16-bit).
    public let samples: [Int16]

    /// Sample rate in Hz.
    public let sampleRate: Int

    /// Construct a frame.
    public init(samples: [Int16], sampleRate: Int = 24_000) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// Codec helpers for the realtime audio wire format.
public enum AudioCodec {
    /// Encode `frame` as base64-encoded little-endian PCM bytes.
    public static func base64Encode(_ frame: AudioFrame) -> String {
        var data = Data(capacity: frame.samples.count * 2)
        for sample in frame.samples {
            let little = sample.littleEndian
            withUnsafeBytes(of: little) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data.base64EncodedString()
    }

    /// Decode a base64-encoded PCM payload at the supplied sample rate.
    ///
    /// Throws ``MojenticError/decoding(message:)`` when the payload is not
    /// valid base64 or has an odd byte count.
    public static func base64Decode(
        _ string: String,
        sampleRate: Int = 24_000
    ) throws -> AudioFrame {
        guard let data = Data(base64Encoded: string) else {
            throw MojenticError.decoding(message: "Invalid base64 audio payload")
        }
        guard data.count % 2 == 0 else {
            throw MojenticError.decoding(
                message: "PCM payload has odd byte count (expected pairs of bytes)"
            )
        }
        var samples: [Int16] = []
        samples.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index < data.endIndex {
            let lo = UInt16(data[index])
            let hi = UInt16(data[data.index(after: index)])
            let combined = (hi << 8) | lo
            samples.append(Int16(bitPattern: combined))
            index = data.index(index, offsetBy: 2)
        }
        return AudioFrame(samples: samples, sampleRate: sampleRate)
    }
}
