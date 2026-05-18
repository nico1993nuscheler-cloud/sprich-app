import SwiftUI

/// Sprint 3 IA: sidebar (NavigationSplitView), 6 sections.
///
/// `SettingsSection` is the deep-link target for `MissingKeyBanner`'s
/// "Open Settings → AI cleanup" CTA (P1-UX-14). The banner posts a
/// `.sprichOpenSettingsSection` notification carrying the section to
/// route to; `SettingsView` listens and updates `selection`.
enum SettingsSection: String, Hashable, CaseIterable, Identifiable {
    case account
    case aiModels
    case modes
    case general
    case privacy
    case about

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .account:   return "Account"
        case .aiModels:  return "AI Models"
        case .modes:     return "Modes"
        case .general:   return "General"
        case .privacy:   return "Privacy"
        case .about:     return "About"
        }
    }

    var iconName: String {
        switch self {
        case .account:   return "person.crop.circle"
        case .aiModels:  return "brain"
        case .modes:     return "text.quote"
        case .general:   return "gear"
        case .privacy:   return "lock.shield"
        case .about:     return "info.circle"
        }
    }
}

extension Notification.Name {
    /// Posted by `MissingKeyBanner` (and any other deep-link source) to
    /// route the Settings window to a specific section. UserInfo carries
    /// the `SettingsSection` raw value under key `"section"`.
    static let sprichOpenSettingsSection = Notification.Name("SprichOpenSettingsSection")
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // Sidebar selection (P1-UX-01). Defaults to AI Models — the
    // load-bearing page where most users start.
    @State private var selection: SettingsSection = .aiModels

    // Local state for API key fields (read from Keychain on appear)
    @State private var groqKey = ""
    @State private var openAIKey = ""
    @State private var deepgramKey = ""
    @State private var anthropicKey = ""
    @State private var googleKey = ""

    @State private var showSavedAlert = false
    @State private var showAdvancedKeys = false
    @State private var showAdvancedLLM = false

    // Glossary local editing
    @State private var newGlossaryFrom = ""
    @State private var newGlossaryTo = ""

    // Local Whisper model download sheet
    @State private var showModelDownload = false
    @ObservedObject private var whisperManager = WhisperModelManager.shared

    // Local LLM (Sprint 2F)
    @State private var showLLMDownload = false
    @State private var showLLMOnboarding = false
    @ObservedObject private var llmManager = LLMModelManager.shared
    /// Cached HardwareProbe result. Probed `.onAppear`, re-probed when the
    /// user taps "Re-check" (so a post-RAM-upgrade user can flip from 🟡 to 🟢).
    @State private var hardwareTier: HardwareProbe.Tier = .recommended

