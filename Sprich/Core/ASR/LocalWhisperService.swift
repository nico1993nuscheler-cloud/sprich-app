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

        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                return "Local Whisper model is not downloaded yet. Open Settings → Speech to Text → Local to download."
            case .emptyTranscription:
                return "Local Whisper returned no text."
            }
        }
    }

    /// Warm the WhisperKit pipe for `model`. Safe to call repeatedly from
    /// any actor — overlapping calls dedupe onto the same load task.
    ///
    /// `modelFolder` must exist on disk — `WhisperModelManager.ensureReady`
    /// is responsible for downloading it. We set `download: false` so an
    /// accidentally-missing folder fails fast instead of hitting the network.
    func prewarm(model: String, modelFolder: URL) async throws {
        #if DEBUG
        print("[Sprich][Local] prewarm(\(model)) — pipe=\(pipe == nil ? "nil" : "set"), loadedModel=\(loadedModel ?? "nil"), loadingTask=\(loadingTask == nil ? "nil" : "in-flight")")
        #endif

        if let pipe, loadedModel == model, case .loaded = pipe.modelState {
            #if DEBUG
            print("[Sprich][Local] prewarm: pipe already loaded, short-circuit")
            #endif
            return
        }
        if let existing = loadingTask {
            #if DEBUG
            print("[Sprich][Local] prewarm: another load in-flight, awaiting")
            #endif
            try await existing.value
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let baseURL = await WhisperModelManager.shared.baseURL
        let task = Task<Void, Error> { [modelFolder] in
            #if DEBUG
            print("[Sprich][Local] prewarm: constructing WhisperKit at \(modelFolder.path)")
            print("[Sprich][Local] prewarm: downloadBase=\(baseURL.path), tokenizerFolder=\(modelFolder.path)")
            #endif

            // Explicitly resolve every path WhisperKit might look at
            // locally, so it never silently falls back to a HuggingFace
            // download that can hang behind slow/blocked networks. The
            // turbo variant in particular was never returning from
            // `init(config)` — the most likely culprit is tokenizer
            // resolution: without `tokenizerFolder` or `downloadBase`,
            // WhisperKit's HubApi tries to fetch tokenizer.json from
            // the network.
            //
            // Also flipping `prewarm: false`. `prewarm: true` tells
            // WhisperKit to eagerly warm the Core ML graph inside the
            // init call. If *that* phase is the one hanging on the
            // turbo variant, we'd never escape `init(config)`. With
            // `prewarm: false`, init returns as soon as the model is
            // loaded; the first transcribe pays a slightly higher
            // latency (WhisperKit warms lazily on demand) but we'd
            // rather trade a bit of first-call latency for a pipeline
            // that actually returns.
            //
            // `logLevel: .debug` temporarily routes WhisperKit's own
            // internal logs to the Xcode console so the next hang
            // report has visibility into what WhisperKit itself is
            // doing.
            let config = WhisperKitConfig(
                model: model,
                downloadBase: baseURL,
                modelFolder: modelFolder.path,
                tokenizerFolder: modelFolder,
                verbose: true,
                logLevel: .debug,
                prewarm: false,
                load: true,
                download: false
            )

            #if DEBUG
            let tInit = CFAbsoluteTimeGetCurrent()
            print("[Sprich][Local] prewarm: calling try await WhisperKit(config) …")
            #endif
            let loaded = try await WhisperKit(config)
            #if DEBUG
            let initMs = Int((CFAbsoluteTimeGetCurrent() - tInit) * 1000)
            print("[Sprich][Local] prewarm: WhisperKit constructed in \(initMs)ms, installing pipe")
            #endif
            await self.setPipe(loaded, model: model)
        }
        loadingTask = task
        defer { loadingTask = nil }
        try await task.value

        #if DEBUG
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        print("[Sprich][Local] prewarm ✅ in \(Int(elapsed * 1000))ms")
        #endif
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
        #if DEBUG
        print("[Sprich][Local] transcribe() entered — pipe=\(pipe == nil ? "nil" : "set"), loadedModel=\(loadedModel ?? "nil"), loadingTask=\(loadingTask == nil ? "nil" : "in-flight")")
        #endif

        // If a prewarm is mid-flight (user just switched to Local and
        // pressed the hotkey), wait for it rather than failing.
        if pipe == nil, let loading = loadingTask {
            #if DEBUG
            print("[Sprich][Local] transcribe: awaiting in-flight loadingTask…")
            #endif
            try await loading.value
            #if DEBUG
            print("[Sprich][Local] transcribe: loadingTask completed")
            #endif
        }
        guard let pipe else {
            #if DEBUG
            print("[Sprich][Local] transcribe ⛔️ pipe still nil after await — throwing modelNotReady")
            #endif
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
        print("[Sprich][Local] PCM convert: \(Int((t1 - t0) * 1000))ms, audio=\(String(format: "%.1f", audioSeconds))s, samples=\(samples.count)")
        #endif

        // Aggressive latency-first decoding. See commit history for the
        // rationale on each knob. VAD chunking only triggers on clips
        // longer than WhisperKit's 30 s window — short clips take the
        // non-chunked path regardless.
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
            chunkingStrategy: .vad
        )

        #if DEBUG
        print("[Sprich][Local] calling pipe.transcribe(audioArray:) …")
        #endif

        // Direct call. No TaskGroup, no timeout wrapping. The prior
        // TaskGroup attempt was one of the prime suspects for the
        // "hotkey release → overlay stuck forever" report, so we're
        // reducing to the minimum code path. If this hangs, it's
        // definitively inside WhisperKit and Xcode's Debug Navigator
        // will show the blocked thread.
        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
        } catch {
            #if DEBUG
            print("[Sprich][Local] pipe.transcribe THREW: \(error)")
            #endif
            throw error
        }

        #if DEBUG
        let t2 = CFAbsoluteTimeGetCurrent()
        let totalChars = results.map { $0.text.count }.reduce(0, +)
        print("[Sprich][Local] pipe.transcribe returned: decode=\(Int((t2 - t1) * 1000))ms, windows=\(results.count), chars=\(totalChars)")
        #endif

        let joined = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if joined.isEmpty {
            #if DEBUG
            print("[Sprich][Local] transcribe: joined result is empty — throwing emptyTranscription")
            #endif
            throw LocalWhisperError.emptyTranscription
        }

        #if DEBUG
        print("[Sprich][Local] transcribe ✅ returning \(joined.count) chars")
        #endif
        return joined
    }

    /// Drop the loaded pipe — useful when the user switches models or
    /// deletes the current one. Frees the Core ML arenas (~1 GB).
    func unload() {
        pipe = nil
        loadedModel = nil
    }
}
