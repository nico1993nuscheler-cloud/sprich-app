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
                surfaceBlockingError(
                    title: "Local Whisper model not downloaded",
                    body: "Open Sprich Settings → Providers → Local to download the ~626 MB model. Local is your default — Sprich will not silently switch to a cloud provider."
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

    /// Stop recording and process through the pipeline.
    func stopAndProcess() async {
        guard case .recording = appState.status,
              let mode = currentMode else { return }

        appState.status = .processing
        RecordingOverlayController.shared.showProcessing()

        do {
            let pipelineStart = CFAbsoluteTimeGetCurrent()

            // 1. Stop recording and get audio data
            guard let audioData = try recorder.stopRecording() else {
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
            let rawTranscript = try await sttService.transcribe(
                audioData: audioData,
                provider: provider,
                language: appState.settings.preferredLanguage,
                prompt: whisperPrompt
            )
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
