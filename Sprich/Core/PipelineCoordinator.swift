import Foundation
import AppKit

/// Orchestrates the full dictation pipeline:
/// Hotkey → Record → STT → (optional LLM Cleanup) → Paste
///
/// Literal mode: STT only — Whisper output is clean enough.
/// Formal mode: STT → Groq LLM (llama, ~200ms) → Paste.
@MainActor
class PipelineCoordinator {
    private let appState: AppState
    private let recorder: AudioRecorder
    private let sttService = TranscriptionService()
    private let llmService = LLMService()

    private var currentMode: TranscriptionMode?
    /// Bundle ID of the frontmost app captured at hotkey-press time.
    /// Used later to resolve the destination `Surface` for Formal mode.
    private var capturedBundleID: String?
    /// Localized name of the frontmost app at hotkey-press time
    /// ("Slack", "Mail"). Persisted into the HistoryEntry alongside
    /// the dictation so History rows read user-friendly rather than
    /// raw bundle-ID. nil when capture fails.
    private var capturedAppName: String?
    /// PID of the frontmost app captured at hotkey-press time. Captured
    /// BEFORE the RecordingOverlay panel shows — otherwise
    /// `NSWorkspace.frontmostApplication` returns Sprich's overlay and
    /// any PID-scoped Accessibility observer (CorrectionLearner) would
    /// attach to the wrong process. See P1-PRD-24-pre.
    private var capturedPid: pid_t?
    /// Provider resolved at hotkey-press time. May differ from the
    /// user's configured choice when we auto-fall-back to Local while
    /// offline. Stashed so `stopAndProcess` uses the same provider
    /// that `startRecording` committed to.
    private var activeProvider: STTProviderType?

    /// When set, transcription output is delivered to this closure
    /// instead of pasted into the focused app via `TextInserter`. Used
    /// by onboarding step 3 to surface the "Try it now" transcription
    /// inside the onboarding window. Set on view-appear and cleared on
    /// view-disappear.
    ///
    /// Errors and the auto-stop continuation hint are intentionally NOT
    /// routed through the intercept — those are pipeline-internal
    /// affordances meant for the real paste target.
    var interceptOutput: ((String) -> Void)?

    /// Single delivery point for transcription output. Honors
    /// `interceptOutput` if set; otherwise pastes via `TextInserter`.
    private func deliver(_ text: String) async {
        if let intercept = interceptOutput {
            #if DEBUG
            print("[Sprich] deliver: routing \(text.count) chars to interceptOutput")
            #endif
            intercept(text)
            return
        }
        #if DEBUG
        print("[Sprich] deliver: no interceptOutput set, pasting via TextInserter (\(text.count) chars)")
        #endif
        // Pass the target captured at record time so TextInserter can
        // re-activate it if the user switched apps during the LLM wait, and
        // fall back to clipboard + notification if it's gone. Never lose the
        // transcription to a wrong-app paste.
        await TextInserter.insert(
            text,
            targetPid: capturedPid,
            targetBundleID: capturedBundleID,
            targetAppName: capturedAppName
        )
    }

    /// Decide which provider to use for a new dictation. Returns the
    /// user's configured choice unless:
    /// (a) that choice is a cloud provider, (b) there's no usable
    /// network path, and (c) the local model is already downloaded.
    /// In that case we transparently use `.local` for this dictation
    /// only — settings are not mutated.
    private func effectiveProviderForThisDictation() -> STTProviderType {
        let configured = appState.settings.sttProvider
        if configured.isLocal { return configured }
        guard !NetworkReachability.shared.isReachable else { return configured }
        guard WhisperModelManager.shared.state.isReady else { return configured }
        return .local
    }

