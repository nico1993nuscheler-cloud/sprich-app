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
    /// In-flight load. Held so (a) repeat `prewarm` calls dedupe to one
    /// WhisperKit construction and (b) `transcribe` can await an ongoing
    /// load instead of failing with `.modelNotReady` when the user triggers
    /// dictation mid-load (e.g. hotkey pressed right after selecting Local).
    private var loadingTask: Task<Void, Error>?

    enum LocalWhisperError: Error, LocalizedError {
        case modelNotReady
        case emptyTranscription
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                return "Local Whisper model is not downloaded yet. Open Settings → Speech to Text → Local to download."
            case .emptyTranscription:
                return "Local Whisper returned no text."
            case .timedOut(let seconds):
                return "Local Whisper timed out after \(Int(seconds))s. Try again, or pick a smaller model tier in Settings → Providers → Local."
            }
        }
    }

    /// Upper bound on a single `WhisperKit.transcribe` call. 180 s is
    /// well above any realistic clip (5-minute max recording × ~0.5×
    /// realtime worst case on M1 8GB ≈ 150 s for a full-duration clip
    /// through large-v3). If we hit it, something's genuinely stuck
    /// and we should free the UI rather than hang forever behind the
    /// recording overlay.
    private static let transcribeTimeout: TimeInterval = 180

    /// Warm the WhisperKit pipe for `model`. Safe to call repeatedly from
    /// any actor — overlapping calls dedupe onto the same load task.
    ///
    /// `modelFolder` must exist on disk — `WhisperModelManager.ensureReady`
    /// is responsible for downloading it. We set `download: false` so an
    /// accidentally-missing folder fails fast instead of hitting the network.
    func prewarm(model: String, modelFolder: URL) async throws {
        if let pipe, loadedModel == model, case .loaded = pipe.modelState {
            return
        }
        if let existing = loadingTask {
            try await existing.value
            return
        }

        let task = Task<Void, Error> { [modelFolder] in
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
            await self.setPipe(loaded, model: model)
        }
        loadingTask = task
        defer { loadingTask = nil }
        try await task.value
    }

    private func setPipe(_ pipe: WhisperKit, model: String) {
        self.pipe = pipe
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
        // If a prewarm is mid-flight (user just switched to Local and
        // pressed the hotkey), wait for it rather than failing.
        if pipe == nil, let loading = loadingTask {
            try await loading.value
        }
        guard let pipe else {
            throw LocalWhisperError.modelNotReady
        }

        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        let audioKB = audioData.count / 1024
        print("[Sprich][Local] transcribe start — \(audioKB)KB audio, lang=\(language ?? "auto")")
        #endif

        let samples = try PCMConverter.float16kHzMono(from: audioData)

        #if DEBUG
        let t1 = CFAbsoluteTimeGetCurrent()
        let audioSeconds = Double(samples.count) / 16_000.0
        print("[Sprich][Local] PCM convert: \(Int((t1 - t0) * 1000))ms, audio duration=\(String(format: "%.1f", audioSeconds))s")
        #endif

        // Aggressive latency-first decoding options. WhisperKit's defaults
        // are tuned for transcription quality on long-form audio with a
        // temperature-fallback ladder (retry at higher temperature when
        // compression-ratio or logprob thresholds trip). For interactive
        // dictation that ladder is a wall-clock tax we don't need —
        // single-pass greedy decoding produces nearly identical output
        // on clean short clips and is measurably faster. Concrete
        // levers below:
        //
        // - `temperature: 0.0` + `temperatureFallbackCount: 0`: do one
        //   deterministic pass, never retry. Saves up to 5× decode
        //   time on any clip where a heuristic threshold would have
        //   triggered a fallback.
        // - `topK: 1`: greedy token sampling. Slightly cheaper per token
        //   than top-5, and there's no stochasticity we want at
        //   temperature 0 anyway.
        // - `compressionRatioThreshold: nil`, `logProbThreshold: nil`,
        //   `noSpeechThreshold: nil`: disable the quality gates that
        //   drive the fallback ladder. They also add per-window overhead.
        // - `withoutTimestamps: true`: skip timestamp-token generation
        //   (we only paste text, no timeline).
        // - `skipSpecialTokens: true`: drop `<|endoftext|>` etc. from
        //   emitted string — already true upstream but set explicitly.
        // - `usePrefillPrompt: true` + `usePrefillCache: true`: reuse
        //   the cached `<|startoftranscript|><|language|><|transcribe|>`
        //   prefix across chunks (WhisperKit defaults, kept explicit).
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 0,
            topK: 1,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            compressionRatioThreshold: nil,
            logProbThreshold: nil,
            noSpeechThreshold: nil,
            // VAD-based chunking. Without this, WhisperKit's default is
            // to process one 30 s window only — any audio longer than
            // that silently drops. `AppSettings.maxRecordingDuration`
            // defaults to 300 s (5 min) and is user-configurable, so
            // >30 s clips are well within normal usage. VAD chunks at
            // speech-pause boundaries so split points don't land
            // mid-word.
            chunkingStrategy: .vad
        )

        // Wrap the transcribe call in a timeout so a hung WhisperKit
        // doesn't strand the user behind a stuck recording overlay.
        // The overlay dismisses on any thrown error, so a timeout
        // surface-reports the problem and frees the UI.
        let timeout = Self.transcribeTimeout
        let results: [TranscriptionResult] = try await withThrowingTaskGroup(
            of: [TranscriptionResult].self
        ) { group in
            group.addTask {
                try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LocalWhisperError.timedOut(timeout)
            }
            // First task to finish wins; cancel the loser.
            guard let first = try await group.next() else {
                throw LocalWhisperError.timedOut(timeout)
            }
            group.cancelAll()
            return first
        }

        #if DEBUG
        let t2 = CFAbsoluteTimeGetCurrent()
        print("[Sprich][Local] decode: \(Int((t2 - t1) * 1000))ms, windows=\(results.count)")
        #endif

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
