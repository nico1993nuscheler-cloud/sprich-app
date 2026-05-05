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
    /// Provider resolved at hotkey-press time. May differ from the
    /// user's configured choice when we auto-fall-back to Local while
    /// offline. Stashed so `stopAndProcess` uses the same provider
    /// that `startRecording` committed to.
    private var activeProvider: STTProviderType?

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
                "Open Sprich Settings → Providers → Local to download. Local is your default — Sprich will not silently switch to a cloud provider."
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
            surfaceBlockingError(
                title: "STT API key missing for \(provider.displayName)",
                body: "Open Sprich Settings → API Keys and paste the \(provider.displayName) key, or switch to Local (offline) in Providers."
            )
            return
        }

        // Stash the resolved provider so stopAndProcess uses the same
        // one — reachability can flip between start and stop.
        activeProvider = provider

        do {
            currentMode = mode
            // Snapshot the frontmost app BEFORE any HUD appears. Sprich's
            // panel is non-activating, so this remains the user's target.
            capturedBundleID = SurfaceDetector.captureFrontmostBundleID()
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
            let finalText = try await runPipeline(audioData: audioData, mode: mode)
            // Append the "keep going" hint inline so it lands in the
            // same text field as the transcription. New line + hint
            // keeps it readable without a huge visual thump.
            let capSeconds = appState.settings.maxRecordingDuration
            let continuation = "\n\n[Sprich: recording reached the \(capSeconds)-second limit — press the hotkey again to continue.]"
            await TextInserter.insert(finalText + continuation)
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
    }

    /// The STT→glossary→(LLM or local polish) path, factored out of
    /// `stopAndProcess` so auto-stopped recordings can share it. Returns
    /// the final cleaned text ready for paste. Does NOT paste — the
    /// caller decides whether to paste the raw result or append a hint.
    private func runPipeline(
        audioData: Data,
        mode: TranscriptionMode
    ) async throws -> String {
        let t0 = CFAbsoluteTimeGetCurrent()

        let whisperPrompt = TextPostProcessor.whisperBiasPrompt(
            glossaryTerms: appState.settings.glossaryTerms,
            includePunctuationHint: (mode == .literal)
        )

        // Surface resolution only for Formal+adaptToSurface. Kicked in
        // parallel so it overlaps with STT round-trip rather than
        // serializing behind it.
        let bundleIDSnapshot = capturedBundleID
        let shouldResolveSurface = (mode == .formal) && appState.settings.adaptToSurface
        let surfaceTask: Task<Surface, Never>? = shouldResolveSurface
            ? Task.detached(priority: .userInitiated) {
                await SurfaceDetector.resolveSurface(bundleID: bundleIDSnapshot)
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
        guard !trimmed.isEmpty else { return "" }

        let corrected = TextPostProcessor.applyGlossary(
            rawTranscript,
            replacements: appState.settings.glossaryReplacements
        )

        if mode == .literal {
            return TextPostProcessor.polishLiteral(corrected)
        }

        RecordingOverlayController.shared.showTranscribedText(corrected)
        let surface = await surfaceTask?.value ?? .generic
        let finalText = try await llmService.cleanup(
            rawText: corrected,
            mode: mode,
            settings: appState.settings,
            surface: surface
        )
        #if DEBUG
        let t2 = CFAbsoluteTimeGetCurrent()
        print("[Sprich] LLM: \(Int((t2 - t1) * 1000))ms \(InputSanitizer.redactForLog(finalText))")
        #endif
        return finalText
    }

    /// Stop recording and process through the pipeline.
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

            // 2. Build Whisper bias prompt (glossary + punctuation hint for literal)
            let whisperPrompt = TextPostProcessor.whisperBiasPrompt(
                glossaryTerms: appState.settings.glossaryTerms,
                includePunctuationHint: (mode == .literal)
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
            let surfaceTask: Task<Surface, Never>? = shouldResolveSurface
                ? Task.detached(priority: .userInitiated) {
                    await SurfaceDetector.resolveSurface(bundleID: bundleIDSnapshot)
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

            // 4. Apply glossary replacements post-STT (runs for every mode)
            let corrected = TextPostProcessor.applyGlossary(
                rawTranscript,
                replacements: appState.settings.glossaryReplacements
            )

            // 5. Mode-dependent processing
            let finalText: String

            if mode == .literal {
                // Literal: STT output + local polish — no LLM
                finalText = TextPostProcessor.polishLiteral(corrected)
                #if DEBUG
                print("[Sprich] Literal mode — skipping LLM (local polish applied)")
                #endif
            } else {
                // Formal + Custom: use LLM to restructure
                RecordingOverlayController.shared.showTranscribedText(corrected)

                // Await the surface resolution launched before STT.
                // `nil` when adaptToSurface is off → fall back to
                // `.generic`, which leaves the prompt unchanged.
                // Worst case (browser AppleScript denied) also returns
                // `.generic` from the detector.
                let surface = await surfaceTask?.value ?? .generic
                #if DEBUG
                print("[Sprich] Surface: \(bundleIDSnapshot ?? "?") → \(surface.debugLabel)")
                #endif

                finalText = try await llmService.cleanup(
                    rawText: corrected,
                    mode: mode,
                    settings: appState.settings,
                    surface: surface
                )
                let t3 = CFAbsoluteTimeGetCurrent()
                #if DEBUG
                print("[Sprich] LLM: \(Int((t3 - t2) * 1000))ms \(InputSanitizer.redactForLog(finalText))")
                #endif
            }

            // 4. Paste
            await TextInserter.insert(finalText)
            let tEnd = CFAbsoluteTimeGetCurrent()
            #if DEBUG
            print("[Sprich] ✅ Total: \(Int((tEnd - pipelineStart) * 1000))ms")
            #endif

            RecordingOverlayController.shared.dismiss()
            appState.status = .ready

        } catch {
            RecordingOverlayController.shared.dismiss()

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
    }

    /// Cancel any in-progress recording.
    func cancel() {
        recorder.cancelRecording()
        currentMode = nil
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