    /// Build a state-aware message for when Local is the chosen provider
    /// but the model isn't ready. The three interesting cases produce
    /// different guidance — "still downloading" is nothing the user
    /// needs to act on, whereas "not downloaded" is.
    private func localModelNotReadyMessage() -> (String, String) {
        switch WhisperModelManager.shared.state {
        case .downloading(let p):
            return (
                "Local Whisper is still downloading",
                "Progress: \(Int(p * 100))%. Hotkeys will work as soon as it finishes. You can keep working — this runs in the background."
            )
        case .preparing:
            return (
                "Local Whisper is finalising",
                "One-time Core ML compile (usually 10–30 seconds). Try your hotkey again in a moment."
            )
        case .failed(let reason):
            return (
                "Local Whisper download failed",
                "\(reason) — open Sprich Settings → Providers → Local and click Download to retry."
            )
        default:
            return (
                "Local Whisper model not downloaded",
                "Open Sprich Settings → Providers → Local to download. Local is your default — Sprich will not silently switch to an online provider."
            )
        }
    }

    init(appState: AppState) {
        self.appState = appState
        // Honor user-configured safety cap.
        self.recorder = AudioRecorder(
            maxDuration: TimeInterval(appState.settings.maxRecordingDuration)
        )

        // Wire audio level updates to the overlay
        recorder.onAudioLevel = { level in
            Task { @MainActor in
                RecordingOverlayController.shared.updateAudioLevel(level)
            }
        }

        // When the recording hits the user's configured time cap mid-flight,
        // process the captured audio through the normal pipeline instead
        // of dropping it. Nothing-is-lost from the user's perspective,
        // and a follow-up notice tells them to hotkey-again to continue.
        recorder.onMaxDurationReached = { [weak self] wav in
            Task { @MainActor in
                await self?.processAutoStoppedAudio(wav)
            }
        }
    }

    /// Toggle recording for a specific mode (used in toggle input mode).
    func toggle(mode: TranscriptionMode) async {
        if case .recording(let currentMode) = appState.status, currentMode == mode {
            await stopAndProcess()
        } else if case .recording = appState.status {
            recorder.cancelRecording()
            await startRecording(mode: mode)
        } else {
            await startRecording(mode: mode)
        }
    }

