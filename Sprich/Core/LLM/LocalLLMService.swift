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

    /// True while a `cleanup()` call is awaiting `client.generateText`.
    /// Swift actors are re-entrant on `await`, so this explicit guard is
    /// required even though `LocalLLMService` is an actor — without it,
    /// two concurrent cleanup() calls hit llama.cpp's `generateText` at
    /// the same time and crash in `LocalLLMClientLlama/Batch.swift:20
    /// Unexpectedly found nil`. Mutable actor state IS preserved across
    /// the actor's own await points, so a simple bool is sufficient.
    private var isGenerating = false

    /// 5-minute idle threshold per scoping Decision 6. Public for tests.
    static let idleUnloadInterval: TimeInterval = 5 * 60

    /// Llama context window in tokens. Sized to comfortably hold:
    ///   - Hardened Formal system prompt (~700 tokens for the longest
    ///     localized variant, e.g. German)
    ///   - Longest destination hint (`aiChat` / `taskManager`, ~160 tokens)
    ///   - A multi-minute dictation (worst-case ~1500 tokens at 60 s of
    ///     speech)
    ///   - The model's pre-EOS output budget (`LLMService.budgetTokens`,
    ///     capped at 1024)
    ///   - Chat-template overhead + safety margin
    ///
    /// History: 2048 → 4096 (2026-05-26) → 8192 (2026-05-27). The 4096
    /// bump still saw `context size exceeded[4096 < 4140]` on Formal +
    /// email surface for a normal-length dictation; 8192 leaves ~3000
    /// tokens of headroom in the worst observed case. Gemma 3 1B
    /// supports 32k natively; ~80 MB extra KV cache is a cheap fix and
    /// gets us out of the "tune the context every release" cycle.
    static let contextSize: Int = 8192

    /// Safety margin (tokens) reserved on top of the conservative
    /// input+output token estimate when deciding whether a dictation
    /// would overflow `contextSize`. Pads against char→token estimate
    /// error and chat-template wrapping overhead.
    static let contextSafetyMargin: Int = 256

    /// Conservative chars-per-token divisor used to estimate token
    /// counts from string lengths without paying for the BPE tokenizer.
    /// 3.0 is below the empirical English (~3.8) and German (~3.5)
    /// averages — under-estimating tokens would let us slip past the
    /// pre-call overflow guard, so we err high (= more tokens per char).
    static let tokensPerCharDivisor: Int = 3

    /// Char-per-token multiplier for converting `LLMService.budgetTokens`
    /// (an output token budget) into a streaming char budget. 4 matches
    /// the OUTPUT side average (model tokens are typically slightly
    /// longer than input tokens for clean polished prose).
    static let charsPerOutputToken: Int = 4

    /// Pass-1 character count below which Formal mode skips the local
    /// LLM entirely and returns Pass-1 verbatim. The local Gemma 3 1B
    /// at Q4_K_M cannot reliably distinguish "example phrase inside the
    /// system prompt" from "actual user input" when the user input is
    /// too short to ground the model — observed 2026-05-27, where
    /// "Thanks." (7 chars) and "Thank you." (10 chars) both produced
    /// the identical hallucinated 65-char string "Please suggest five
    /// launch tagline ideas for a Mac dictation app." (the model
    /// locked onto the tagline example in the Formal system prompt).
    ///
    /// `TextPostProcessor.polishLiteral` (Pass-1) already capitalises
    /// the first letter and adds terminal punctuation, which is the
    /// entire useful polish for ack-style inputs — so skipping the LLM
    /// loses zero quality and removes the hallucination surface.
    ///
    /// 25 chars: above all common acks/greetings ("Sounds good to me.",
    /// "I'll be there soon.") and below the German Slogans trap
    /// (38 chars) so that case still exercises the language-drift
    /// and length-ratio guards.
    ///
    /// Local-only: cloud providers (Groq Llama 70B, Claude, GPT-4o)
    /// handle short inputs reliably and aren't subject to this
    /// example-bleed failure mode.
    static let shortInputBypassChars: Int = 25

    private init() {
        Task { [weak self] in
            await self?.installPrewarmHook()
            await self?.installBackgroundUnloadObservers()
        }
    }

    /// App-launch trigger: if the user has `.local` selected AND the model
    /// is already on disk, kick off the llama.cpp + Metal-shader compile in
    /// the background. Without this, the first Formal-mode dictation after
    /// install pays a 14–15 s freeze for Metal shader JIT compilation —
    /// macOS caches the compiled shaders in `~/Library/Caches/com.apple.metal/`
    /// so subsequent launches are fast, but the first user dictation is
    /// the worst place to surface a cold-load.
    ///
    /// Mirrors the WhisperKit pattern at
    /// `TranscriptionService.prewarmLocalWhisperIfReady` and is called
    /// alongside it from `SprichApp.applicationDidFinishLaunching`.
    @MainActor
    static func prewarmIfReady(settings: AppSettings) {
        // Touch `shared` so the actor's init runs and the prewarmHook +
        // background-unload observers install BEFORE any download flow
        // tries to call the hook.
        let service = LocalLLMService.shared
        guard settings.llmProvider.isLocal else { return }
        let spec = LocalLLMModelSpec.resolved(from: settings)
        guard let modelFile = LLMModelManager.shared.existingFile(for: spec) else { return }
        Task.detached(priority: .userInitiated) {
            do {
                try await service.prewarm(spec: spec, modelFile: modelFile)
                #if DEBUG
                print("[Sprich] Local LLM warm (\(spec.id))")
                #endif
            } catch {
                #if DEBUG
                print("[Sprich] Local LLM warm failed: \(error)")
                #endif
            }
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
                // See `Self.contextSize` for the sizing rationale and
                // the 2048 → 4096 → 8192 history.
                context: Self.contextSize,
                // 0.0 (greedy decoding) — Sprich is a text polisher, not a
                // creative writing tool. Same input must produce same output;
                // sampling at 0.3 caused two identical dictations to yield
                // different LLM outputs, which is the wrong behavior for a
                // transcription-cleanup product. Greedy also tends to follow
                // long structured prompts (formal-mode rules + destination
                // hints) more reliably on a 1B-parameter model than sampling
                // does. Cloud providers are pinned to 0 in `LLMService.swift`
                // for the same reason.
                temperature: 0.0,
                topK: 40,
                topP: 0.95,
                options: .init(
                    // Per-spec stop tokens — Gemma 3 uses `<end_of_turn>` /
                    // `<start_of_turn>`; Gemma 4 changed them to `<turn|>` /
                    // `<|turn>`. Sourced from the resolved spec so we never
                    // serve one family's tokens while running the other.
                    // Verified 2026-05-16 (G3) / 2026-05-29 (G4).
                    extraEOSTokens: Set(spec.eosTokens),
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
    ///
    /// For Formal mode, `inputText` is Pass-1 (literal-cleaned) text —
    /// `PipelineCoordinator` runs `polishLiteral` before calling here. For
    /// Custom mode it is the post-glossary STT result. Formal output is
    /// gated by `FormalOutputGuard` against a sentence-count contract; on
    /// breach we silently return `inputText` (the Pass-1 baseline).
    func cleanup(
        inputText: String,
        mode: TranscriptionMode,
        settings: AppSettings,
        surface: Surface = .generic
    ) async throws -> String {
        let sanitizedText = InputSanitizer.sanitize(inputText)
        guard !sanitizedText.isEmpty else {
            throw SprichError.emptyTranscription
        }

        // Short-input bypass — see `shortInputBypassChars` doc above for
        // the full rationale. On Formal mode, very short Pass-1 inputs
        // ("Thanks.", "Thank you.", "Got it.") are NOT sent to the local
        // LLM because Gemma 3 1B reliably hallucinates the in-prompt
        // tagline example for short user inputs. Pass-1 already handles
        // capitalization + terminal punctuation, which is the entire
        // useful polish at this length.
        if mode == .formal, sanitizedText.count < Self.shortInputBypassChars {
            #if DEBUG
            print("[Sprich] Formal guard fallback (local): short-input bypass (\(sanitizedText.count) chars < \(Self.shortInputBypassChars))")
            #endif
            return sanitizedText
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

        // Resolve the user-selected tier (Standard 1B / High Quality E2B)
        // once for this call. Used for lazy-load AND for the post-cleanup
        // background reprewarm so we reload the SAME spec the user is on.
        let activeSpec = LocalLLMModelSpec.resolved(from: settings)

        // Lazy-load on cold start — first Formal dictation after launch
        // when prewarm hasn't fired yet. Subsequent calls hit the cached
        // client. If the loaded client is a DIFFERENT spec than the one the
        // user just switched to, drop it and load the selected one.
        if client != nil, loadedSpecID != activeSpec.id {
            unload()
        }
        if client == nil {
            try await loadIfNeeded(spec: activeSpec)
        }
        guard let client else {
            throw SprichError.localLLMNotReady("Model failed to load. Check Settings → Providers → Local LLM, or switch to a cloud provider.")
        }

        // Concurrent-generation guard — see `isGenerating` doc above.
        // PipelineCoordinator already drops new dictations while .processing,
        // so reaching here with isGenerating=true should be impossible in
        // normal flow. This is defense-in-depth.
        if isGenerating {
            throw SprichError.localLLMNotReady("Sprich is still finishing the previous dictation. Please wait a moment and try again.")
        }
        isGenerating = true
        defer { isGenerating = false }

        let input = LLMInput.chat([
            .system(systemPrompt),
            .user(sanitizedText)
        ])

        // Pre-call context-budget guard. llama.cpp throws
        // `LLMError.failedToDecode("context size exceeded[N < M]")` when
        // a decode tries to grow the KV cache past `contextSize`, and on
        // the FOLLOWING dictation can crash with a `fatalError` in
        // `LocalLLMClientLlama/Batch.swift:20 Unexpectedly found nil`
        // because the context isn't reliably reset by the library after
        // a decode-time throw. Both observed 2026-05-27 on Formal +
        // email surface.
        //
        // For Formal mode we fall back to Pass-1 silently so the user
        // still gets the literal cleanup — same UX as any other guard
        // fallback. Custom mode has no Pass-1 to fall back to, so we
        // surface a clean error rather than mute it.
        let inputCharsEstimate = systemPrompt.count + sanitizedText.count
        let inputTokensEstimate = inputCharsEstimate / Self.tokensPerCharDivisor
        let outputTokenBudget = LLMService.budgetTokens(for: sanitizedText)
        let neededContext = inputTokensEstimate + outputTokenBudget + Self.contextSafetyMargin
        if neededContext > Self.contextSize {
            #if DEBUG
            print("[Sprich] Formal guard fallback (local): pre-call context overflow (need ~\(neededContext) tokens, have \(Self.contextSize))")
            #endif
            if mode == .formal {
                return sanitizedText
            } else {
                throw SprichError.localLLMNotReady("Dictation too long for the local model right now. Try shorter, or switch to a cloud provider in Settings.")
            }
        }

        lastUsedAt = Date()

        // Stream tokens with a hard char-budget early-stop. Without this,
        // when the 1B model decides a dictation warrants a 9-sentence
        // list (the tagline trap on test #2, 2026-05-27), it ran for
        // 11.5 s before the post-call sentence-count guard rejected it.
        // The stream is short-circuited well before that — the Generator
        // gets deinit'd when the for-await exits via `break`, which
        // halts further llama.cpp decode steps.
        //
        // The library's `extraEOSTokens` stops (`<end_of_turn>` /
        // `<start_of_turn>`) handle the normal "model finishes cleanly"
        // case. The char budget catches runaway generation only.
        let charBudget = outputTokenBudget * Self.charsPerOutputToken
        var raw = ""
        var earlyStopped = false
        do {
            let generator = try client.textStream(from: input)
            for try await chunk in generator {
                raw += chunk
                if raw.count > charBudget {
                    #if DEBUG
                    print("[Sprich][LocalLLM] early-stop at \(raw.count) chars (budget=\(charBudget))")
                    #endif
                    earlyStopped = true
                    break
                }
            }
        } catch {
            // The library's context can land in an inconsistent state
            // after a mid-decode throw — the next dictation then hits a
            // `fatalError` in `Batch.swift:20`. Drop the client so the
            // next call lazy-reloads from a clean state. ~520 ms
            // re-load cost vs. an app crash is the right tradeoff.
            #if DEBUG
            print("[Sprich][LocalLLM] generation error, unloading client: \(error)")
            #endif
            unload()
            scheduleBackgroundPrewarm(spec: activeSpec)
            throw error
        }

        // Breaking out of the for-await loop mid-generation leaves the
        // llama.cpp context in a half-decoded state — the iterator goes
        // out of scope but the underlying KV cache is not reset, and the
        // NEXT call to `client.textStream(...)` hits a
        // `Batch.swift:20: Unexpectedly found nil` fatalError on the
        // poisoned context. Natural EOS (the model emits its end-of-text
        // token and the for-await exits without `break`) is clean — the
        // library handles that path correctly. So we unload only on
        // early-stop. Kick a background prewarm so the user's next
        // dictation doesn't pay the cold-load latency.
        if earlyStopped {
            unload()
            scheduleBackgroundPrewarm(spec: activeSpec)
        }

        // Formal mode: enforce the two-pass contract (sentence count
        // within ±1 of Pass 1, non-empty after artifact cleanup). On
        // breach the guard returns `sanitizedText` (== Pass 1) silently.
        // Custom mode is user-driven — no contract to enforce, just run
        // the same artifact cleanup as before.
        if mode == .formal {
            let effectiveSurface: Surface = settings.adaptToSurface ? surface : .generic
            let result = FormalOutputGuard.enforce(
                pass1Text: sanitizedText,
                rawLLMOutput: raw,
                language: settings.preferredLanguage,
                surface: effectiveSurface
            )
            #if DEBUG
            if result.usedFallback {
                print("[Sprich] Formal guard fallback (local): \(result.fallbackReason ?? "?")")
            }
            #endif
            // Deterministic shape normalisation — ensures email greeting/
            // sign-off get blank-line framing even when Gemma 3 1B produced
            // only half the shape (observed 2026-05-29). No-op on
            // non-email surfaces.
            return TextPostProcessor.normalizeShape(result.text, surface: effectiveSurface)
        } else {
            let cleaned = FormalOutputGuard.stripWrappingQuotes(
                FormalOutputGuard.stripPreamble(raw)
            )
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    /// Re-prewarm the default-spec model in the background after a
    /// post-cleanup `unload()` (early-stop or generation throw). The
    /// user's NEXT dictation can then hit a warm client even though
    /// the previous one poisoned the context. Idempotent — `prewarm`
    /// short-circuits if the client is already loaded.
    private func scheduleBackgroundPrewarm(spec: LocalLLMModelSpec = .defaultSpec) {
        Task.detached(priority: .userInitiated) {
            let modelFile = await MainActor.run {
                LLMModelManager.shared.existingFile(for: spec)
            }
            guard let modelFile else { return }
            do {
                try await LocalLLMService.shared.prewarm(spec: spec, modelFile: modelFile)
                #if DEBUG
                print("[Sprich][LocalLLM] background reprewarm ✅")
                #endif
            } catch {
                #if DEBUG
                print("[Sprich][LocalLLM] background reprewarm failed: \(error)")
                #endif
            }
        }
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

}
