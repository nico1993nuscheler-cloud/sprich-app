import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0
    @State private var groqKey = ""
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted()
    @State private var microphoneGranted = Permissions.isMicrophoneGranted()
    /// Provider choice on step 3. Defaults to `.local` so the recommended
    /// path requires zero user input — clicking Continue is enough.
    @State private var providerChoice: STTProviderType = .local
    /// Expanded state of the "Advanced — use a cloud provider" disclosure.
    @State private var cloudDisclosureExpanded = false
    /// Drives the download-progress strip on the final step when Local
    /// was the chosen provider.
    @ObservedObject private var whisperManager = WhisperModelManager.shared

    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: accessibilityStep
                case 2: microphoneStep
                case 3: providerChoiceStep
                default: finalStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)

            progressDots
                .padding(.bottom, 18)
        }
        .frame(width: 500, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Seed the choice from whatever the user already has saved
            // (so replaying onboarding via the menubar item doesn't
            // silently reset them from Cloud back to Local).
            providerChoice = appState.settings.sttProvider
            // If they had a cloud provider configured, open the advanced
            // disclosure pre-expanded so they can see/edit their key.
            cloudDisclosureExpanded = !providerChoice.isLocal
        }
        .onReceive(permissionTimer) { _ in
            accessibilityGranted = Permissions.isAccessibilityGranted()
            microphoneGranted = Permissions.isMicrophoneGranted()
        }
    }

    // MARK: - Shared pieces

    private var header: some View {
        HStack(spacing: 14) {
            if let logo = NSImage(named: "SprichLogo") {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Sprich").font(.title2).fontWeight(.semibold)
                Text("Speech-to-text, your way.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Circle()
                    .fill(i == currentStep ? Color.accentColor :
                          i < currentStep ? Color.accentColor.opacity(0.5) :
                          Color.gray.opacity(0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // Skip / back / primary row — one row for every step
    private func navRow(primaryLabel: String,
                        primaryDisabled: Bool = false,
                        primary: @escaping () -> Void) -> some View {
        HStack {
            if currentStep > 0 {
                Button("Back") { currentStep -= 1 }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(primaryLabel, action: primary)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
    }

    // MARK: - Step 0 — welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome").font(.title).fontWeight(.bold)

            Text("Sprich turns your voice into clean text in any app — emails, chats, docs, code comments. Hold a shortcut, speak, release. Done.")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                bullet(
                    icon: "bolt.fill",
                    title: "Fast",
                    text: "Under one second from release to pasted text."
                )
                bullet(
                    icon: "lock.shield.fill",
                    title: "Private",
                    text: "API keys live in macOS Keychain. No telemetry. No account."
                )
                bullet(
                    icon: "gift.fill",
                    title: "Free",
                    text: "Bring your own API keys — Groq's free tier covers typical daily use. No subscription, ever."
                )
            }
            .padding(.top, 4)

            Spacer()

            navRow(primaryLabel: "Get Started") { currentStep = 1 }
        }
    }

    private func bullet(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Step 1 — accessibility

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 1 — Accessibility").font(.title2).fontWeight(.semibold)

            Text("Sprich listens for your shortcut system-wide and pastes the result into whatever app is focused. macOS requires Accessibility permission for this.")
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                if accessibilityGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Granted").font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.orange)
                    Text("Not granted yet").font(.system(size: 13, weight: .semibold))
                }
            }

            if !accessibilityGranted {
                Button("Open Accessibility Settings") {
                    Permissions.promptAccessibility()
                }
                .buttonStyle(.bordered)

                Text("A system prompt will appear. Click **Open System Settings**, then toggle Sprich on. You may need to relaunch Sprich afterwards.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            navRow(primaryLabel: accessibilityGranted ? "Continue" : "I've granted access") {
                currentStep = 2
            }
        }
        .onChange(of: accessibilityGranted) { granted in
            if granted && currentStep == 1 {
                // Auto-advance after a short delay so the user sees the green checkmark
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if currentStep == 1 { currentStep = 2 }
                }
            }
        }
    }

    // MARK: - Step 2 — microphone

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 2 — Microphone").font(.title2).fontWeight(.semibold)

            Text("Sprich records your voice only while you're holding the shortcut. Audio is sent directly to your chosen transcription provider, never cached to disk.")
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                if microphoneGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Granted").font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "mic.slash.fill").foregroundColor(.orange)
                    Text("Not granted yet").font(.system(size: 13, weight: .semibold))
                }
            }

            if !microphoneGranted {
                Button("Grant Microphone Access") {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        microphoneGranted = Permissions.isMicrophoneGranted()
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            navRow(primaryLabel: "Continue") { currentStep = 3 }
        }
        .onChange(of: microphoneGranted) { granted in
            if granted && currentStep == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if currentStep == 2 { currentStep = 3 }
                }
            }
        }
    }

    // MARK: - Step 3 — Provider choice (Local default, cloud recommended)

    private var providerChoiceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step 3 — Choose your transcription").font(.title2).fontWeight(.semibold)

            Text("Sprich can transcribe fully on your Mac (default) or use a cloud API (recommended for the fastest, most polished experience).")
                .foregroundColor(.secondary)

            // Local (default) card — selected by default so "just click
            // Continue" is a valid path. Still the privacy-first option
            // that requires no key — but we no longer label it
            // "recommended", because for creators who want maximum speed
            // and quality the cloud path is what we recommend.
            providerOptionCard(
                choice: .local,
                icon: "lock.shield.fill",
                title: "Local (default)",
                badge: "No account · No API key · ~\(WhisperModelCatalog.balanced.approxSizeMB) MB one-time download",
                description: "Runs Whisper on your Mac with Apple Silicon acceleration. Best privacy, zero per-dictation cost. Pick Balanced tier — change later in Settings."
            )

            // Cloud (recommended). Collapsed by default, but the label
            // explicitly calls out why someone would open it.
            DisclosureGroup(isExpanded: $cloudDisclosureExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A cloud provider key unlocks two things at once: faster, more polished transcription (Groq Whisper ≈ 0.5 s round-trip) AND the AI-powered cleanup used in Formal and Custom modes. Without a cloud key, only Literal mode works.")
                        .font(.caption).foregroundColor(.secondary)

                    providerOptionCard(
                        choice: .groq,
                        icon: "bolt.fill",
                        title: "Cloud — Groq (recommended)",
                        badge: "Free tier · ≈ €0.0007/min after · powers STT + Formal cleanup",
                        description: "Sends audio to Groq's API for transcription. Same key drives the Formal-mode AI polish, so one key gets you everything."
                    )

                    if providerChoice == .groq {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Groq API key").font(.caption).foregroundColor(.secondary)
                            SecureField("gsk_…", text: $groqKey)
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundColor(.accentColor)
                                Link("Get a free Groq key at console.groq.com",
                                     destination: URL(string: "https://console.groq.com/keys")!)
                                    .font(.caption)
                            }
                        }
                        .padding(.top, 4)
                    }

                    Text("OpenAI, Deepgram, Claude and Gemini keys can be added anytime from Settings → API Keys.")
                        .font(.caption).foregroundColor(.secondary).padding(.top, 2)
                }
                .padding(.top, 8)
            } label: {
                Text("Cloud — recommended for fastest speed and Formal-mode cleanup")
                    .font(.system(size: 13, weight: .medium))
            }

            // Heads-up for users who pick Local without adding any cloud
            // key: Formal/Custom modes call an LLM, and the LLM path is
            // always cloud. Literal is purely local.
            if providerChoice == .local && !hasAnyCloudLLMKey {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Local covers transcription (Literal mode). Formal and Custom modes still need a cloud LLM key — expand the section above, or add one later in Settings → API Keys.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.08))
                )
            }

            Spacer()

            HStack {
                Button("Back") { currentStep -= 1 }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Spacer()
                Button(primaryButtonTitle) {
                    commitProviderChoice()
                    currentStep = 4
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(primaryButtonDisabled)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch providerChoice {
        case .local:    return "Continue with Local"
        case .groq:     return groqKey.trimmingCharacters(in: .whitespaces).isEmpty
                            ? "Continue"
                            : "Save Key & Continue"
        default:        return "Continue"
        }
    }

    /// Block advancing when the user selected Cloud but provided no key —
    /// otherwise they'd land on the shortcuts screen with a broken setup.
    private var primaryButtonDisabled: Bool {
        if providerChoice == .groq {
            return groqKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    /// True when the user has a cloud LLM key stored in Keychain for any
    /// provider. Drives the "Formal/Custom need a cloud key" hint below
    /// the Local card — we only nag users who'd actually be missing
    /// Formal/Custom functionality. A user who already had Groq set up
    /// from a previous install is silent-ok.
    private var hasAnyCloudLLMKey: Bool {
        let candidates: [LLMProviderType] = [.groq, .claude, .google, .openai]
        for provider in candidates {
            if let v = KeychainManager.retrieve(key: provider.keychainKey),
               !v.isEmpty { return true }
        }
        // Also a Groq key entered on this very screen counts.
        return !groqKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Execute the side effects of the provider choice: save the STT
    /// provider, store any entered key, and — for Local — kick off the
    /// model download in the background so the user doesn't have to
    /// wait on this step.
    private func commitProviderChoice() {
        appState.settings.sttProvider = providerChoice
        appState.saveSettings()

        switch providerChoice {
        case .local:
            // Fire-and-forget. `WhisperModelManager` publishes progress
            // via `state`; the final step shows a small indicator so
            // the user knows the background download is happening.
            let model = appState.settings.localWhisperModel
            Task { @MainActor in
                try? await WhisperModelManager.shared.ensureReady(model: model)
            }
        case .groq:
            let trimmed = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                KeychainManager.store(
                    key: STTProviderType.groq.keychainKey,
                    value: trimmed
                )
            }
        default:
            break
        }
    }

    private func providerOptionCard(
        choice: STTProviderType,
        icon: String,
        title: String,
        badge: String,
        description: String
    ) -> some View {
        let selected = providerChoice == choice
        return Button {
            providerChoice = choice
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                    Text(badge).font(.caption2).foregroundColor(.secondary)
                    Text(description).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected
                          ? Color.accentColor.opacity(0.08)
                          : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.2),
                        lineWidth: selected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 4 — Shortcut cheat-sheet

    private var finalStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your shortcuts").font(.title2).fontWeight(.bold)

            Text("Hold the combo, speak, release. The cleaned text is pasted into whatever app is focused.")
                .foregroundColor(.secondary).font(.callout)

            // When Local was chosen on step 3, surface the background
            // download progress so the user knows that's why their first
            // dictation attempt might say "still downloading".
            if appState.settings.sttProvider.isLocal {
                localDownloadStatusRow
            }

            VStack(spacing: 10) {
                shortcutCard(
                    symbols: ["globe", "shift"],
                    labels:  ["fn",     "shift"],
                    title:   "Literal",
                    subtitle: "Clean transcription — fillers removed, grammar fixed.",
                    useCases: "Chats · Notes · Code comments",
                    accent:  Color(red: 0.35, green: 0.85, blue: 0.65)
                )
                shortcutCard(
                    symbols: ["globe", "control"],
                    labels:  ["fn",     "control"],
                    title:   "Formal",
                    subtitle: "Restructured into polished written language.",
                    useCases: "Emails · Documents · Proposals",
                    accent:  Color(red: 0.55, green: 0.45, blue: 0.95)
                )
                shortcutCard(
                    symbols: ["globe", "command"],
                    labels:  ["fn",     "cmd"],
                    title:   "Custom",
                    subtitle: "Your own prompt (enable in Settings).",
                    useCases: "Slack tone · Bullet points · Any niche style",
                    accent:  Color(red: 0.95, green: 0.65, blue: 0.35)
                )
            }

            Spacer()

            Button("Start Using Sprich") { finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    /// Passive status strip shown on the final step when Local was the
    /// chosen provider on step 3. Observes `WhisperModelManager.shared`
    /// so the progress bar climbs live as the model downloads in the
    /// background. If the model is already Ready (e.g. the user replayed
    /// onboarding after a fresh install had already finished downloading),
    /// we don't render anything — nothing useful to say.
    @ViewBuilder
    private var localDownloadStatusRow: some View {
        switch whisperManager.state {
        case .downloading(let p):
            HStack(spacing: 10) {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 160)
                Text("Downloading Whisper \(Int(p * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.08))
            )
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing Whisper (one-time Core ML compile, ~10–30 s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.08))
            )
        case .failed(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper download failed")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(msg) — open Settings → Providers → Local to retry.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
            )
        default:
            EmptyView()
        }
    }

    private func shortcutCard(
        symbols: [String],
        labels: [String],
        title: String,
        subtitle: String,
        useCases: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(zip(symbols, labels).enumerated()), id: \.offset) { idx, pair in
                    if idx > 0 {
                        Text("+").font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    keycap(symbol: pair.0, label: pair.1)
                }
            }
            .frame(width: 128, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary)
                Text(useCases)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accent.opacity(0.85))
                    .padding(.top, 1)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func keycap(symbol: String, label: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
        }
        .foregroundColor(.primary)
        .frame(width: 44, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.gray.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 1, y: 1)
    }

    // MARK: - Finish

    private func finish() {
        UserDefaults.standard.set(true, forKey: "sprich.hasCompletedOnboarding")
        // AppDelegate listens for this to (re)start the hotkey manager with
        // the freshly granted Accessibility permission and close the window.
        NotificationCenter.default.post(name: .sprichOnboardingComplete, object: nil)
    }
}