    /// Start recording for a given mode (used by hold-to-talk).
    func startRecording(mode: TranscriptionMode) async {
        #if DEBUG
        print("[Sprich] startRecording(\(mode.displayName)) — status=\(appState.status)")
        #endif

        // Refuse to start a new dictation while the previous one is still
        // being post-processed (STT → LLM → paste). Without this guard,
        // a fast hotkey re-press could start a fresh recording while the
        // previous LLM call is mid-flight. Both calls then hit the local
        // llama.cpp client concurrently — its batch state is NOT safe for
        // concurrent generate() and crashes in
        // `LocalLLMClientLlama/Batch.swift:20 Unexpectedly found nil`.
        // Drop the request silently; the user can re-press once the paste
        // lands. Belt-and-suspenders: `LocalLLMService.cleanup` also
        // refuses concurrent generation, so even if this guard ever fails
        // (e.g. status raced back to .ready before LLM finished), llama
        // can't crash.
        if case .processing = appState.status {
            #if DEBUG
            print("[Sprich] startRecording dropped — still processing previous dictation")
            #endif
            return
        }

        // Trial / license gate (P1-PRD-08). Hard-lock per D4 — no
        // degraded mode at expiry, just point the user at the buy flow.
        if !TrialState.shared.isEntitled {
            await handleTrialBlocked()
            return
        }

        if !Permissions.isMicrophoneGranted() {
            let granted = await Permissions.requestMicrophone()
            if !granted {
                surfaceBlockingError(
                    title: "Microphone access denied",
                    body: "Grant Sprich microphone permission in System Settings → Privacy & Security → Microphone."
                )
                return
            }
        }

        // Resolve the provider we'll actually use for this dictation.
        // Auto-fallback to .local if the user's cloud choice is unreachable
        // AND a local model is ready on disk. This is session-only — the
        // user's saved preference is untouched.
        let provider = effectiveProviderForThisDictation()
        #if DEBUG
        if provider != appState.settings.sttProvider {
            print("[Sprich] Network offline — falling back to \(provider.displayName) for this dictation")
        }
        #endif

        // STT readiness check: cloud providers need an API key;
        // local (on-device Whisper) needs the model downloaded.
        // Literal mode doesn't need an LLM so we only check STT here.
        //
        // When a guard fails the recording overlay never appears, so we
        // surface the error by pasting it inline where the user was
        // about to dictate. See `surfaceBlockingError` for the details.
        if provider.isLocal {
            if !WhisperModelManager.shared.state.isReady {
                let (title, body) = localModelNotReadyMessage()
                surfaceBlockingError(title: title, body: body)
                return
            }
            // Model bytes are on disk, but that's not the same as
            // "pipe is warmed and ready to transcribe". Core ML
            // compile + weight load take seconds-to-minutes depending
            // on hardware and whether the compiled form is cached
            // yet. Without this guard, a hotkey press during warmup
            // leads to recording → release → `transcribe()` awaiting
            // `loadingTask.value` → an indefinitely-stuck overlay
            // with nothing pasted.
            if !WhisperModelManager.shared.isPipeReady {
                surfaceBlockingError(
                    title: "Sprich is still warming up",
                    body: "Whisper is loading (first launch after install takes a few minutes; subsequent launches are faster). Try again in a moment — the menubar will show Ready when it's done."
                )
                return
            }
            // Kick off a parallel warm-load so the pipe is ready by the
            // time the user releases the hotkey. If the load is already
            // complete this is cheap (early-return inside `prewarm`).
            TranscriptionService.prewarmLocalWhisperIfReady(
                model: appState.settings.localWhisperModel
            )
        } else if KeychainManager.retrieve(key: provider.keychainKey) == nil {
            // Cloud configured but no key. If we're offline AND the local
            // model is on disk, effectiveProviderForThisDictation() already
            // would have flipped us to .local — so reaching here with a
            // missing key means: cloud configured, online, key missing.
            //
            // P1-UX-15: route through MissingKeyBanner (system notification
            // + deep-link) instead of the inline-paste modal. The hotkey
            // misfires almost always happen while the user is in another
            // app — the modal alert kept landing on a UI the user wasn't
            // looking at.
            await MainActor.run {
                MissingKeyBanner.present(providerName: provider.displayName)
            }
            appState.status = .ready
            return
        }

        // Stash the resolved provider so stopAndProcess uses the same
        // one — reachability can flip between start and stop.
        activeProvider = provider

        do {
            currentMode = mode
            // Snapshot the frontmost app BEFORE any HUD appears. Sprich's
            // panel is non-activating, so this remains the user's target.
            // PID capture must happen here too — once the overlay shows,
            // NSWorkspace.frontmostApplication returns Sprich's own panel
            // and CorrectionLearner would attach to the wrong process.
            let front = NSWorkspace.shared.frontmostApplication
            capturedBundleID = front?.bundleIdentifier
            capturedPid = front?.processIdentifier
            capturedAppName = front?.localizedName
            #if DEBUG
            print("[Sprich] captured target PID=\(capturedPid ?? -1) bundle=\(capturedBundleID ?? "?")")
            #endif
            try recorder.startRecording()
            appState.status = .recording(mode)
            RecordingOverlayController.shared.show(
                mode: mode,
                badge: appState.settings.badgeLetter(for: mode),
                displayName: appState.settings.displayName(for: mode)
            )
        } catch {
            surfaceBlockingError(
                title: "Recording failed",
                body: error.localizedDescription
            )
        }
    }

    /// Handle audio that AudioRecorder auto-stopped after hitting the
    /// `maxRecordingDuration` cap. We run it through the full pipeline
    /// (so the user's N minutes of speech aren't wasted) and append a
    /// short "continue with hotkey" notice so they know they hit the
    /// cap and what to do. Mode is whatever was in flight when the
    /// cap tripped.
    func processAutoStoppedAudio(_ audioData: Data) async {
        guard let mode = currentMode else { return }
        // Flip UI to processing so the overlay shows the spinner for
        // the STT+LLM leg — exact same visual as a hotkey release.
        appState.status = .processing
        RecordingOverlayController.shared.showProcessing()

        do {
            let result = try await runPipeline(audioData: audioData, mode: mode)
            let finalText = result.text
            // Append the "keep going" hint inline so it lands in the
            // same text field as the transcription. New line + hint
            // keeps it readable without a huge visual thump.
            let capSeconds = appState.settings.maxRecordingDuration
            let continuation = "\n\n[Sprich: recording reached the \(capSeconds)-second limit — press the hotkey again to continue.]"
            await deliver(finalText + continuation)
            // Record the auto-stopped dictation into history too — only
            // the pre-continuation text, since the bracket is Sprich's
            // own message, not user content. v1.0.11: enrich targetApp
            // with the browser brand name when known ("App — Brand");
            // falls back to bare app name for Literal / native / TCC-denied.
            if interceptOutput == nil {
                let label = WebSurfaceLabel.formatTargetApp(
                    appName: capturedAppName,
                    webHost: result.webHost
                )
                HistoryStore.shared.record(
                    text: finalText,
                    mode: mode,
                    targetApp: label
                )
            }
        } catch {
            #if DEBUG
            print("[Sprich] ❌ Auto-stop pipeline error: \(error)")
            #endif
            surfaceBlockingError(
                title: "Recording auto-stopped at the time limit, but transcription failed",
                body: (error as? SprichError)?.userFacingMessage ?? error.localizedDescription
            )
        }

        RecordingOverlayController.shared.dismiss()
        appState.status = .ready
        currentMode = nil
        activeProvider = nil
        capturedPid = nil
        capturedBundleID = nil
        capturedAppName = nil
    }

