import Foundation
import WhisperKit

/// Thin wrapper around `WhisperKit` exposing the same `transcribe(audioData:…)`
/// surface the cloud providers use. Owns a single pipe instance — loading it
/// is the expensive part (Core ML first-compile can be 10–30 s for
/// large-v3), so we cache on first use and across dictations.
///
/// Kept as an `actor` so concurrent hotkey presses can't race on the load
/// sequence.
actor LocalWhisperService {

    private var pipe: WhisperKit?
    private var loadedModel: String?

    enum LocalWhisperError: Error, LocalizedError {
        case modelNotReady
        case emptyTranscription

        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                return "Local Whisper model is not downloaded yet. Open Settings → Speech to Text → Local to download."
            case .emptyTranscription:
                return "Local Whisper returned no text."
            }
        }
    }

    /// Warm the WhisperKit pipe for `model`. Safe to call repeatedly; only
    /// the first call pays the load + Core ML compile cost.
    ///
    /// `modelFolder` must exist on disk — `WhisperModelManager.ensureReady`
    /// is responsible for downloading it. We set `download: false` so an
    /// accidentally-missing folder fails fast instead of hitting the network.
    func prewarm(model: String, modelFolder: URL) async throws {
        if let pipe, loadedModel == model, case .loaded = pipe.modelState {
            return
        }

        let config = WhisperKitConfig(
            model: model,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let loaded = try await WhisperKit(config)
        self.pipe = loaded
        self.loadedModel = model
    }

    /// Transcribe an in-memory WAV blob produced by `AudioRecorder`.
    /// - Parameter audioData: 16-bit PCM mono WAV (any sample rate;
    ///   `PCMConverter` resamples to 16 kHz).
    /// - Parameter language: ISO 639-1 code, or nil for auto-detect.
    func transcribe(
        audioData: Data,
        language: String?
    ) async throws -> String {
        guard let pipe else {
            throw LocalWhisperError.modelNotReady
        }

        let samples = try PCMConverter.float16kHzMono(from: audioData)

        // DecodingOptions init order is fixed — see Configurations.swift in
        // WhisperKit v0.18: verbose, task, language, temperature, ..., then
        // detectLanguage, skipSpecialTokens, withoutTimestamps.
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        let joined = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if joined.isEmpty {
            throw LocalWhisperError.emptyTranscription
        }
        return joined
    }

    /// Drop the loaded pipe — useful when the user switches models or
    /// deletes the current one. Frees the Core ML arenas (~1 GB).
    func unload() {
        pipe = nil
        loadedModel = nil
    }
}
