import Foundation
import AVFoundation

/// Records audio from the microphone using AVAudioEngine.
/// Outputs M4A data suitable for Whisper API upload.
class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var isRecording = false
    private var recordingStartTime: Date?
    private let maxDuration: TimeInterval

    /// Called on each audio buffer with the current RMS level (0.0–1.0).
    var onAudioLevel: ((Float) -> Void)?

    init(maxDuration: TimeInterval = 300) {  // 5 minutes default
        self.maxDuration = maxDuration
    }

    /// Start recording audio. Requires microphone permission.
    func startRecording() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Use the input node's native format to avoid conversion issues
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Create temp file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sprich_recording_\(UUID().uuidString).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        self.tempFileURL = fileURL

        // Create audio file with the native format
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: nativeFormat.settings
        )
        self.audioFile = audioFile

        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            // Check max duration
            if let start = self.recordingStartTime,
               Date().timeIntervalSince(start) > self.maxDuration {
                DispatchQueue.main.async {
                    try? self.stopRecording()
                }
                return
            }

            // Write buffer to file
            try? audioFile.write(from: buffer)

            // Compute RMS audio level for visualization
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameCount {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrtf(sum / Float(max(frameCount, 1)))
                // Normalize: typical speech RMS is 0.01–0.15, map to 0–1
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

    /// Stop recording and return the audio data.
    /// Audio data is suitable for direct upload to STT API.
    func stopRecording() throws -> Data? {
        guard isRecording else { return nil }

        isRecording = false
        recordingStartTime = nil

        // Remove tap and stop engine
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil  // Close the file

        // Read the recorded data
        guard let fileURL = tempFileURL else { return nil }
        defer {
            // Clean up temp file — no audio persistence on disk
            try? FileManager.default.removeItem(at: fileURL)
            tempFileURL = nil
        }

        let data = try Data(contentsOf: fileURL)

        // Return nil if recording was too short (< 0.5 seconds likely noise)
        if data.count < 8000 {  // ~0.25 seconds at 16kHz
            return nil
        }

        return data
    }

    /// Cancel recording without returning data.
    func cancelRecording() {
        isRecording = false
        recordingStartTime = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil

        // Clean up temp file
        if let fileURL = tempFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            tempFileURL = nil
        }
    }

    var recording: Bool {
        return isRecording
    }
}
