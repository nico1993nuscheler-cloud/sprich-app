import Foundation
import UserNotifications

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
                appState.status = .error("Microphone access denied")
                showNotification(title: "Sprich", body: "Microphone permission required. Open System Settings.")
                return
            }
        }

        // Only check STT key — literal mode doesn't need LLM
        let sttKey = KeychainManager.retrieve(key: appState.settings.sttProvider.keychainKey)
        if sttKey == nil {
            appState.status = .error("STT API key not configured")
            showNotification(title: "Sprich", body: "Please configure your STT API key in Settings.")
            return
        }

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
            appState.status = .error("Recording failed: \(error.localizedDescription)")
            showNotification(title: "Sprich Error", body: "Failed to start recording: \(error.localizedDescription)")
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

            // 3. Kick off surface resolution in parallel with STT.
            // For native apps this is a cheap dictionary lookup; for
            // browsers it runs AppleScript to read the active tab URL.
            // Either way the latency is hidden behind the STT request.
            let bundleIDSnapshot = capturedBundleID
            let surfaceTask = Task.detached(priority: .userInitiated) {
                await SurfaceDetector.resolveSurface(bundleID: bundleIDSnapshot)
            }

            // 4. Transcribe via STT
            let rawTranscript = try await sttService.transcribe(
                audioData: audioData,
                provider: appState.settings.sttProvider,
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
                // Worst case (browser AppleScript denied) it returns
                // `.generic`, which leaves the prompt unchanged.
                let surface = await surfaceTask.value
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
            appState.status = .error(error.localizedDescription)

            let errorMessage: String
            if let sprichError = error as? SprichError {
                errorMessage = sprichError.userFacingMessage
            } else {
                errorMessage = error.localizedDescription
            }

            showNotification(title: "Sprich Error", body: errorMessage)

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if case .error = self?.appState.status {
                    self?.appState.status = .ready
                }
            }
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

    // MARK: - Notifications

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
