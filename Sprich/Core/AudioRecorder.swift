import Foundation
import AVFoundation

/// Records audio from the microphone using AVAudioEngine.
/// Audio is accumulated entirely in RAM — never written to disk —
/// and returned as a WAV-encoded `Data` blob suitable for STT API upload.
///
/// Why in-memory only: a temp file in `/tmp` can be read by any app on the
/// system, snapshotted by Time Machine/iCloud mid-recording, or survive a
/// crash. Keeping samples in RAM means they vanish the moment the process
/// exits and never hit any backup/forensics surface.
class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var recordingStartTime: Date?
    private let maxDuration: TimeInterval

    // In-memory PCM sample storage. Stored as 16-bit little-endian mono
    // samples at `sampleRate` Hz — the canonical WAV payload format.
    private var pcmBuffer = Data()
    private var sampleRate: Double = 16000
    private let bufferQueue = DispatchQueue(label: "com.niconuscheler.sprich.audiobuffer")

    /// Loudest per-buffer RMS seen during the current recording (raw, 0.0–1.0,
    /// pre-normalization). Updated on the audio thread under `bufferQueue`. Used
    /// as a lightweight energy/VAD signal: a near-silent clip is dropped before
    /// STT (otherwise Whisper hallucinates canned phrases like "Thank you." /
    /// "Transcription by CastingWords." on silence). OpenWhispr solves the same
    /// problem by bundling a Silero VAD model into whisper.cpp; an energy gate is
    /// the provider-agnostic equivalent that also works for our cloud STT paths.
    private var peakLevel: Float = 0

    /// Peak RMS and duration of the LAST stopped recording, exposed so the
    /// pipeline can apply a secondary hallucination filter (drop a canned
    /// Whisper phrase only when the clip carried no real speech energy).
    private(set) var lastPeakLevel: Float = 0
    private(set) var lastDurationSeconds: Double = 0

    /// Peak RMS below which a clip is treated as silence and dropped outright in
    /// `stopRecording`. Conservative — normal (even quiet) speech peaks well
    /// above this; only the mic noise floor falls below. Tunable; `lastPeakLevel`
    /// is logged in DEBUG so real-mic values can calibrate it.
    static let silencePeakThreshold: Float = 0.010

    /// Called on each audio buffer with the current RMS level (0.0–1.0).
    var onAudioLevel: ((Float) -> Void)?

    /// Fired when the `maxDuration` cap trips mid-recording. Delivers the
    /// WAV-encoded audio captured up to that point so the pipeline can
    /// process it instead of dropping it — the user's minutes of speech
    /// are not wasted. Callback runs on the main thread.
    var onMaxDurationReached: ((Data) -> Void)?

    init(maxDuration: TimeInterval = 300) {  // 5 minutes default
        self.maxDuration = maxDuration
    }

    /// Start recording audio. Requires microphone permission.
    func startRecording() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        self.sampleRate = nativeFormat.sampleRate

        // Reset in-memory buffer + peak level for this recording.
        bufferQueue.sync { pcmBuffer = Data(); peakLevel = 0 }

        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            // Check max duration. Previously this called
            // `stopRecording()` and discarded the result, which meant
            // the user lost every second of audio past the cap because
            // the subsequent hotkey release saw `isRecording = false`
            // and got `nil` back. Now we keep the captured WAV and
            // surface it to the coordinator via `onMaxDurationReached`,
            // which processes it through the normal pipeline + appends
            // a notice telling the user to press the hotkey again to
            // continue dictating.
            if let start = self.recordingStartTime,
               Date().timeIntervalSince(start) > self.maxDuration {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let wav = try? self.stopRecording() {
                        self.onMaxDurationReached?(wav)
                    }
                }
                return
            }

            // Append samples to in-memory buffer (converted to 16-bit PCM).
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                self.appendPCM16(from: channelData, frameCount: frameCount)

                // Compute RMS audio level for visualization
                var sum: Float = 0
                for i in 0..<frameCount {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrtf(sum / Float(max(frameCount, 1)))
                self.bufferQueue.sync { if rms > self.peakLevel { self.peakLevel = rms } }
                let normalized = min(1.0, rms * 8)
                DispatchQueue.main.async {
                    self.onAudioLevel?(normalized)
                }
            }
        }

        try engine.start()
        self.audioEngine = engine
        self.isRecording = true
        self.recordingStartTime = Date()
    }

    /// Stop recording and return a WAV-encoded Data blob built in memory.
    /// The returned bytes are byte-for-byte identical to a standard
    /// 16-bit PCM mono WAV file, suitable for direct upload to STT APIs.
    func stopRecording() throws -> Data? {
        guard isRecording else { return nil }

        isRecording = false
        recordingStartTime = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        let pcm = bufferQueue.sync { pcmBuffer }
        let peak = bufferQueue.sync { peakLevel }
        // Zero out our copy so the samples don't linger in the instance's heap.
        bufferQueue.sync { pcmBuffer = Data() }

        // Record peak + duration for the pipeline's secondary hallucination
        // filter, BEFORE any early-return so they're valid even on a drop.
        lastPeakLevel = peak
        lastDurationSeconds = sampleRate > 0 ? Double(pcm.count) / (sampleRate * 2.0) : 0
        #if DEBUG
        print(String(format: "[Sprich] AudioRecorder: stop — %.2fs, peak RMS %.4f, %d bytes",
                     lastDurationSeconds, peak, pcm.count))
        #endif

        // Return nil if recording was too short (< ~0.25s of mono 16kHz)
        // 16kHz * 2 bytes * 0.25s = 8000 bytes
        if pcm.count < 8000 { return nil }

        // Energy gate (lightweight VAD): a clip whose loudest moment never rose
        // above the noise floor is silence — sending it to Whisper produces a
        // hallucinated canned phrase ("Thank you.", "Transcription by
        // CastingWords."). Drop it here so the pipeline dismisses cleanly.
        if peak < Self.silencePeakThreshold {
            #if DEBUG
            print(String(format: "[Sprich] AudioRecorder: dropping silent clip (peak %.4f < %.4f)",
                         peak, Self.silencePeakThreshold))
            #endif
            return nil
        }

        return encodeWAV(pcm: pcm, sampleRate: Int(sampleRate), channels: 1, bitsPerSample: 16)
    }

    /// Cancel recording without returning data.
    func cancelRecording() {
        isRecording = false
        recordingStartTime = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        bufferQueue.sync { pcmBuffer = Data() }
    }

    var recording: Bool {
        return isRecording
    }

    // MARK: - In-memory PCM accumulation

    /// Convert float samples in [-1.0, 1.0] to 16-bit little-endian PCM
    /// and append to the in-memory buffer.
    private func appendPCM16(from samples: UnsafePointer<Float>, frameCount: Int) {
        var chunk = Data(capacity: frameCount * 2)
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, samples[i]))
            let value = Int16(clamped * Float(Int16.max))
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { chunk.append(contentsOf: $0) }
        }
        bufferQueue.sync { pcmBuffer.append(chunk) }
    }

    // MARK: - WAV encoding

    /// Build a minimal RIFF/WAVE container around the raw PCM payload.
    /// Produces the same bytes AVAudioFile would write for an equivalent
    /// PCM file — just without ever touching disk.
    private func encodeWAV(pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcm.count
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32LE(UInt32(chunkSize)))
        header.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32LE(16))              // PCM fmt chunk size
        header.append(uint16LE(1))               // AudioFormat = 1 (PCM)
        header.append(uint16LE(UInt16(channels)))
        header.append(uint32LE(UInt32(sampleRate)))
        header.append(uint32LE(UInt32(byteRate)))
        header.append(uint16LE(UInt16(blockAlign)))
        header.append(uint16LE(UInt16(bitsPerSample)))

        // data subchunk
        header.append(contentsOf: "data".utf8)
        header.append(uint32LE(UInt32(dataSize)))

        var wav = Data(capacity: 44 + dataSize)
        wav.append(header)
        wav.append(pcm)
        return wav
    }

    private func uint16LE(_ value: UInt16) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 2)
    }

    private func uint32LE(_ value: UInt32) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 4)
    }
}
