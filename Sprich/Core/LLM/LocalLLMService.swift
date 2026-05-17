import Foundation
import LocalLLMClient
import LocalLLMClientLlama
import AppKit

/// Thin actor around `LocalLLMClient.llama` exposing the same `cleanup(...)`
/// surface the cloud providers use.
///
/// Owns a single `LlamaClient` instance — loading the GGUF is the expensive
/// part (cold-load ~1.4 s on M1 Pro per benchmark), so we cache on first
/// use and across dictations. Mirrors `LocalWhisperService`'s shape and
/// lifecycle pattern.
///
/// Design references:
/// - Decision 6: prewarm-before-`.ready` (wired via `LLMModelManager.prewarmHook`);
///   unload on app background + 5 min idle.
/// - Decision 5a/5b/5c: no cloud fallback. If the local context fails to
///   load, we surface `SprichError.localLLMNotReady` and let the user pick
///   a cloud provider in Settings.
/// - Stop tokens: every chat completion includes `<end_of_turn>` +
///   `<start_of_turn>` as `extraEOSTokens` (benchmark doc § stop tokens).
/// - Surface-hint integration: piggybacks on `LLMService.composeSystemPrompt`
///   so Formal-mode dictation into Mail / Slack / Notion / etc. produces
///   the right shape on the 1B model (per `proposed-prompt-change.md`).
/// - Prompt parity with cloud: same `SystemPromptCatalog` lookup, same
///   `composeSystemPrompt` helper, same `temperature: 0.3`. Cloud and
///   local read from the same source so prompt-level parity is structural,
///   not aspirational.
actor LocalLLMService {

    /// Singleton — wired into `LLMModelManager.prewarmHook` at first access
    /// so the manager can trigger prewarm-before-`.ready` (Decision 6).
    static let shared = LocalLLMService()

    private var client: LlamaClient?
    private var loadedSpecID: String?
    private var loadingTask: Task<Void, Error>?
    private var lastUsedAt: Date = .distantPast

    /// 5-minute idle threshold per scoping Decision 6. Public for tests.
    static let idleUnloadInterval: TimeInterval = 5 * 60

    private init() {
        Task { [weak self] in
            await self?.installPrewarmHook()
            await self?.installBackgroundUnloadObservers()
        }
    }

    // MARK: - Prewarm

    /// Loads the GGUF and instantiates `LlamaClient`. Safe to call repeatedly
    /// — overlapping calls dedupe onto the same in-flight load task.
    ///
    /// Called by `LLMModelManager.prewarmHook` after a fresh download (so
    /// the first Formal-mode dictation is instant), and by `cleanup()`'s
    /// lazy path on cold start.
    func prewarm(spec: LocalLLMModelSpec, modelFile: URL) async throws {
        if let client, loadedSpecID == spec.id {
            #if DEBUG
            print("[Sprich][LocalLLM] prewarm: client already loaded, short-circuit")
            #endif
            return
        }
        if let existing = loadingTask {
            #if DEBUG
            print("[Sprich][LocalLLM] prewarm: another load in-flight, awaiting")
            #endif
            try await existing.value
            return
        }

        // Refuse to load a spec whose digest hasn't been verified by the
        // manager — `existingFile` returning nil means we'd be loading
        // unknown bytes. Belt-and-suspenders against Decision 5a's
        // "no silent surprises" rule.
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw SprichError.localLLMNotReady("Model file missing on disk at \(modelFile.path).")
        }

        await MainActor.run { LLMModelManager.shared.markPipeNotReady() }

        let task = Task { [spec, modelFile] in
            #if DEBUG
            let t0 = CFAbsoluteTimeGetCurrent()
            print("[Sprich][LocalLLM] prewarm: loading \(spec.id) from \(modelFile.path)")
            #endif

            let parameter = LlamaClient.Parameter(
                // 2048 covers Sprich's max realistic input (a few minutes
                // of dictation cleaned by a short prompt) with margin.
                context: 2048,
                // 0.3 matches the cloud LLM call site so cloud/local
                // behavior parity isn't just prompts.
                temperature: 0.3,
                topK: 40,
                topP: 0.95,
                options: .init(
                    // Gemma 3 GGUF emits trailing `<end_of_turn>` token
                    // spam without these stops. Verified 2026-05-16,
                    // documented in `benchmarks/2026-05-local-llm.md`.
                    extraEOSTokens: ["<end_of_turn>", "<start_of_turn>"],
                    verbose: false
                )
            )

            let loaded = try await LocalLLMClient.llama(
                url: modelFile,
                parameter: parameter
            )
            await self.setClient(loaded, specID: spec.id)
            await MainActor.run { LLMModelManager.shared.markPipeReady() }

            #if DEBUG
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            print("[Sprich][LocalLLM] prewarm ✅ in \(ms) ms")
            #endif
        }
        loadingTask = task
        defer { loadingTask = nil }
        try await task.value
    }

    private func setClient(_ client: LlamaClient, specID: String) {
        self.client = client
        self.loadedSpecID = specID
    }

    // MARK: - Cleanup

    /// Drop-in replacement for `LLMService.cleanup` — same signature, same
    /// prompt-composition path, same surface-hint integration. The provider
    /// switch in `LLMService` routes to this for `.local`.
    func cleanup(
        rawText: String,
        mode: TranscriptionMode,
        settings: AppSettings,
        surface: Surface = .generic
    ) async throws -> String {
        let sanitizedText = InputSanitizer.sanitize(rawText)
        guard !sanitizedText.isEmpty else {
            throw SprichError.emptyTranscription
        }

        // Compose the base system prompt for the active mode + language
        // via the same catalog cloud uses. This is the "prompt parity"
        // hook from `proposed-prompt-change.md`.
        let basePrompt = SystemPromptCatalog.prompt(
            for: mode,
            language: settings.preferredLanguage
        )
        // Reuse the existing surface-adaptation helper — Formal-mode
        // outputs adapt to email / slack / docs / etc. on the 1B model
        // via the same `Destination: …` if/else rule the cloud path uses.
        let systemPrompt = LLMService.composeSystemPrompt(
            base: basePrompt,
            mode: mode,
            surface: surface,
            adaptToSurface: settings.adaptToSurface
        )

        // Lazy-load on cold start — first Formal dictation after launch
        // when prewarm hasn't fired yet. Subsequent calls hit the cached
        // client.
        if client == nil {
            try await loadIfNeeded(spec: LocalLLMModelSpec.defaultSpec)
        }
        guard let client else {
            throw SprichError.localLLMNotReady("Model failed to load. Check Settings → Providers → Local LLM, or switch to a cloud provider.")
        }

        let input = LLMInput.chat([
            .system(systemPrompt),
            .user(sanitizedText)
        ])

        lastUsedAt = Date()

        let raw = try await client.generateText(from: input)

        // Strip the known preamble artifacts the 1B model occasionally
        // emits despite the "no preamble" prompt directive. Whitelist is
        // small + per `local-llm-distribution-plan.md` § C7.
        return Self.stripPreamble(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve the on-disk file via `LLMModelManager` and call `prewarm`.
    /// Called from `cleanup` on cold start.
    private func loadIfNeeded(spec: LocalLLMModelSpec) async throws {
        let modelFile = await MainActor.run {
            LLMModelManager.shared.existingFile(for: spec)
        }
        guard let modelFile else {
            throw SprichError.localLLMNotReady("Local model not downloaded. Open Settings → Providers → Local LLM to download.")
        }
        try await prewarm(spec: spec, modelFile: modelFile)
    }

    /// Drops the client and frees the model arenas. Triggered on the
    /// idle-unload path (Decision 6) and when the user deletes the model
    /// or switches to a different cloud provider.
    func unload() {
        client = nil
        loadedSpecID = nil
        Task { @MainActor in LLMModelManager.shared.markPipeNotReady() }
        #if DEBUG
        print("[Sprich][LocalLLM] unload — client dropped")
        #endif
    }

    // MARK: - Idle-unload (Decision 6: on background + 5 min idle)

    /// Wired in `init` so the actor listens for NSApp background
    /// transitions. The 5-min idle window starts when the app loses focus;
    /// if `cleanup` is called in the meantime, `lastUsedAt` advances and
    /// the timer restarts. If the app regains focus, the pending unload
    /// is cancelled.
    private func installBackgroundUnloadObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { await LocalLLMService.shared.scheduleIdleUnload() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { await LocalLLMService.shared.cancelIdleUnload() }
        }
    }

    private var idleUnloadTask: Task<Void, Never>?

    fileprivate func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleUnloadInterval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.unloadIfIdle()
        }
    }

    fileprivate func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func unloadIfIdle() {
        // Re-check the idle window — if cleanup fired during the sleep
        // (foreground returned briefly, did some dictation, backgrounded
        // again), don't unload mid-use.
        let since = Date().timeIntervalSince(lastUsedAt)
        guard since >= Self.idleUnloadInterval else { return }
        unload()
    }

    // MARK: - Prewarm hook wiring

    private func installPrewarmHook() {
        Task { @MainActor in
            LLMModelManager.shared.prewarmHook = { [weak self] spec, modelFile in
                try await self?.prewarm(spec: spec, modelFile: modelFile)
            }
        }
    }

    // MARK: - Preamble stripper

    /// Known per-language preamble strings the 1B model occasionally
    /// leaks before the actual output. Documented in
    /// `local-llm-distribution-plan.md` § C7 (response parser).
    private static let preambles: [String] = [
        "Here is the rewritten text:",
        "Here's the rewritten text:",
        "Here is the cleaned text:",
        "Here's the cleaned text:",
        "Hier ist der überarbeitete Text:",
        "Hier ist der bereinigte Text:",
        "Hier der überarbeitete Text:"
    ]

    static func stripPreamble(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for preamble in preambles {
            if trimmed.hasPrefix(preamble) {
                let dropped = trimmed.dropFirst(preamble.count)
                return String(dropped).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }
}