    // Trial state drives the Upgrade button in the About card (L3.2).
    // Live-refreshes the card so the button appears/disappears the moment
    // entitlement flips (trial → expired, trial → licensed after purchase).
    @StateObject private var trial = TrialState.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.displayName, systemImage: section.iconName)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 200)
            .listStyle(.sidebar)
        } detail: {
            // Each section is wired ticket-by-ticket. The shell (this ticket,
            // P1-UX-01) lands a placeholder for every section so navigation
            // works end-to-end; P1-UX-03 through P1-UX-12 replace them.
            Group {
                switch selection {
                case .account:   sectionPlaceholder(.account)
                case .aiModels:  sectionPlaceholder(.aiModels)
                case .modes:     sectionPlaceholder(.modes)
                case .general:   sectionPlaceholder(.general)
                case .privacy:   sectionPlaceholder(.privacy)
                case .about:     sectionPlaceholder(.about)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 760, height: 620)
        .onReceive(NotificationCenter.default.publisher(for: .sprichOpenSettingsSection)) { note in
            if let raw = note.userInfo?["section"] as? String,
               let section = SettingsSection(rawValue: raw) {
                selection = section
            }
        }
        .onAppear {
            loadKeys()
            whisperManager.refreshState(for: appState.settings.localWhisperModel)
            llmManager.refreshState(for: LocalLLMModelSpec.defaultSpec)
            hardwareTier = HardwareProbe.evaluate()
        }
        .alert("Settings Saved", isPresented: $showSavedAlert) {
            Button("OK", role: .cancel) {}
        }
        .sheet(isPresented: $showModelDownload) {
            ModelDownloadView(
                model: appState.settings.localWhisperModel,
                onDone: {
                    showModelDownload = false
                    // Download just finished — warm the pipe in the
                    // background so the first dictation after this
                    // doesn't pay the ~10-30 s Core ML first-compile
                    // cost on the hotkey's release path.
                    TranscriptionService.prewarmLocalWhisperIfReady(
                        model: appState.settings.localWhisperModel
                    )
                },
                onCancel: {
                    showModelDownload = false
                    // If the user abandons the download, flip the provider
                    // back to Groq so a hotkey press doesn't dead-end.
                    if appState.settings.sttProvider.isLocal {
                        appState.settings.sttProvider = .groq
                        appState.saveSettings()
                    }
                }
            )
        }
        .sheet(isPresented: $showLLMDownload) {
            LLMModelDownloadView(
                spec: LocalLLMModelSpec.defaultSpec,
                onDone: {
                    showLLMDownload = false
                },
                onCancel: {
                    showLLMDownload = false
                    // Mirror the Whisper-sheet pattern: if the user
                    // abandons a download they came here to do because
                    // they'd already picked `.local`, flip the provider
                    // back to Groq so Formal/Custom modes don't dead-end.
                    if appState.settings.llmProvider.isLocal {
                        appState.settings.llmProvider = .groq
                        appState.saveSettings()
                    }
                }
            )
        }
        .sheet(isPresented: $showLLMOnboarding) {
            LocalLLMOnboardingView(onClose: {
                showLLMOnboarding = false
            })
        }
    }

    // MARK: - Local Whisper status row

    @ViewBuilder
    private var localWhisperStatus: some View {
        let modelName = appState.settings.localWhisperModel

        VStack(alignment: .leading, spacing: 10) {

            // Model tier picker. Lets the user trade speed for accuracy
            // without leaving Settings. Switching to a different variant
            // flips the local state to reflect that model's on-disk
            // presence — typically `.absent`, which surfaces the warning
            // banner and Download button below.
            VStack(alignment: .leading, spacing: 4) {
                Text("Whisper model")
                    .font(.caption).foregroundColor(.secondary)

                Picker("", selection: Binding(
                    get: { appState.settings.localWhisperModel },
                    set: { newValue in
                        appState.settings.localWhisperModel = newValue
                        appState.saveSettings()
                        whisperManager.refreshState(for: newValue)
                        // Warm the pipe for the newly-selected model if
                        // it's already on disk. If not, the warning
                        // banner routes the user to Download.
                        TranscriptionService.prewarmLocalWhisperIfReady(model: newValue)
                    }
                )) {
                    ForEach(WhisperModelCatalog.all) { option in
                        Text(option.displayName).tag(option.variantName)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if let option = WhisperModelCatalog.option(for: appState.settings.localWhisperModel) {
                    Text(option.subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusIconName)
                    .foregroundStyle(statusIconColor)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelName)
                        .font(.system(.caption, design: .monospaced))
                    Text(statusSubline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                switch whisperManager.state {
                case .ready:
                    Button("Delete") {
                        try? whisperManager.deleteModel(modelName)
                    }
                    .controlSize(.small)
                case .downloading:
                    Button("Cancel") { whisperManager.cancelDownload() }
                        .controlSize(.small)
                case .preparing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Download") { showModelDownload = true }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }

            // Explicit warning when the user has picked Local but the
            // model isn't downloaded yet — a green-checkmark UI led the
            // previous tester to think they were good to go and the
            // first hotkey silently failed.
            if shouldShowMissingModelWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local dictation won't work until the model is downloaded.")
                            .font(.system(size: 12, weight: .semibold))
                        Text(missingModelCallToAction)
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(localStatusBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(localStatusBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Local LLM status row (Sprint 2F)

    /// "Local LLM" provider section shown when the user picks `.local`.
    /// Mirrors the shape of `localWhisperStatus` so the two on-device
    /// providers feel like one design system: hardware-eligibility badge,
    /// model row with download/delete/cancel, and a missing-model warning
    /// that's friendly rather than punitive.
    ///
    /// Decision references:
    /// - 4-sub-A: model quality picker is a separate row gated by tier
    ///   (Recommended unlocks; Eligible shows "1B only" + override hint).
    /// - 5a / 5b / 5c: no cloud-fallback toggle. A user selecting `.local`
    ///   gets local-only — switching providers is the one and only way to
    ///   reach a cloud LLM. Honest copy reinforces this.
    /// - 7a: HardwareProbe.Tier drives badge + latency expectation copy.
    @ViewBuilder
    private var localLLMStatus: some View {
        let spec = LocalLLMModelSpec.defaultSpec

        VStack(alignment: .leading, spacing: 10) {

            // Hardware-eligibility badge — the same probe onboarding ran.
            hardwareTierBadge

            // Model row — mirrors localWhisperStatus styling.
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: llmStatusIconName)
                    .foregroundStyle(llmStatusIconColor)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.displayName)
                        .font(.system(.caption, design: .monospaced))
                    Text(llmStatusSubline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                switch llmManager.state {
                case .ready:
                    Button("Delete") {
                        try? llmManager.deleteModel(spec)
                    }
                    .controlSize(.small)
                case .downloading, .verifying:
                    Button("Cancel") { llmManager.cancelDownload() }
                        .controlSize(.small)
                case .preparing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Download (\(formatBytes(spec.expectedSize)))") {
                        showLLMDownload = true
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hardwareTier.supportsLocalLLM)
                }
            }

            // Decision 4-sub-A: model quality preset row. 1B is the only
            // Phase 1 ship; 2B / 4B unlock when HardwareProbe = Recommended.
            // The row stays visible at all tiers so users know what's
            // possible — disabled when not eligible.
            if hardwareTier.qualityPresetsUnlocked {
                qualityPresetRow
            } else if case .eligible = hardwareTier {
                Text("Quality presets (Gemma 2 2B / Gemma 3 4B) unlock on 16 GB+ Macs.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Missing-model warning, same pattern as localWhisperStatus.
            if shouldShowMissingLLMWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Formal and Custom modes won't work until the AI model is downloaded.")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Default (Literal) mode keeps working — it doesn't use the LLM. Tap Download above when you're on Wi-Fi.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5))
            }

            // 5a/5b/5c honest copy: no fallback, no silent cloud egress.
            // A user who picked Local explicitly should never be surprised
            // by a cloud call they didn't authorise.
            Text("Local LLM runs fully on your Mac. There is no cloud fallback — to use a cloud provider, switch the LLM Provider above. Your transcribed text never leaves the device while Local is selected.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 2)

            HStack {
                Spacer()
                Button("Guided setup") { showLLMOnboarding = true }
                    .controlSize(.small)
                    .font(.caption2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(localLLMStatusBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(localLLMStatusBorder, lineWidth: 0.5)
        )
    }

    /// 🟢 Recommended / 🟡 Eligible / 🔴 Not supported badge + latency copy.
    /// "Re-check" lets a user who upgraded RAM flip from 🟡 → 🟢 without
    /// quitting the app (agenda Decision 7a requirement).
    @ViewBuilder
    private var hardwareTierBadge: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(hardwareTierEmoji)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Mac: \(hardwareTier.displayLabel)")
                    .font(.system(size: 12, weight: .semibold))
                Text(hardwareTier.latencyExpectationCopy)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Re-check") {
                hardwareTier = HardwareProbe.evaluate()
            }
            .controlSize(.small)
            .font(.caption2)
        }
    }

    /// Quality preset picker (Recommended tier only). Phase 1 ships 1B as
    /// the only spec; 2B / 4B labels show as disabled placeholders so the
    /// UI is honest about what's coming without committing the bytes yet.
    @ViewBuilder
    private var qualityPresetRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Local model quality")
                .font(.caption).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { appState.settings.localLLMModel },
                set: { newValue in
                    appState.settings.localLLMModel = newValue
                    appState.saveSettings()
                    // Future P2-LLM expansion: refreshState for the
                    // newly-selected spec. Phase 1 ships one spec.
                }
            )) {
                Text("Gemma 3 1B (Q4_K_M) — 0.8 GB")
                    .tag(LocalLLMModelSpec.defaultSpec.id)
                Text("Gemma 2 2B — coming soon")
                    .tag("gemma-2-2b-it-q4_k_m")
                Text("Gemma 3 4B — coming soon")
                    .tag("gemma-3-4b-it-q4_k_m")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(true)  // Phase 1: single spec; 2B/4B unlock in a follow-up sprint.

            Text("More Gemma sizes will ship as quality presets — Phase 1 starts with 1B.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var hardwareTierEmoji: String {
        switch hardwareTier {
        case .recommended:   return "🟢"
        case .eligible:      return "🟡"
        case .notSupported:  return "🔴"
        }
    }

    private var llmStatusIconName: String {
        switch llmManager.state {
        case .ready:                    return "checkmark.circle.fill"
        case .downloading, .verifying,
             .preparing:                return "arrow.down.circle"
        case .failed:                   return "exclamationmark.octagon.fill"
        default:                        return "circle.dashed"
        }
    }

    private var llmStatusIconColor: Color {
        switch llmManager.state {
        case .ready:                    return .green
        case .downloading, .verifying,
             .preparing:                return .blue
        case .failed:                   return .red
        default:                        return .secondary
        }
    }

    private var llmStatusSubline: String {
        switch llmManager.state {
        case .unknown:                  return "Status not checked yet."
        case .absent:                   return "Not downloaded."
        case .downloading(let p):       return "Downloading… \(Int(p * 100))%"
        case .verifying:                return "Verifying integrity (SHA-256)…"
        case .preparing:                return "Preparing model…"
        case .ready(_, let sizeBytes):  return "Ready · \(formatBytes(sizeBytes)) on disk"
        case .failed(let err):          return err.errorDescription ?? "Setup failed."
        }
    }

    private var shouldShowMissingLLMWarning: Bool {
        // Mirror the local-Whisper guard: only warn when the user has
        // actively chosen `.local` AND the model isn't ready.
        guard appState.settings.llmProvider.isLocal else { return false }
        if case .ready = llmManager.state { return false }
        if llmManager.state.isBusy { return false }
        return true
    }

    private var localLLMStatusBackground: Color {
        shouldShowMissingLLMWarning
            ? Color.orange.opacity(0.06)
            : Color.secondary.opacity(0.06)
    }

    private var localLLMStatusBorder: Color {
        shouldShowMissingLLMWarning
            ? Color.orange.opacity(0.4)
            : Color.secondary.opacity(0.2)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Warning background when the user's staring at a non-functional
    /// Local provider selection; neutral otherwise.
    private var localStatusBackground: Color {
        shouldShowMissingModelWarning
            ? Color.orange.opacity(0.06)
            : Color.secondary.opacity(0.08)
    }

    private var localStatusBorder: Color {
        shouldShowMissingModelWarning
            ? Color.orange.opacity(0.3)
            : Color.clear
    }

    private var shouldShowMissingModelWarning: Bool {
        switch whisperManager.state {
        case .ready, .downloading, .preparing: return false
        case .absent, .unknown, .failed: return true
        }
    }

    /// "~216 MB, one-time." / "~632 MB, one-time." etc, driven by the
    /// currently-selected model's catalog entry.
    private var missingModelCallToAction: String {
        if let option = WhisperModelCatalog.option(
            for: appState.settings.localWhisperModel
        ) {
            return "Click Download above. ~\(option.approxSizeMB) MB, one-time."
        }
        return "Click Download above."
    }

    private var statusIconName: String {
        switch whisperManager.state {
        case .ready: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        case .preparing: return "gearshape.2"
        case .failed: return "exclamationmark.triangle.fill"
        case .absent, .unknown: return "exclamationmark.triangle.fill"
        }
    }

    private var statusIconColor: Color {
        switch whisperManager.state {
        case .ready: return .green
        case .failed, .absent, .unknown: return .orange
        default: return .secondary
        }
    }

    private var statusSubline: String {
        switch whisperManager.state {
        case .ready(_, let size):
            let fmt = ByteCountFormatter(); fmt.countStyle = .file
            let sizeStr = fmt.string(fromByteCount: size)
            // .ready means bytes on disk. If the pipe hasn't warmed yet
            // the user needs to know — otherwise a hotkey press blocks
            // on a load they can't see. The flag flips to true when
            // LocalWhisperService finishes constructing WhisperKit.
            if whisperManager.isPipeReady {
                return "Ready · \(sizeStr) on disk"
            } else {
                return "Loading Core ML model… · \(sizeStr) on disk"
            }
        case .downloading(let p):
            return "Downloading \(Int(p * 100))%"
        case .preparing:
            return "Preparing (Core ML compile)…"
        case .failed(let msg):
            return msg
        case .absent, .unknown:
            return "Not downloaded — dictation will not work"
        }
    }

    // MARK: - Section placeholder (P1-UX-01 shell — replaced ticket-by-ticket)

    /// Stand-in detail view shown while a section hasn't been wired up to
    /// its real content yet. Each subsequent ticket (P1-UX-03..P1-UX-12)
    /// swaps one of these out for the redesigned section.
    @ViewBuilder
    private func sectionPlaceholder(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: section.iconName)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text(section.displayName)
                    .font(.title2).fontWeight(.semibold)
            }
            Text("This section is being redesigned (Sprint 3). Your existing settings still apply at dictation time — the editor UI returns in the next build.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func saveBar(_ action: @escaping () -> Void = {}) -> some View {
        HStack {
            Spacer()
            Button("Save") {
                action()
                appState.saveSettings()
                showSavedAlert = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - API Keys Tab

    private var apiKeysTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                card {
                    sectionHeader("Speech-to-Text")
                    apiKeyField(
                        label: "Groq API Key (recommended)",
                        text: $groqKey,
                        url: "https://console.groq.com",
                        urlLabel: "console.groq.com",
                        steps: ["Sign up or log in", "Go to API Keys", "Create new key"],
                        note: "Same key powers the fastest LLM cleanup for Formal mode."
                    )
                }

                card {
                    DisclosureGroup(isExpanded: $showAdvancedKeys) {
                        VStack(alignment: .leading, spacing: 14) {
                            apiKeyField(
                                label: "OpenAI API Key",
                                text: $openAIKey,
                                url: "https://platform.openai.com/api-keys",
                                urlLabel: "platform.openai.com",
                                steps: ["Log in to platform", "Open API Keys page", "Create new secret key"]
                            )
                            apiKeyField(
                                label: "Deepgram API Key",
                                text: $deepgramKey,
                                url: "https://console.deepgram.com",
                                urlLabel: "console.deepgram.com",
                                steps: ["Create free account", "Go to API Keys", "Create new key"]
                            )
                            apiKeyField(
                                label: "Google API Key (Gemini)",
                                text: $googleKey,
                                url: "https://aistudio.google.com/apikey",
                                urlLabel: "aistudio.google.com",
                                steps: ["Open Google AI Studio", "Click \"Get API key\"", "Create key — free tier"]
                            )
                            apiKeyField(
                                label: "Anthropic API Key (Claude)",
                                text: $anthropicKey,
                                url: "https://console.anthropic.com/settings/keys",
                                urlLabel: "console.anthropic.com",
                                steps: ["Log in to Console", "Go to API Keys", "Create key — add credits first"]
                            )
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Advanced — alternative STT / LLM providers")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.secondary)
                    Text("Keys are stored securely in macOS Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                saveBar { saveKeys() }
            }
            .padding(18)
        }
    }

    private func apiKeyField(
        label: String,
        text: Binding<String>,
        url: String,
        urlLabel: String,
        steps: [String],
        note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            SecureField("", text: text, prompt: Text("sk-…"))
                .textFieldStyle(.roundedBorder)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(index + 1).")
                                .foregroundColor(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            Text(step)
                        }
                    }
                    if let note = note {
                        Text(note).foregroundColor(.secondary).padding(.top, 2)
                    }
                    Link(urlLabel, destination: URL(string: url)!).padding(.top, 2)
                }
                .font(.caption)
                .padding(.top, 4)
            } label: {
                Text("How to get this key")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - Providers Tab

    private var providersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                card {
                    sectionHeader("Speech-to-Text Provider")
                    Picker("", selection: $appState.settings.sttProvider) {
                        ForEach(STTProviderType.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: appState.settings.sttProvider) { _, newValue in
                        // Keep the reachability read current so the warning
                        // banner reflects disk state, not a stale cache.
                        whisperManager.refreshState(
                            for: appState.settings.localWhisperModel
                        )
                        guard newValue.isLocal else { return }
                        // Warm the pipe in the background if the model is
                        // already on disk — makes the first dictation after
                        // provider switch fast instead of 10-30 s slow.
                        TranscriptionService.prewarmLocalWhisperIfReady(
                            model: appState.settings.localWhisperModel
                        )
                    }
                    providerDescription(for: appState.settings.sttProvider)

                    if appState.settings.sttProvider.isLocal {
                        localWhisperStatus
                    } else if !hasKey(forSTT: appState.settings.sttProvider) {
                        missingKeyBanner(
                            providerName: appState.settings.sttProvider.displayName,
                            kind: "STT"
                        )
                    }
                }

                card {
                    sectionHeader("LLM Provider (Formal + Custom modes)")
                    Text("Groq is fastest and reuses the STT key. Change only if you want a different model.")
                        .font(.caption).foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Text("Active:").foregroundColor(.secondary).font(.caption)
                        Text(appState.settings.llmProvider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                    }

                    DisclosureGroup(isExpanded: $showAdvancedLLM) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("", selection: $appState.settings.llmProvider) {
                                ForEach(LLMProviderType.allCases, id: \.self) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)

                            Group {
                                switch appState.settings.llmProvider {
                                case .groq:
                                    labeledField("Groq Model", text: $appState.settings.groqLLMModel)
                                    Text("Uses same API key as STT. No extra key needed.")
                                        .font(.caption).foregroundColor(.secondary)
                                case .claude:
                                    labeledField("Claude Model", text: $appState.settings.claudeModel)
                                case .google:
                                    labeledField("Gemini Model", text: $appState.settings.googleModel)
                                case .openai:
                                    labeledField("OpenAI Model", text: $appState.settings.openAILLMModel)
                                case .local:
                                    localLLMStatus
                                }
                            }

                            if !hasKey(forLLM: appState.settings.llmProvider) {
                                missingKeyBanner(
                                    providerName: appState.settings.llmProvider.displayName,
                                    kind: "LLM"
                                )
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Advanced — change LLM provider / model")
                            .font(.system(size: 13, weight: .medium))
                    }

                    Text("Literal mode skips LLM entirely — instant output.")
                        .font(.caption).foregroundColor(.secondary)
                }

                card {
                    sectionHeader("Language")
                    Picker("", selection: Binding(
                        get: { appState.settings.preferredLanguage ?? "auto" },
                        set: { appState.settings.preferredLanguage = $0 == "auto" ? nil : $0 }
                    )) {
                        ForEach(AppLanguages.all, id: \.code) { lang in
                            Text(lang.displayName).tag(lang.code ?? "auto")
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text("Pin STT to a specific language, or let the provider detect it.")
                        .font(.caption).foregroundColor(.secondary)
                }

                saveBar()
            }
            .padding(18)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Modes Tab

    private var modesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                card {
                    HStack {
                        sectionHeader("Literal Mode")
                        Spacer()
                        shortcutChip("Fn + Shift")
                    }
                    Text("Fast clean-up via STT only (no LLM). Punctuation and capitalization polished locally.")
                        .font(.caption).foregroundColor(.secondary)

                    promptEditor($appState.settings.literalPrompt, charLimit: 500)

                    HStack {
                        Button("Reset to Default") {
                            appState.settings.literalPrompt = TranscriptionMode.literal.defaultSystemPrompt
                        }
                        .font(.caption)
                        Spacer()
                    }
                }

                card {
                    HStack {
                        sectionHeader("Formal Mode")
                        Spacer()
                        shortcutChip("Fn + Control")
                    }
                    Text("Full LLM rewrite for professional written text.")
                        .font(.caption).foregroundColor(.secondary)

                    promptEditor($appState.settings.formalPrompt, charLimit: 500)

                    HStack {
                        Button("Reset to Default") {
                            appState.settings.formalPrompt = TranscriptionMode.formal.defaultSystemPrompt
                        }
                        .font(.caption)
                        Spacer()
                    }

                    Divider().padding(.vertical, 4)

                    Toggle("Adapt tone to destination app", isOn: $appState.settings.adaptToSurface)
                        .toggleStyle(.switch)
                    Text("Matches the rewrite to where you're pasting — email greeting for Gmail/Mail, terse for Slack/Teams/Messages, clean prose for docs. Reads the active browser tab URL for web apps (requires one-time Automation permission).")
                        .font(.caption).foregroundColor(.secondary)
                }

                card {
                    HStack {
                        sectionHeader("Custom Mode")
                        Spacer()
                        shortcutChip("Fn + Command")
                    }

                    Toggle("Enable custom mode", isOn: $appState.settings.customModeEnabled)
                        .toggleStyle(.switch)

                    if appState.settings.customModeEnabled {
                        Divider().padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Name").font(.caption).foregroundColor(.secondary)
                                    TextField("", text: $appState.settings.customModeName,
                                              prompt: Text("Slack"))
                                        .textFieldStyle(.roundedBorder)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Badge").font(.caption).foregroundColor(.secondary)
                                    TextField("", text: Binding(
                                        get: { appState.settings.customModeBadge },
                                        set: { appState.settings.customModeBadge = String($0.prefix(1)).uppercased() }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("System prompt")
                                        .font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(appState.settings.customModePrompt.count) / 400")
                                        .font(.caption2)
                                        .foregroundColor(appState.settings.customModePrompt.count >= 400 ? .orange : .secondary)
                                }
                                promptEditor(Binding(
                                    get: { appState.settings.customModePrompt },
                                    set: { appState.settings.customModePrompt = String($0.prefix(400)) }
                                ), charLimit: 400)
                            }
                        }
                    }
                }

                saveBar()
            }
            .padding(18)
        }
    }

    private func promptEditor(_ text: Binding<String>, charLimit: Int) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 90)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
            )
    }

    private func shortcutChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.gray.opacity(0.15))
            )
    }

    // MARK: - Dictionary Tab

    private var dictionaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                card {
                    sectionHeader("Vocabulary (Whisper bias)")
                    Text("Comma-separated terms Whisper should prefer. Great for names, brands, technical jargon. Kept under ~200 tokens.")
                        .font(.caption).foregroundColor(.secondary)

                    promptEditor($appState.settings.glossaryTerms, charLimit: 800)
                }

                card {
                    sectionHeader("Replacements (post-STT)")
                    Text("Exact find → replace pairs applied after transcription. Case-insensitive, whole-word where possible.")
                        .font(.caption).foregroundColor(.secondary)

                    if appState.settings.glossaryReplacements.isEmpty {
                        Text("No replacements yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 6) {
                            ForEach($appState.settings.glossaryReplacements) { $rep in
                                HStack(spacing: 8) {
                                    TextField("", text: $rep.from, prompt: Text("from"))
                                        .textFieldStyle(.roundedBorder)
                                    Image(systemName: "arrow.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                    TextField("", text: $rep.to, prompt: Text("to"))
                                        .textFieldStyle(.roundedBorder)
                                    Button {
                                        appState.settings.glossaryReplacements.removeAll { $0.id == rep.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red.opacity(0.75))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Divider().padding(.vertical, 2)

                    HStack(spacing: 8) {
                        TextField("", text: $newGlossaryFrom, prompt: Text("From"))
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        TextField("", text: $newGlossaryTo, prompt: Text("To"))
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let from = newGlossaryFrom.trimmingCharacters(in: .whitespaces)
                            let to = newGlossaryTo.trimmingCharacters(in: .whitespaces)
                            guard !from.isEmpty else { return }
                            appState.settings.glossaryReplacements.append(
                                GlossaryReplacement(from: from, to: to)
                            )
                            newGlossaryFrom = ""
                            newGlossaryTo = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.accentColor)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                }

                saveBar()
            }
            .padding(18)
        }
    }

    // MARK: - Privacy Tab (Sprint 2F)

    /// Static + live disclosure of what Sprich does and doesn't do with the
    /// network. Honest backstop to the recording-overlay indicator: when a
    /// curious user opens Settings to verify the "fully local" claim, this
    /// is the page that has to be true and complete.
    ///
    /// Spec: `~/Claude/40_Projects/Sprich/network-off-proof-ui-spec.md`
    /// § Surface 3.
    @ObservedObject private var networkIndicator = NetworkStatusIndicator.shared

    private var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                card {
                    sectionHeader("Network status")

                    HStack(alignment: .top, spacing: 10) {
                        Text(networkIndicator.route.glyph)
                            .font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(networkIndicator.route.shortLabel)
                                .font(.system(size: 14, weight: .semibold))
                            Text(networkIndicator.route.tooltip)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(networkIndicator.route == .offline
                                ? Color.green.opacity(0.08)
                                : Color.orange.opacity(0.08))
                    )

                    Text("Sprich shows this indicator live on the recording overlay too — green means the dictation runs without any network call this session.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                card {
                    sectionHeader("What Sprich never sends")
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Audio recordings — held in memory, never written to disk, never uploaded.", systemImage: "checkmark")
                            .font(.caption)
                        Label("Analytics or telemetry — zero SDKs linked, no event beacons.", systemImage: "checkmark")
                            .font(.caption)
                        Label("Dictation content to Sprich's servers — our endpoints don't accept transcripts at all.", systemImage: "checkmark")
                            .font(.caption)
                        Label("Auto-update probes — Sprich doesn't ship an auto-updater.", systemImage: "checkmark")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                card {
                    sectionHeader("Full network-call inventory")
                    Text("Every outbound call Sprich makes is documented in plain language. If you find a call we haven't disclosed, please email support@sprichapp.com — we'd consider it a bug.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Read the network-call inventory") {
                            if let url = URL(string: "https://sprichapp.com/network-calls") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 4)
                }

                card {
                    sectionHeader("AI model attribution")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Speech-to-text uses Whisper (OpenAI), running on-device via WhisperKit.")
                            .font(.caption)
                        Text("Local AI cleanup uses Gemma 3 by Google, running on-device via llama.cpp.")
                            .font(.caption)
                        Text("Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }

                Spacer()
            }
            .padding(18)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                card {
                    sectionHeader("Input Mode")
                    Picker("", selection: $appState.settings.inputMode) {
                        ForEach(InputMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                card {
                    sectionHeader("Safety")
                    Stepper(
                        "Max recording: \(appState.settings.maxRecordingDuration)s",
                        value: $appState.settings.maxRecordingDuration,
                        in: 30...600,
                        step: 30
                    )
                }

                card {
                    sectionHeader("Keyboard Shortcuts")
                    VStack(spacing: 8) {
                        shortcutRow(name: "Literal Mode", keys: "Fn + Shift")
                        shortcutRow(name: "Formal Mode", keys: "Fn + Control")
                        if appState.settings.customModeEnabled {
                            shortcutRow(
                                name: appState.settings.customModeName.isEmpty ? "Custom Mode" : appState.settings.customModeName,
                                keys: "Fn + Command"
                            )
                        }
                    }
                }

                card {
                    sectionHeader("Permissions")
                    permissionRow(
                        name: "Accessibility",
                        granted: Permissions.isAccessibilityGranted(),
                        action: { Permissions.openAccessibilitySettings() }
                    )
                    permissionRow(
                        name: "Microphone",
                        granted: Permissions.isMicrophoneGranted(),
                        pendingNote: "Requested on first use"
                    )
                }

                card {
                    sectionHeader("About")
                    // Dynamic version from Info.plist (L3.1) — previously
                    // hardcoded "v1.0.0" drifted from real releases. Tagline
                    // also lost the "Open-source" claim that conflicts with
                    // the commercial AppSumo positioning + BUSL relicensing.
                    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
                    HStack {
                        Image("SprichLogo")
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sprich v\(appVersion)").font(.system(size: 13, weight: .semibold))
                            Text("Speech-to-text for macOS")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    // Upgrade / license state (L3.2 — audit P0 #4 surface 4).
                    // Trial-active: nudge to lifetime. Licensed: confirmation
                    // badge. Other states: nothing (signed-out / unknown /
                    // expired all have stronger surfaces elsewhere — the
                    // menubar trial-expired row, the lock view, sign-in).
                    switch trial.entitlement {
                    case .trialActive:
                        Button {
                            if let url = URL(string: "https://sprichapp.com/pricing") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("Upgrade to lifetime")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    case .licensed:
                        Label("Lifetime license active", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    case .trialExpired, .signedOut, .unknown, .deviceBlocked:
                        EmptyView()
                    }
                }

                saveBar()
            }
            .padding(18)
        }
    }

    private func shortcutRow(name: String, keys: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            shortcutChip(keys)
        }
    }

    private func permissionRow(name: String, granted: Bool,
                                action: (() -> Void)? = nil,
                                pendingNote: String? = nil) -> some View {
        HStack {
            Text(name)
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Granted").font(.caption).foregroundColor(.secondary)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red.opacity(0.8))
                if let action = action {
                    Button("Open Settings", action: action)
                        .controlSize(.small)
                } else if let note = pendingNote {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func providerDescription(for provider: STTProviderType) -> some View {
        Group {
            switch provider {
            case .groq:
                Text("Fastest & cheapest (~$0.0007/min). Uses Whisper model via Groq cloud.")
            case .openai:
                Text("Standard Whisper API (~$0.006/min). Most reliable.")
            case .deepgram:
                Text("Nova-3 model (~$0.008/min). Excellent real-time performance.")
            case .local:
                Text("Runs fully on-device with WhisperKit — no network, no API key. Pick a tier below.")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    // MARK: - Key validation

    private func hasKey(forSTT provider: STTProviderType) -> Bool {
        // Re-read from Keychain each body re-eval; cheap and always current.
        _ = groqKey; _ = openAIKey; _ = deepgramKey  // force dependency on @State
        // Local provider needs a downloaded model, not an API key —
        // treat as "has key" so the missing-key banner doesn't fire.
        if provider.isLocal { return true }
        guard let v = KeychainManager.retrieve(key: provider.keychainKey) else { return false }
        return !v.isEmpty
    }

    private func hasKey(forLLM provider: LLMProviderType) -> Bool {
        _ = groqKey; _ = openAIKey; _ = anthropicKey; _ = googleKey
        switch provider {
        case .groq:
            // Reuses Groq STT key
            guard let v = KeychainManager.retrieve(key: STTProviderType.groq.keychainKey) else { return false }
            return !v.isEmpty
        case .claude, .google, .openai:
            guard let v = KeychainManager.retrieve(key: provider.keychainKey) else { return false }
            return !v.isEmpty
        case .local:
            // Local LLM needs a model on disk, not a key. The model-readiness
            // check is owned by `LLMModelManager.state` (P2-LLM-05) and the
            // Settings "Local LLM" section reads it directly; the
            // missing-key banner never applies.
            return true
        }
    }

    private func missingKeyBanner(providerName: String, kind: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Missing API key for \(providerName)")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add your \(providerName) key on the API Keys tab — \(kind) calls will fail until then.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func loadKeys() {
        groqKey = KeychainManager.retrieve(key: STTProviderType.groq.keychainKey) ?? ""
        openAIKey = KeychainManager.retrieve(key: STTProviderType.openai.keychainKey) ?? ""
        deepgramKey = KeychainManager.retrieve(key: STTProviderType.deepgram.keychainKey) ?? ""
        anthropicKey = KeychainManager.retrieve(key: LLMProviderType.claude.keychainKey) ?? ""
        googleKey = KeychainManager.retrieve(key: LLMProviderType.google.keychainKey) ?? ""
    }

    private func saveKeys() {
        if !groqKey.isEmpty {
            KeychainManager.store(key: STTProviderType.groq.keychainKey, value: groqKey)
        }
        if !openAIKey.isEmpty {
            KeychainManager.store(key: STTProviderType.openai.keychainKey, value: openAIKey)
            KeychainManager.store(key: LLMProviderType.openai.keychainKey, value: openAIKey)
        }
        if !deepgramKey.isEmpty {
            KeychainManager.store(key: STTProviderType.deepgram.keychainKey, value: deepgramKey)
        }
        if !anthropicKey.isEmpty {
            KeychainManager.store(key: LLMProviderType.claude.keychainKey, value: anthropicKey)
        }
        if !googleKey.isEmpty {
            KeychainManager.store(key: LLMProviderType.google.keychainKey, value: googleKey)
        }
    }
}