    /// Output of `runPipeline` — final cleaned text + (for browser
    /// dictations) the resolved tab host so the caller can label the
    /// History row "Google Chrome — Gmail". `webHost` is nil for Literal
    /// mode, native apps, unsupported browsers, or failed reads.
    struct PipelineResult {
        let text: String
        let webHost: String?
    }

    /// The STT→glossary→(LLM or local polish) path, factored out of
    /// `stopAndProcess` so auto-stopped recordings can share it. Returns
    /// the final cleaned text + URL host ready for paste / history label.
    /// Does NOT paste — the caller decides whether to paste the raw
    /// result or append a hint.
    private func runPipeline(
        audioData: Data,
        mode: TranscriptionMode
    ) async throws -> PipelineResult {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Formal now uses the same Whisper bias as Literal: ship the
        // punctuation hint so Whisper does the punctuation/capitalization
        // work upstream. Pass 1 of the two-pass Formal pipeline is exactly
        // the Literal-mode output, so the bias must match.
        let whisperPrompt = TextPostProcessor.whisperBiasPrompt(
            glossaryTerms: appState.settings.glossaryTerms,
            includePunctuationHint: (mode == .literal || mode == .formal)
        )

        // Surface resolution only for Formal+adaptToSurface. Kicked in
        // parallel so it overlaps with STT round-trip rather than
        // serializing behind it. `Resolved` carries both the LLM-routing
        // surface AND the browser URL host (for History label enrichment).
        let bundleIDSnapshot = capturedBundleID
        let shouldResolveSurface = (mode == .formal) && appState.settings.adaptToSurface
        let surfaceTask: Task<SurfaceDetector.Resolved, Never>? = shouldResolveSurface
            ? Task.detached(priority: .userInitiated) {
                await SurfaceDetector.resolve(bundleID: bundleIDSnapshot)
            }
            : nil

        let provider = activeProvider ?? appState.settings.sttProvider
        let rawTranscript = try await sttService.transcribe(
            audioData: audioData,
            provider: provider,
            language: appState.settings.preferredLanguage,
            prompt: whisperPrompt
        )

        #if DEBUG
        let t1 = CFAbsoluteTimeGetCurrent()
        print("[Sprich] STT: \(Int((t1 - t0) * 1000))ms \(InputSanitizer.redactForLog(rawTranscript))")
        #endif

        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PipelineResult(text: "", webHost: nil) }

        let corrected = TextPostProcessor.applyGlossary(
            rawTranscript,
            replacements: appState.settings.glossaryReplacements
        )

        // Pass 1 of the two-pass Formal pipeline — also the entire
        // Literal-mode output. Custom mode bypasses Pass 1 so user-authored
        // prompts can operate on the raw post-glossary text.
        let pass1Text = (mode == .formal || mode == .literal)
            ? TextPostProcessor.polishLiteral(corrected)
            : corrected

        if mode == .literal {
            return PipelineResult(text: pass1Text, webHost: nil)
        }

