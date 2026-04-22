import Foundation
import AVFoundation
import WhisperKit

/// Converts `AudioRecorder`'s WAV-encoded Data blob into the
/// `[Float]` at 16 kHz mono that `WhisperKit.transcribe(audioArray:)` expects.
///
/// AudioRecorder captures at the mic's native sample rate (typically 48 kHz
/// on Apple Silicon built-in mics) and encodes 16-bit Int16 PCM mono WAV.
/// Whisper models operate at 16 kHz. We parse the RIFF header, build an
/// `AVAudioPCMBuffer`, and hand it to WhisperKit's `AudioProcessor` which
/// already has a well-tested resample path we don't want to reimplement.
enum PCMConverter {

    enum PCMConverterError: Error, LocalizedError {
        case notAWavFile
        case unsupportedFormat(String)
        case resampleFailed

        var errorDescription: String? {
            switch self {
            case .notAWavFile: return "Not a valid WAV payload."
            case .unsupportedFormat(let msg): return "Unsupported WAV format: \(msg)."
            case .resampleFailed: return "Failed to resample audio to 16 kHz."
            }
        }
    }

    /// Parse + resample `wavData` to a 16 kHz mono Float32 array ready for
    /// `WhisperKit.transcribe(audioArray:)`. Runs on the calling thread; the
    /// call site should keep the work off the main actor for non-trivial
    /// clip lengths.
    static func float16kHzMono(from wavData: Data) throws -> [Float] {
        let parsed = try parseWAV(wavData)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: parsed.sampleRate,
            channels: AVAudioChannelCount(parsed.channels),
            interleaved: true
        ) else {
            throw PCMConverterError.unsupportedFormat("cannot build source format")
        }

        let frameCount = UInt32(parsed.pcm.count / Int(parsed.blockAlign))
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: frameCount
        ) else {
            throw PCMConverterError.resampleFailed
        }
        sourceBuffer.frameLength = frameCount

        parsed.pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress,
                  let dst = sourceBuffer.int16ChannelData?[0] else { return }
            memcpy(dst, src, parsed.pcm.count)
        }

        // Fast path: already 16 kHz mono — just convert Int16 → Float32.
        if Int(parsed.sampleRate) == 16_000 && parsed.channels == 1 {
            return floatArrayFromInt16Buffer(sourceBuffer)
        }

        guard let resampled = AudioProcessor.resampleAudio(
            fromBuffer: sourceBuffer,
            toSampleRate: 16_000,
            channelCount: 1
        ) else {
            throw PCMConverterError.resampleFailed
        }

        return AudioProcessor.convertBufferToArray(buffer: resampled)
    }

    // MARK: - WAV header parsing

    private struct ParsedWAV {
        let sampleRate: Double
        let channels: Int
        let bitsPerSample: Int
        let blockAlign: Int
        let pcm: Data
    }

    /// Minimal RIFF/WAVE parser. Tolerates extra chunks before `data`; bails
    /// on anything that's not 16-bit Int16 PCM.
    private static func parseWAV(_ data: Data) throws -> ParsedWAV {
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            throw PCMConverterError.notAWavFile
        }

        var offset = 12
        var sampleRate: Double = 0
        var channels = 0
        var bitsPerSample = 0
        var blockAlign = 0
        var pcmData: Data?

        while offset + 8 <= data.count {
            let chunkID = data.subdata(in: offset..<offset + 4)
            let chunkSize = Int(readUInt32LE(data, at: offset + 4))
            let bodyStart = offset + 8
            let bodyEnd = min(bodyStart + chunkSize, data.count)

            if chunkID == Data("fmt ".utf8) {
                let format = readUInt16LE(data, at: bodyStart)
                guard format == 1 else {
                    throw PCMConverterError.unsupportedFormat("non-PCM audio format \(format)")
                }
                channels = Int(readUInt16LE(data, at: bodyStart + 2))
                sampleRate = Double(readUInt32LE(data, at: bodyStart + 4))
                blockAlign = Int(readUInt16LE(data, at: bodyStart + 12))
                bitsPerSample = Int(readUInt16LE(data, at: bodyStart + 14))
                guard bitsPerSample == 16 else {
                    throw PCMConverterError.unsupportedFormat("\(bitsPerSample)-bit PCM")
                }
            } else if chunkID == Data("data".utf8) {
                pcmData = data.subdata(in: bodyStart..<bodyEnd)
                break
            }

            offset = bodyEnd + (chunkSize % 2)  // pad to even byte boundary
        }

        guard let pcm = pcmData, channels > 0, sampleRate > 0, blockAlign > 0 else {
            throw PCMConverterError.unsupportedFormat("missing fmt or data chunk")
        }

        return ParsedWAV(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            blockAlign: blockAlign,
            pcm: pcm
        )
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        return lo | (hi << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// Int16 → Float32 conversion for the already-16-kHz fast path.
    private static func floatArrayFromInt16Buffer(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        guard let ptr = buffer.int16ChannelData?[0] else { return [] }
        let scale = Float(Int16.max)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = Float(ptr[i]) / scale
        }
        return out
    }
}