        RecordingOverlayController.shared.showTranscribedText(pass1Text)
        let resolved = await surfaceTask?.value ?? .generic
        let finalText = try await llmService.cleanup(
            inputText: pass1Text,
            mode: mode,
            settings: appState.settings,
            surface: resolved.surface
        )
        #if DEBUG
        let t2 = CFAbsoluteTimeGetCurrent()
        print("[Sprich] LLM: \(Int((t2 - t1) * 1000))ms \(InputSanitizer.redactForLog(finalText))")
        #endif
        return PipelineResult(text: finalText, webHost: resolved.webHost)
    }

    /// Stop recording and process through the pipeline.
    // MARK: - Whisper silence-hallucination filter

    /// Canned phrases Whisper emits when fed silence/noise with no real speech
    /// (a well-known Whisper failure mode). NEVER a legitimate dictation, so
    /// dropped regardless of signal. The energy gate in `AudioRecorder` catches
    /// most silent clips; this is the safety net for clips with faint ambient
    /// noise that clear it but still transcribe to a canned phrase.
    private static let alwaysDropHallucinations: Set<String> = [
        "thanks for watching", "thank you for watching", "thanks for watching everyone",
        "thank you for watching this video", "transcription by castingwords", "castingwords",
        "subtitles by the amara org community", "subtitles by amara org", "amara org",
        "please subscribe", "subscribe to my channel", "like and subscribe"
    ]

    /// Short phrases that ARE plausible real dictations ("thanks", "okay") but
    /// are also Whisper's favourite silence-hallucinations. Dropped ONLY when the
    /// clip carried no real speech energy (peak below the speech threshold), so a
    /// genuinely-spoken "Thanks." (which has energy) is preserved.
    private static let lowEnergyHallucinations: Set<String> = [
        "thank you", "thank you very much", "thanks", "you", "bye", "okay", "ok", "so", "um", "uh"
    ]

    /// Peak RMS below which a canned phrase is treated as a hallucination rather
    /// than real speech. Above the silence gate, below normal speech energy.
    private static let hallucinationSpeechPeak: Float = 0.045

    /// Lowercase, strip non-alphanumerics, collapse whitespace — for matching a
    /// transcript against the canned-phrase sets above.
    private static func normalizeForHallucinationMatch(_ s: String) -> String {
        let mapped = s.lowercased().unicodeScalars.map { sc -> Character in
            CharacterSet.alphanumerics.contains(sc) ? Character(sc) : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Returns the matched canned phrase if `transcript` is a Whisper
    /// silence-hallucination that should be dropped, else nil. The returned
    /// string is always a hardcoded denylist member (not user content), so it is
    /// safe to log.
    private static func whisperHallucinationMatch(_ transcript: String, peak: Float) -> String? {
        let norm = normalizeForHallucinationMatch(transcript)
        guard !norm.isEmpty else { return nil }
        if alwaysDropHallucinations.contains(norm) { return norm }
        if lowEnergyHallucinations.contains(norm), peak < hallucinationSpeechPeak { return norm }
        return nil
    }

    func stopAndProcess() async {
        #if DEBUG
        print("[Sprich] stopAndProcess() entered — status=\(appState.status), currentMode=\(currentMode?.displayName ?? "nil")")
        #endif
        guard case .recording = appState.status,
              let mode = currentMode else {
            #if DEBUG
            print("[Sprich] stopAndProcess ⚠️ guard failed — returning early (status or mode wrong)")
            #endif
            return
        }

        appState.status = .processing
        RecordingOverlayController.shared.showProcessing()
        #if DEBUG
        print("[Sprich] stopAndProcess: status flipped to .processing, overlay → processing")
        #endif

        do {
            let pipelineStart = CFAbsoluteTimeGetCurrent()

            // Carries the browser tab host (e.g. "mail.google.com") out
            // of the LLM-cleanup branch so the history-record block below
            // can format the target-app label as "Google Chrome — Gmail".
            // Stays nil for Literal mode, native apps, or when the
            // browser AppleScript read failed / was denied — record()
            // falls back to bare app name in that case.
            var resolvedWebHost: String? = nil

            // 1. Stop recording and get audio data
            guard let audioData = try recorder.stopRecording() else {
                #if DEBUG
                print("[Sprich] stopAndProcess: recorder.stopRecording returned nil — no audio, dismissing")
                #endif
                RecordingOverlayController.shared.dismiss()
                appState.status = .ready
                return
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            #if DEBUG
            print("[Sprich] Audio export: \(Int((t1 - pipelineStart) * 1000))ms (\(audioData.count / 1024)KB)")
            #endif

            // 2. Build Whisper bias prompt. Formal shares Literal's
            // punctuation hint so Whisper does the punctuation work
            // upstream — Pass 1 of the two-pass Formal pipeline is the
            // Literal-mode output, so the bias must match.
            let whisperPrompt = TextPostProcessor.whisperBiasPrompt(
                glossaryTerms: appState.settings.glossaryTerms,
                includePunctuationHint: (mode == .literal || mode == .formal)
            )

            // 3. Kick off surface resolution in parallel with STT — but
            // ONLY for Formal mode with the setting on. Literal and
            // Custom never consume the result, and launching AppleScript
            // against a browser frontmost app can (a) trigger a TCC
            // Automation prompt that gates CGEvent dispatch system-wide
            // and (b) burn main-thread cycles via Apple Events bouncing.
            // Keeping Literal's release-to-paste path zero-cost is the
            // whole point of Literal mode.
            let bundleIDSnapshot = capturedBundleID
            let shouldResolveSurface = (mode == .formal) && appState.settings.adaptToSurface
            let surfaceTask: Task<SurfaceDetector.Resolved, Never>? = shouldResolveSurface
                ? Task.detached(priority: .userInitiated) {
                    await SurfaceDetector.resolve(bundleID: bundleIDSnapshot)
                }
                : nil

            // 4. Transcribe via STT. Use the provider resolved at
            // startRecording time — the user may have been offline
            // then and we already committed to that fallback.
            let provider = activeProvider ?? appState.settings.sttProvider
            #if DEBUG
            print("[Sprich] stopAndProcess: calling sttService.transcribe(provider=\(provider.displayName))…")
            #endif
            let rawTranscript = try await sttService.transcribe(
                audioData: audioData,
                provider: provider,
                language: appState.settings.preferredLanguage,
                prompt: whisperPrompt
            )
            #if DEBUG
            print("[Sprich] stopAndProcess: sttService.transcribe returned \(rawTranscript.count) chars")
            #endif
            let t2 = CFAbsoluteTimeGetCurrent()
            #if DEBUG
            print("[Sprich] STT: \(Int((t2 - t1) * 1000))ms \(InputSanitizer.redactForLog(rawTranscript))")
            #endif

            guard !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                RecordingOverlayController.shared.dismiss()
                appState.status = .ready
                return
            }

            // Silence-hallucination filter: even past the recorder's energy gate,
            // a faint-noise clip can transcribe to a canned Whisper phrase
            // ("Thank you.", "Transcription by CastingWords."). Drop those so we
            // never paste — or auto-learn a correction from — phantom text.
            if let hallucination = Self.whisperHallucinationMatch(rawTranscript, peak: recorder.lastPeakLevel) {
                #if DEBUG
                print(String(format: "[Sprich] stopAndProcess: dropping Whisper silence-hallucination \"%@\" (peak %.4f)",
                             hallucination, recorder.lastPeakLevel))
                #endif
                RecordingOverlayController.shared.dismiss()
                appState.status = .ready
                return
            }

            // 4. Apply glossary replacements post-STT (runs for every mode)
            let corrected = TextPostProcessor.applyGlossary(
                rawTranscript,
                replacements: appState.settings.glossaryReplacements
            )

            // 5. Pass 1 of the two-pass Formal pipeline — also the entire
            // Literal-mode output. Custom mode bypasses Pass 1 so
            // user-authored prompts can operate on the raw post-glossary
            // text.
            let pass1Text = (mode == .formal || mode == .literal)
                ? TextPostProcessor.polishLiteral(corrected)
                : corrected

            let finalText: String

            if mode == .literal {
                finalText = pass1Text
                #if DEBUG
                print("[Sprich] Literal mode — skipping LLM (Pass 1 only)")
                #endif
            } else {
                // Formal + Custom: route through the LLM. Formal sends
                // Pass-1 (literal-cleaned) text; Custom sends the raw
                // post-glossary text untouched.
                RecordingOverlayController.shared.showTranscribedText(pass1Text)

                // Await the surface resolution launched before STT.
                // `nil` when adaptToSurface is off → fall back to
                // `.generic`, which leaves the prompt unchanged.
                // Worst case (browser AppleScript denied) also returns
                // `.generic` from the detector.
                let resolved = await surfaceTask?.value ?? .generic
                #if DEBUG
                print("[Sprich] Surface: \(bundleIDSnapshot ?? "?") → \(resolved.surface.debugLabel) (host=\(resolved.webHost ?? "—"))")
                #endif

                finalText = try await llmService.cleanup(
                    inputText: pass1Text,
                    mode: mode,
                    settings: appState.settings,
                    surface: resolved.surface
                )
                // Stash the host so the post-deliver history record can
                // format `targetApp` as "App — Brand" without re-running
                // the AppleScript. `resolvedWebHost` is declared at the
                // top of the `do` block.
                resolvedWebHost = resolved.webHost
                let t3 = CFAbsoluteTimeGetCurrent()
                #if DEBUG
                print("[Sprich] LLM: \(Int((t3 - t2) * 1000))ms \(InputSanitizer.redactForLog(finalText))")
                #endif
            }

            // 4. Paste (or intercept, when onboarding's "Try it now" is active)
            await deliver(finalText)
            let tEnd = CFAbsoluteTimeGetCurrent()
            #if DEBUG
            print("[Sprich] ✅ Total: \(Int((tEnd - pipelineStart) * 1000))ms")
            #endif

            // P1-PRD-12 — record into the 30-day rolling History store.
            // Skip when the onboarding intercept was active (the "Try it
            // now" surface is not a real dictation the user pasted
            // anywhere) and when the text is empty.
            //
            // v1.0.11 — enrich `targetApp` with the browser brand name
            // when known: "Google Chrome" → "Google Chrome — Gmail".
            // `resolvedWebHost` is non-nil only for Formal+adaptToSurface
            // dictations in a supported browser with Automation TCC
            // granted; everywhere else this falls back to bare app name.
            if interceptOutput == nil {
                let label = WebSurfaceLabel.formatTargetApp(
                    appName: capturedAppName,
                    webHost: resolvedWebHost
                )
                HistoryStore.shared.record(
                    text: finalText,
                    mode: mode,
                    targetApp: label
                )
            }

            // P1-PRD-24 — start watching the target app for a user
            // correction of `finalText` within 30 s. Skip when the
            // dictation was intercepted by onboarding (no real paste
            // target) or when the user disabled auto-learn. We need
            // the target PID captured at hotkey-press time — without
            // it, the AXObserver would attach to Sprich's own panel.
            if appState.settings.autoLearnEnabled,
               interceptOutput == nil,
               let targetPid = capturedPid {
                startAutoLearn(targetPid: targetPid, originalText: finalText, mode: mode)
            }

            RecordingOverlayController.shared.dismiss()
            appState.status = .ready

        } catch {
            RecordingOverlayController.shared.dismiss()

            // P1-UX-15: SprichError.missingAPIKey gets the non-modal
            // MissingKeyBanner treatment (system notification + deep-link
            // to AI Models) instead of the inline-paste modal. All other
            // errors still go through the existing visible-error surface.
            if let sprichError = error as? SprichError,
               case let .missingAPIKey(provider) = sprichError {
                await MainActor.run {
                    MissingKeyBanner.present(providerName: provider)
                }
                appState.status = .ready
                currentMode = nil
                return
            }

            let errorMessage: String
            if let sprichError = error as? SprichError {
                errorMessage = sprichError.userFacingMessage
            } else {
                errorMessage = error.localizedDescription
            }

            #if DEBUG
            print("[Sprich] ❌ Pipeline error: \(errorMessage) — raw: \(error)")
            #endif

            // Use the same visible-error surface the pre-recording guards
            // use. `surfaceBlockingError` also handles the auto-clear of
            // the error status 3 s later, so no need to repeat that here.
            surfaceBlockingError(title: "Sprich Error", body: errorMessage)
        }

        currentMode = nil
        activeProvider = nil
        capturedPid = nil
        capturedBundleID = nil
        capturedAppName = nil
    }

    /// P1-PRD-24 — hook CorrectionLearner up for a 30 s window after a
    /// successful dictation. When a correction passes all guardrails we
    /// append it to `glossaryReplacements` silently and surface a small
    /// non-interactive toast so the user knows it happened. No
    /// confirmation step — wrong learns are removed from Settings →
    /// Dictionary.
    private func startAutoLearn(targetPid: pid_t, originalText: String, mode: TranscriptionMode) {
        CorrectionLearner.shared.watchForCorrection(
            targetPid: targetPid,
            originalText: originalText,
            mode: mode,
            settings: appState.settings
        ) { [weak self] from, to in
            Task { @MainActor in
                guard let self else { return }
                // Case-insensitive dedup against existing entries.
                if self.appState.settings.glossaryReplacements
                    .contains(where: { $0.from.lowercased() == from.lowercased() }) {
                    return
                }
                self.appState.settings.glossaryReplacements.append(
                    GlossaryReplacement(from: from, to: to)
                )
                self.appState.saveSettings()
                CorrectionBannerController.shared.present(from: from, to: to)
            }
        }
    }

    /// Cancel any in-progress recording.
    func cancel() {
        recorder.cancelRecording()
        currentMode = nil
        activeProvider = nil
        capturedPid = nil
        capturedBundleID = nil
        capturedAppName = nil
        appState.status = .ready
        RecordingOverlayController.shared.dismiss()
    }

    /// Gate path when the trial is expired or the user isn't signed in.
    /// We surface a blocking error AND raise the appropriate window
    /// (sign-in vs. trial-expired) so the next click is purposeful.
    private func handleTrialBlocked() async {
        let entitlement = TrialState.shared.entitlement
        let title: String
        let body: String
        switch entitlement {
        case .signedOut, .unknown:
            title = "Sprich needs you to sign in"
            body = "Sign in with your email to start your 7-day free trial. Open the menubar icon → Account."
        case .trialExpired:
            title = "Your 7-day Sprich trial has ended"
            body = "Buy a lifetime license at sprichapp.com/pricing to keep dictating. The buy window just opened."
        case .deviceBlocked:
            title = "This device is linked to another Sprich account"
            body = TrialState.shared.lastError
                ?? "Sign in with the account that first claimed this Mac, or email support@sprichapp.com to release the device."
        case .trialActive, .licensed:
            // Should not reach here; isEntitled returned false but the
            // enum says active — recompute by attempting validation
            // and let the user retry.
            await TrialState.shared.validateNow()
            return
        }
        surfaceBlockingError(title: title, body: body)

        await MainActor.run {
            if let delegate = NSApp.delegate as? AppDelegate {
                if entitlement == .trialExpired {
                    delegate.showTrialLockWindow()
                }
            }
        }
    }

    // MARK: - Error surfacing

    /// Surface a fatal-for-this-dictation error by pasting it inline into
    /// whatever text field had focus when the user pressed the hotkey.
    ///
    /// Rationale: the user just pressed a dictation hotkey, so they're
    /// already looking at the text field they expected text to land in.
    /// Pasting the error there puts the diagnostic exactly where their
    /// attention is, and requires no permission prompt — unlike
    /// Notification Center (needs authorization) or NSAlert (modal,
    /// interruptive). Accessibility is already granted (otherwise the
    /// hotkey itself wouldn't fire), so `TextInserter.insert` works.
    ///
    /// The menubar icon also flips to the error state via the
    /// `appState.status` observer in AppDelegate, and we print to the
    /// Xcode console in DEBUG so dev debugging stays visible even if the
    /// paste target swallows text silently.
    private func surfaceBlockingError(title: String, body: String) {
        appState.status = .error(title)

        #if DEBUG
        print("[Sprich] ⛔️ \(title) — \(body)")
        #endif

        let pasted = "⚠️ Sprich: \(title). \(body)"
        Task { @MainActor in
            await TextInserter.insert(pasted)
        }

        // Auto-clear the error status after 3 s so the menubar icon
        // doesn't sit in "error" forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if case .error = self?.appState.status {
                self?.appState.status = .ready
            }
        }
    }
}
