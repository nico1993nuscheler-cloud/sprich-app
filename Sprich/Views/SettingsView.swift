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

    // Local Whisper model download sheet
    @State private var showModelDownload = false
    @ObservedObject private var whisperManager = WhisperModelManager.shared

    // Local LLM (Sprint 2F)
    @State private var showLLMDownload = false
    @ObservedObject private var llmManager = LLMModelManager.shared
    /// Cached HardwareProbe result. Probed `.onAppear`, re-probed when the
    /// user taps "Re-check" (so a post-RAM-upgrade user can flip from 🟡 to 🟢).
    @State private var hardwareTier: HardwareProbe.Tier = .recommended

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
                case .account:   AccountSection()
                case .aiModels:
                    AIModelsSection(
                        groqKey: $groqKey,
                        openAIKey: $openAIKey,
                        deepgramKey: $deepgramKey,
                        anthropicKey: $anthropicKey,
                        googleKey: $googleKey,
                        hardwareTier: $hardwareTier,
                        onRequestWhisperDownload: { showModelDownload = true },
                        onRequestLLMDownload: { showLLMDownload = true }
                    )
                    .environmentObject(appState)
                case .modes:     ModesSection().environmentObject(appState)
                case .general:   GeneralSection().environmentObject(appState)
                case .privacy:   PrivacySection()
                case .about:     AboutSection()
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
    }

    private func loadKeys() {
        groqKey = KeychainManager.retrieve(key: STTProviderType.groq.keychainKey) ?? ""
        openAIKey = KeychainManager.retrieve(key: STTProviderType.openai.keychainKey) ?? ""
        deepgramKey = KeychainManager.retrieve(key: STTProviderType.deepgram.keychainKey) ?? ""
        anthropicKey = KeychainManager.retrieve(key: LLMProviderType.claude.keychainKey) ?? ""
        googleKey = KeychainManager.retrieve(key: LLMProviderType.google.keychainKey) ?? ""
    }

}

// MARK: - AccountSection (P1-UX-03)

/// Sidebar section: email + trial state + Sign out + Upgrade link.
/// Fixes UX audit P0 #7 by giving the signed-in user a real destination
/// inside Settings rather than the re-sign-in panel they used to land on
/// when clicking the menubar Account row.
private struct AccountSection: View {
    @StateObject private var auth = AuthService.shared
    @StateObject private var trial = TrialState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Account")
                        .font(.title2).fontWeight(.semibold)
                }

                card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Signed in as")
                            .font(.caption).foregroundColor(.secondary)
                        Text(auth.currentUserEmail ?? "Not signed in")
                            .font(.system(size: 13, weight: .medium))
                            .textSelection(.enabled)
                    }
                }

                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Plan")
                            .font(.caption).foregroundColor(.secondary)
                        entitlementRow
                    }
                }

                card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Session")
                            .font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("Sign out", action: confirmAndSignOut)
                                .controlSize(.regular)
                                .disabled(!auth.isSignedIn)
                            Spacer()
                        }
                        Text("Trial state stays linked to your email — signing back in restores access.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }

                card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Delete account")
                            .font(.caption).foregroundColor(.secondary)
                        Text("Email support@sprichapp.com to delete your account and associated trial/license records.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("support@sprichapp.com",
                             destination: URL(string: "mailto:support@sprichapp.com?subject=Delete%20my%20Sprich%20account")!)
                            .font(.caption)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var entitlementRow: some View {
        switch trial.entitlement {
        case .trialActive:
            HStack(spacing: 10) {
                Image(systemName: "clock.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trial — \(trial.daysRemaining) day\(trial.daysRemaining == 1 ? "" : "s") left")
                        .font(.system(size: 13, weight: .medium))
                    Text("Buy a lifetime license to keep dictating after your trial ends.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Button("Upgrade") {
                    NSWorkspace.shared.open(URL(string: "https://sprichapp.com/pricing")!)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .licensed:
            Label("Lifetime license active", systemImage: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)
        case .trialExpired:
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.red)
                Text("Trial expired").font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Buy lifetime") {
                    NSWorkspace.shared.open(URL(string: "https://sprichapp.com/pricing")!)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .deviceBlocked:
            Text("This Mac is associated with another trial. Sign in with the original account, or buy a license to lift the block.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .signedOut, .unknown:
            Text("Sign in from the menubar icon to start your trial.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @MainActor
    private func confirmAndSignOut() {
        guard auth.isSignedIn else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of Sprich?"
        alert.informativeText = "Your trial state stays linked to your email — signing back in restores access."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign out")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            auth.signOut()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        SettingsCard(content: content)
    }
}

// MARK: - SettingsCard (shared card chrome for sidebar sections)

/// Shared card chrome used by every sidebar section. Pulled out of
/// SettingsView's private helper so AccountSection / GeneralSection /
/// ModesSection / PrivacySection / AboutSection can share one component.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
    }
}

/// Sidebar-section header used by every section. One-liner replacement
/// for the per-card `sectionHeader` of the old TabView IA.
struct SettingsSectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2).fontWeight(.semibold)
        }
    }
}

// MARK: - PrivacySection (P1-UX-11)

/// Per Decision 4 in sprint-3-settings-ux.md: two cards only.
/// The live NetworkStatusIndicator is the hero; the inventory link is
/// the secondary path for skeptics. The "What Sprich never sends" 4-row
/// checklist that Nico called wishiwashi is cut. The Gemma attribution
/// string moved to AboutSection (still legally mandatory, just lives
/// where attribution belongs).
private struct PrivacySection: View {
    @ObservedObject private var networkIndicator = NetworkStatusIndicator.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeader(icon: "lock.shield", title: "Privacy")

                SettingsCard {
                    Text("Network status")
                        .font(.caption).foregroundColor(.secondary)

                    HStack(alignment: .top, spacing: 12) {
                        Text(networkIndicator.route.glyph)
                            .font(.system(size: 28))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(networkIndicator.route.shortLabel)
                                .font(.system(size: 14, weight: .semibold))
                            Text(networkStatusStaticCopy)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(networkIndicator.route == .offline
                                  ? Color.green.opacity(0.10)
                                  : Color.orange.opacity(0.10))
                    )

                    Text("Sprich shows this indicator live on the recording overlay too — green confirms the dictation ran without any network call.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard {
                    Text("Network call inventory")
                        .font(.caption).foregroundColor(.secondary)
                    Text("Every outbound call Sprich makes is documented in plain language. If you find a call we haven't disclosed, email support@sprichapp.com — we'd consider it a bug.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Read the inventory") {
                            if let url = URL(string: "https://sprichapp.com/network-calls") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Present-tense framing for the static Settings card (the recording
    /// overlay uses past-tense "stayed" to confirm what just happened).
    private var networkStatusStaticCopy: String {
        switch networkIndicator.route {
        case .offline:
            return "Sprich is configured to keep your audio and text on this Mac."
        default:
            return networkIndicator.route.tooltip
        }
    }
}

// MARK: - AboutSection (P1-UX-12)

/// Version (dynamic, not hardcoded — UX audit P0 #5 fix) + Sprich
/// tagline + trial/licensed state row + AI model attributions
/// (Whisper + Gemma) including the legally mandatory Gemma Terms
/// reference string (Sprint 2F locked decision: lives somewhere; moved
/// here from Privacy per Decision 4).
private struct AboutSection: View {
    @StateObject private var trial = TrialState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeader(icon: "info.circle", title: "About")

                SettingsCard {
                    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
                    HStack(spacing: 12) {
                        Image("SprichLogo")
                            .resizable()
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sprich").font(.system(size: 15, weight: .semibold))
                            Text("Version \(appVersion)")
                                .font(.caption).foregroundColor(.secondary)
                            Text("Speech-to-text for macOS")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    // Trial / licensed state row (UX audit P0 #4 surface).
                    switch trial.entitlement {
                    case .trialActive:
                        Divider().padding(.vertical, 4)
                        HStack {
                            Text("Trial — \(trial.daysRemaining) day\(trial.daysRemaining == 1 ? "" : "s") left")
                                .font(.caption)
                            Spacer()
                            Button("Upgrade to lifetime") {
                                NSWorkspace.shared.open(URL(string: "https://sprichapp.com/pricing")!)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    case .licensed:
                        Divider().padding(.vertical, 4)
                        Label("Lifetime license active", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .trialExpired, .signedOut, .unknown, .deviceBlocked:
                        EmptyView()
                    }
                }

                SettingsCard {
                    Text("AI model attributions")
                        .font(.caption).foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speech-to-text uses Whisper (OpenAI), running on-device via WhisperKit.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("On-device AI cleanup uses Gemma 3 by Google, running locally via llama.cpp.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        // Sprint 2F mandatory Gemma attribution string (verbatim).
                        // Relocated from the Privacy tab to About per Decision 4.
                        Text("Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }

                SettingsCard {
                    Text("Support")
                        .font(.caption).foregroundColor(.secondary)
                    Link("support@sprichapp.com",
                         destination: URL(string: "mailto:support@sprichapp.com")!)
                        .font(.caption)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - ModesSection (P1-UX-05 + P1-UX-06)

/// Three mode editors (Literal / Formal / Custom). The mode-per-hotkey
/// surface is Sprich's #1 differentiator per the OW audit — this section
/// stays a first-class destination. Each mode has its system-prompt
/// editor + hotkey display + Reset-to-default. Formal also has the
/// adapt-tone-to-destination-app toggle. Autosaves on field commit.
private struct ModesSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeader(icon: "text.quote", title: "Modes")

                Text("Three dictation modes, each on its own hotkey. Pick the right one as you press — no menus, no settings round-trip.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsCard {
                    HStack {
                        Text("Literal").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        shortcutChip("Fn + Shift")
                    }
                    Text("Fast clean-up via Whisper only (no AI rewrite). Punctuation and capitalization polished locally.")
                        .font(.caption).foregroundColor(.secondary)
                    promptEditor($appState.settings.literalPrompt)
                    HStack {
                        Button("Reset to default") {
                            appState.settings.literalPrompt = TranscriptionMode.literal.defaultSystemPrompt
                            appState.saveSettings()
                        }
                        .font(.caption)
                        Spacer()
                    }
                    .onChange(of: appState.settings.literalPrompt) { _, _ in
                        appState.saveSettings()
                    }
                }

                SettingsCard {
                    HStack {
                        Text("Formal").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        shortcutChip("Fn + Control")
                    }
                    Text("Full AI rewrite for professional written text.")
                        .font(.caption).foregroundColor(.secondary)
                    promptEditor($appState.settings.formalPrompt)
                    HStack {
                        Button("Reset to default") {
                            appState.settings.formalPrompt = TranscriptionMode.formal.defaultSystemPrompt
                            appState.saveSettings()
                        }
                        .font(.caption)
                        Spacer()
                    }

                    Divider().padding(.vertical, 4)

                    Toggle("Adapt tone to destination app", isOn: $appState.settings.adaptToSurface)
                        .toggleStyle(.switch)
                        .onChange(of: appState.settings.adaptToSurface) { _, _ in
                            appState.saveSettings()
                        }
                    Text("Matches the rewrite to where you're pasting — email greeting for Gmail/Mail, terse for Slack/Teams/Messages, clean prose for docs. Reads the active browser tab URL for web apps (one-time Automation permission).")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: appState.settings.formalPrompt) { _, _ in
                        appState.saveSettings()
                    }
                }

                SettingsCard {
                    HStack {
                        Text("Custom").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        shortcutChip("Fn + Command")
                    }

                    Toggle("Enable custom mode", isOn: $appState.settings.customModeEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: appState.settings.customModeEnabled) { _, _ in
                            appState.saveSettings()
                        }

                    if appState.settings.customModeEnabled {
                        Divider().padding(.vertical, 4)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Name").font(.caption).foregroundColor(.secondary)
                                TextField("", text: $appState.settings.customModeName,
                                          prompt: Text("Slack"))
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { appState.saveSettings() }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Badge").font(.caption).foregroundColor(.secondary)
                                TextField("", text: Binding(
                                    get: { appState.settings.customModeBadge },
                                    set: {
                                        appState.settings.customModeBadge = String($0.prefix(1)).uppercased()
                                        appState.saveSettings()
                                    }
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
                                set: {
                                    appState.settings.customModePrompt = String($0.prefix(400))
                                    appState.saveSettings()
                                }
                            ))
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func promptEditor(_ text: Binding<String>) -> some View {
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
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15)))
    }
}

// MARK: - GeneralSection (P1-UX-04 + P1-UX-06)

/// Input mode + max recording duration + keyboard shortcuts read-out +
/// permissions. About content moved to AboutSection (P1-UX-12).
/// Autosaves on field commit (P1-UX-06) — no Save button.
private struct GeneralSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeader(icon: "gear", title: "General")

                SettingsCard {
                    Text("Input mode")
                        .font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $appState.settings.inputMode) {
                        ForEach(InputMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: appState.settings.inputMode) { _, _ in
                        appState.saveSettings()
                    }
                }

                SettingsCard {
                    Text("Safety")
                        .font(.caption).foregroundColor(.secondary)
                    Stepper(
                        "Max recording: \(appState.settings.maxRecordingDuration)s",
                        value: $appState.settings.maxRecordingDuration,
                        in: 30...600,
                        step: 30
                    )
                    .onChange(of: appState.settings.maxRecordingDuration) { _, _ in
                        appState.saveSettings()
                    }
                }

                SettingsCard {
                    Text("Keyboard shortcuts")
                        .font(.caption).foregroundColor(.secondary)
                    VStack(spacing: 8) {
                        shortcutRow(name: "Literal mode", keys: "Fn + Shift")
                        shortcutRow(name: "Formal mode", keys: "Fn + Control")
                        if appState.settings.customModeEnabled {
                            shortcutRow(
                                name: appState.settings.customModeName.isEmpty ? "Custom mode" : appState.settings.customModeName,
                                keys: "Fn + Command"
                            )
                        }
                    }
                }

                SettingsCard {
                    Text("Permissions")
                        .font(.caption).foregroundColor(.secondary)
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

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func shortcutRow(name: String, keys: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15)))
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
                // Orange instead of red (UX audit P2 — match Onboarding
                // tone: orange = action needed, red = blocking error).
                Image(systemName: "xmark.circle.fill").foregroundColor(.orange)
                if let action = action {
                    Button("Open Settings", action: action)
                        .controlSize(.small)
                } else if let note = pendingNote {
                    Text(note).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - AIModelsSection (P1-UX-08 — STT half; P1-UX-09 lands LLM half + sidebar wiring)

/// Load-bearing section of the sidebar IA. Two stacked sub-sections —
/// Speech recognition + AI cleanup — each rendered as a `ProviderCardPair`
/// (Cloud / On this Mac) with a context-aware config view below.
///
/// Decision 2 in `sprint-3-settings-ux.md`. This commit lands the section
/// shell + the Speech-recognition half. The AI-cleanup half is stubbed
/// pending P1-UX-09, after which the sidebar switch in `SettingsView.body`
/// swaps `sectionPlaceholder(.aiModels)` for this view.
private struct AIModelsSection: View {
    @EnvironmentObject var appState: AppState

    @Binding var groqKey: String
    @Binding var openAIKey: String
    @Binding var deepgramKey: String
    @Binding var anthropicKey: String
    @Binding var googleKey: String

    @Binding var hardwareTier: HardwareProbe.Tier
    let onRequestWhisperDownload: () -> Void
    let onRequestLLMDownload: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeader(icon: "brain", title: "AI Models")

                Text("Pick where the AI runs. Cloud is the fastest setup; On this Mac is private and free after the first download.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                speechRecognitionCard

                aiCleanupCard

                languageCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Language pin (P1-UX-10)

    /// Optional language hint passed to the STT provider. nil = auto-detect,
    /// which Whisper handles well for ~98% of cases; pinning is the escape
    /// hatch when auto-detect picks the wrong tongue mid-sentence (the user
    /// pain point that drove this row to be first-class).
    @ViewBuilder
    private var languageCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Language")
                    .font(.system(size: 13, weight: .semibold))
                Picker("", selection: Binding(
                    get: { appState.settings.preferredLanguage ?? "auto" },
                    set: { newValue in
                        appState.settings.preferredLanguage = newValue == "auto" ? nil : newValue
                        appState.saveSettings()
                    }
                )) {
                    ForEach(AppLanguages.all, id: \.code) { lang in
                        Text(lang.displayName).tag(lang.code ?? "auto")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text("Pin speech recognition to a specific language, or let the provider detect it.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Speech recognition (P1-UX-08)

    @ViewBuilder
    private var speechRecognitionCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speech recognition")
                    .font(.system(size: 13, weight: .semibold))

                ProviderCardPair(
                    isLocalSelected: appState.settings.sttProvider.isLocal,
                    cloudTitle: "Cloud",
                    cloudIcon: "cloud",
                    cloudSubtitle: "Fastest setup · API key required",
                    cloudDescription: "Audio is sent to the chosen provider for transcription. Best quality, no model download.",
                    localTitle: "On this Mac",
                    localIcon: "laptopcomputer",
                    localSubtitle: "Private · no API key",
                    localDescription: "Runs on-device with WhisperKit. Slower the very first time (~10–30 s) while macOS compiles the model.",
                    onSelectCloud: selectCloudSTT,
                    onSelectLocal: selectLocalSTT
                )

                Divider().padding(.vertical, 2)

                if appState.settings.sttProvider.isLocal {
                    LocalProviderConfigView(
                        kind: .stt,
                        hardwareTier: $hardwareTier,
                        onRequestDownload: onRequestWhisperDownload
                    )
                    .environmentObject(appState)
                } else {
                    CloudProviderConfigView(
                        kind: .stt,
                        groqKey: $groqKey,
                        openAIKey: $openAIKey,
                        deepgramKey: $deepgramKey,
                        anthropicKey: $anthropicKey,
                        googleKey: $googleKey
                    )
                    .environmentObject(appState)
                }
            }
        }
    }

    private func selectCloudSTT() {
        // Default cloud STT pick is Groq — fastest, cheapest, and the same
        // key powers Groq LLM cleanup so most users have it already. The
        // sub-picker inside `CloudProviderConfigView` lets users move from
        // there to OpenAI or Deepgram.
        guard appState.settings.sttProvider.isLocal else { return }
        appState.settings.sttProvider = .groq
        appState.saveSettings()
    }

    private func selectLocalSTT() {
        guard !appState.settings.sttProvider.isLocal else { return }
        appState.settings.sttProvider = .local
        appState.saveSettings()
        // Refresh state so the warning-banner reflects on-disk truth.
        WhisperModelManager.shared.refreshState(
            for: appState.settings.localWhisperModel
        )
        TranscriptionService.prewarmLocalWhisperIfReady(
            model: appState.settings.localWhisperModel
        )
    }

    // MARK: AI cleanup (P1-UX-09)

    @ViewBuilder
    private var aiCleanupCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI cleanup")
                    .font(.system(size: 13, weight: .semibold))
                Text("Used by Formal and Custom modes. Literal mode skips the AI cleanup entirely.")
                    .font(.caption).foregroundColor(.secondary)

                ProviderCardPair(
                    isLocalSelected: appState.settings.llmProvider.isLocal,
                    cloudTitle: "Cloud",
                    cloudIcon: "cloud",
                    cloudSubtitle: "Fastest setup · API key required",
                    cloudDescription: "Transcribed text is sent to the chosen provider for cleanup. Best quality, no model download.",
                    localTitle: "On this Mac",
                    localIcon: "laptopcomputer",
                    localSubtitle: "Private · no API key",
                    localDescription: "Runs on-device with Gemma 3 1B via llama.cpp. ~0.8 GB one-time download. Needs Apple Silicon + 8 GB RAM.",
                    onSelectCloud: selectCloudLLM,
                    onSelectLocal: selectLocalLLM
                )

                Divider().padding(.vertical, 2)

                if appState.settings.llmProvider.isLocal {
                    LocalProviderConfigView(
                        kind: .llm,
                        hardwareTier: $hardwareTier,
                        onRequestDownload: onRequestLLMDownload
                    )
                    .environmentObject(appState)
                } else {
                    CloudProviderConfigView(
                        kind: .llm,
                        groqKey: $groqKey,
                        openAIKey: $openAIKey,
                        deepgramKey: $deepgramKey,
                        anthropicKey: $anthropicKey,
                        googleKey: $googleKey
                    )
                    .environmentObject(appState)
                }
            }
        }
    }

    private func selectCloudLLM() {
        guard appState.settings.llmProvider.isLocal else { return }
        // Default cloud LLM pick is Groq — reuses the STT key, so the
        // most common path is "user already has a Groq key, just flip
        // the card." Sub-picker in CloudProviderConfigView lets them
        // move to Claude / Gemini / OpenAI from there.
        appState.settings.llmProvider = .groq
        appState.saveSettings()
    }

    private func selectLocalLLM() {
        guard !appState.settings.llmProvider.isLocal else { return }
        // Sprint 2F Decision 7a: still let the user pick Local even on
        // Eligible hardware — the warning copy + disabled Download
        // button surfaces the constraint. .notSupported is the only
        // block, and we don't guard here (the warning + disabled
        // button do the work).
        appState.settings.llmProvider = .local
        appState.saveSettings()
        LLMModelManager.shared.refreshState(for: LocalLLMModelSpec.defaultSpec)
    }
}

// MARK: - AIModelsSection building blocks (P1-UX-07)

/// Distinguishes a Speech-recognition row from an AI-cleanup row. The two
/// halves of `AIModelsSection` share the same Cloud/Local config view shape;
/// `ProviderKind` flips wording, picker contents, and (for local) whether
/// the HardwareProbe badge appears (LLM-only — STT runs anywhere).
private enum ProviderKind {
    case stt
    case llm
}

/// Cloud branch of the AI Models config (P1-UX-07).
///
/// Decision 3 in `sprint-3-settings-ux.md`: cloud config is *almost* fully
/// visible — the only thing tucked away is the model-name string, which
/// 95% of users don't touch. Layout:
///   1. Cloud sub-provider segmented picker (Groq / OpenAI / Deepgram for
///      STT; Groq / Claude / Gemini / OpenAI for LLM).
///   2. Inline API-key SecureField for the currently-selected sub-provider.
///      Edits write straight to Keychain on field commit — no Save button.
///   3. "Advanced — model name" `DisclosureGroup` (LLM only) for the
///      model-string field. STT model strings are baked into each provider,
///      so the disclosure isn't shown for `.stt`.
private struct CloudProviderConfigView: View {
    @EnvironmentObject var appState: AppState
    let kind: ProviderKind

    @Binding var groqKey: String
    @Binding var openAIKey: String
    @Binding var deepgramKey: String
    @Binding var anthropicKey: String
    @Binding var googleKey: String

    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            subProviderPicker
            keyField
            if kind == .llm {
                advancedDisclosure
            }
        }
    }

    // MARK: Sub-picker

    @ViewBuilder
    private var subProviderPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind == .stt ? "Cloud provider" : "Cloud provider")
                .font(.caption).foregroundColor(.secondary)
            switch kind {
            case .stt:
                Picker("", selection: sttCloudBinding) {
                    Text("Groq").tag(STTProviderType.groq)
                    Text("OpenAI").tag(STTProviderType.openai)
                    Text("Deepgram").tag(STTProviderType.deepgram)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            case .llm:
                Picker("", selection: llmCloudBinding) {
                    Text("Groq").tag(LLMProviderType.groq)
                    Text("Claude").tag(LLMProviderType.claude)
                    Text("Gemini").tag(LLMProviderType.google)
                    Text("OpenAI").tag(LLMProviderType.openai)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Text(currentProviderBlurb)
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bound to `appState.settings.sttProvider` but guarded against writes of
    /// `.local` (the local branch is shown by `LocalProviderConfigView`, not
    /// this view, so the segmented picker's tag set is cloud-only). If the
    /// upstream value is somehow `.local` when this view is on screen, fall
    /// back to `.groq` for display so the picker doesn't crash.
    private var sttCloudBinding: Binding<STTProviderType> {
        Binding(
            get: {
                let p = appState.settings.sttProvider
                return p.isLocal ? .groq : p
            },
            set: { newValue in
                appState.settings.sttProvider = newValue
                appState.saveSettings()
            }
        )
    }

    private var llmCloudBinding: Binding<LLMProviderType> {
        Binding(
            get: {
                let p = appState.settings.llmProvider
                return p.isLocal ? .groq : p
            },
            set: { newValue in
                appState.settings.llmProvider = newValue
                appState.saveSettings()
            }
        )
    }

    private var currentProviderBlurb: String {
        switch kind {
        case .stt:
            switch appState.settings.sttProvider {
            case .groq:     return "Fastest & cheapest (~$0.0007/min). Whisper large-v3 via Groq cloud."
            case .openai:   return "Standard Whisper API (~$0.006/min). Most reliable."
            case .deepgram: return "Nova-3 model (~$0.008/min). Excellent real-time performance."
            case .local:    return ""
            }
        case .llm:
            switch appState.settings.llmProvider {
            case .groq:    return "Fastest. Reuses your Groq STT key — no extra key needed."
            case .claude:  return "Claude (Anthropic). Strong at long-form rewrites."
            case .google:  return "Gemini (Google). Generous free tier."
            case .openai:  return "OpenAI. GPT-4o-mini by default."
            case .local:   return ""
            }
        }
    }

    // MARK: API key field

    @ViewBuilder
    private var keyField: some View {
        let provider = currentKeychainProvider
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.label)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Link(provider.dashboardLabel,
                     destination: URL(string: provider.dashboardURL)!)
                    .font(.caption2)
            }
            SecureField("", text: provider.binding, prompt: Text("sk-…"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: provider.binding.wrappedValue) { _, newValue in
                    // Autosave to Keychain on every keystroke. Empty value
                    // = user cleared the field; we still write so the
                    // missing-key banner reflects the intent.
                    KeychainManager.store(key: provider.keychainKey, value: newValue)
                }
            if kind == .llm, appState.settings.llmProvider == .groq {
                Text("Same key powers the fastest STT — no separate Groq STT key needed.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// Resolves which key (label + binding + dashboard URL) the inline field
    /// should render, based on the currently-selected sub-provider. Pulls
    /// label/URL strings out of the provider enums so this view stays
    /// label-agnostic when copy changes elsewhere.
    private var currentKeychainProvider: ResolvedCloudKey {
        switch kind {
        case .stt:
            switch appState.settings.sttProvider {
            case .groq:
                return .init(label: "Groq API key",
                             binding: $groqKey,
                             keychainKey: STTProviderType.groq.keychainKey,
                             dashboardURL: "https://console.groq.com/keys",
                             dashboardLabel: "Get a key →")
            case .openai:
                return .init(label: "OpenAI API key",
                             binding: $openAIKey,
                             keychainKey: STTProviderType.openai.keychainKey,
                             dashboardURL: "https://platform.openai.com/api-keys",
                             dashboardLabel: "Get a key →")
            case .deepgram:
                return .init(label: "Deepgram API key",
                             binding: $deepgramKey,
                             keychainKey: STTProviderType.deepgram.keychainKey,
                             dashboardURL: "https://console.deepgram.com",
                             dashboardLabel: "Get a key →")
            case .local:
                // Defensive — local should never render this view.
                return .init(label: "Groq API key",
                             binding: $groqKey,
                             keychainKey: STTProviderType.groq.keychainKey,
                             dashboardURL: "https://console.groq.com/keys",
                             dashboardLabel: "Get a key →")
            }
        case .llm:
            switch appState.settings.llmProvider {
            case .groq:
                return .init(label: "Groq API key (shared with STT)",
                             binding: $groqKey,
                             keychainKey: LLMProviderType.groq.keychainKey,
                             dashboardURL: "https://console.groq.com/keys",
                             dashboardLabel: "Get a key →")
            case .claude:
                return .init(label: "Anthropic API key",
                             binding: $anthropicKey,
                             keychainKey: LLMProviderType.claude.keychainKey,
                             dashboardURL: "https://console.anthropic.com/settings/keys",
                             dashboardLabel: "Get a key →")
            case .google:
                return .init(label: "Google API key",
                             binding: $googleKey,
                             keychainKey: LLMProviderType.google.keychainKey,
                             dashboardURL: "https://aistudio.google.com/apikey",
                             dashboardLabel: "Get a key →")
            case .openai:
                return .init(label: "OpenAI API key",
                             binding: $openAIKey,
                             keychainKey: LLMProviderType.openai.keychainKey,
                             dashboardURL: "https://platform.openai.com/api-keys",
                             dashboardLabel: "Get a key →")
            case .local:
                return .init(label: "Groq API key",
                             binding: $groqKey,
                             keychainKey: LLMProviderType.groq.keychainKey,
                             dashboardURL: "https://console.groq.com/keys",
                             dashboardLabel: "Get a key →")
            }
        }
    }

    private struct ResolvedCloudKey {
        let label: String
        let binding: Binding<String>
        let keychainKey: String
        let dashboardURL: String
        let dashboardLabel: String
    }

    // MARK: Advanced disclosure (LLM only)

    @ViewBuilder
    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model name")
                    .font(.caption).foregroundColor(.secondary)
                TextField("", text: modelBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { appState.saveSettings() }
                Text("Override only if you know the exact model ID you want.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(.top, 6)
        } label: {
            Text("Advanced — model name")
                .font(.caption)
                .foregroundColor(.accentColor)
        }
    }

    private var modelBinding: Binding<String> {
        switch appState.settings.llmProvider {
        case .groq:   return $appState.settings.groqLLMModel
        case .claude: return $appState.settings.claudeModel
        case .google: return $appState.settings.googleModel
        case .openai: return $appState.settings.openAILLMModel
        case .local:  return .constant("")  // unreachable
        }
    }
}

/// Local (on-device) branch of the AI Models config (P1-UX-07).
///
/// Decision 3: local config is fully inline — no DisclosureGroup. Everything
/// the user needs to see is at the top level. Layout:
///   1. Hardware probe badge + Re-check (LLM only — STT runs on any Mac).
///   2. Status row (downloading / verifying / preparing / ready / failed)
///      with the right action button on the right (Download / Cancel /
///      Delete).
///   3. Quality picker — Whisper: Fast / Balanced / Accurate segmented;
///      Gemma: 1B selected, 2B/4B disabled placeholders for now.
///   4. Friendly missing-model warning when the user picked `.local` but
///      no bytes are on disk (mirrors the orphan helpers' pattern —
///      reused verbatim until orphan cleanup lands in P1-UX-09 follow-up).
private struct LocalProviderConfigView: View {
    @EnvironmentObject var appState: AppState
    let kind: ProviderKind
    @Binding var hardwareTier: HardwareProbe.Tier
    let onRequestDownload: () -> Void

    @ObservedObject private var whisperManager = WhisperModelManager.shared
    @ObservedObject private var llmManager = LLMModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if kind == .llm {
                hardwareTierBadge
            }
            statusRow
            qualityPicker
            if shouldShowMissingWarning {
                missingModelWarning
            }
            if kind == .llm {
                // Honest copy reinforcing Sprint 2F Decision 5a/5b/5c —
                // local LLM never falls back to cloud silently.
                Text("Runs fully on your Mac. There's no cloud fallback — to use a cloud model, switch to the Cloud card above.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Hardware badge (LLM only)

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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Re-check") {
                hardwareTier = HardwareProbe.evaluate()
            }
            .controlSize(.small)
            .font(.caption2)
        }
    }

    private var hardwareTierEmoji: String {
        switch hardwareTier {
        case .recommended:   return "🟢"
        case .eligible:      return "🟡"
        case .notSupported:  return "🔴"
        }
    }

    // MARK: Status row

    @ViewBuilder
    private var statusRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusIconName)
                .foregroundStyle(statusIconColor)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(modelDisplayName)
                    .font(.system(.caption, design: .monospaced))
                Text(statusSubline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actionButton
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        switch kind {
        case .stt:
            switch whisperManager.state {
            case .ready:
                Button("Delete") {
                    try? whisperManager.deleteModel(appState.settings.localWhisperModel)
                }
                .controlSize(.small)
            case .downloading:
                Button("Cancel") { whisperManager.cancelDownload() }
                    .controlSize(.small)
            case .preparing:
                ProgressView().controlSize(.small)
            default:
                Button("Download") { onRequestDownload() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        case .llm:
            switch llmManager.state {
            case .ready:
                Button("Delete") {
                    try? llmManager.deleteModel(LocalLLMModelSpec.defaultSpec)
                }
                .controlSize(.small)
            case .downloading, .verifying:
                Button("Cancel") { llmManager.cancelDownload() }
                    .controlSize(.small)
            case .preparing:
                ProgressView().controlSize(.small)
            default:
                Button("Download (\(formatBytes(LocalLLMModelSpec.defaultSpec.expectedSize)))") {
                    onRequestDownload()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!hardwareTier.supportsLocalLLM)
            }
        }
    }

    private var modelDisplayName: String {
        switch kind {
        case .stt: return appState.settings.localWhisperModel
        case .llm: return LocalLLMModelSpec.defaultSpec.displayName
        }
    }

    private var statusIconName: String {
        switch kind {
        case .stt:
            switch whisperManager.state {
            case .ready:                  return "checkmark.circle.fill"
            case .downloading, .preparing: return "arrow.down.circle"
            case .failed, .absent, .unknown: return "exclamationmark.triangle.fill"
            }
        case .llm:
            switch llmManager.state {
            case .ready:                                 return "checkmark.circle.fill"
            case .downloading, .verifying, .preparing:   return "arrow.down.circle"
            case .failed:                                return "exclamationmark.octagon.fill"
            default:                                     return "circle.dashed"
            }
        }
    }

    private var statusIconColor: Color {
        switch kind {
        case .stt:
            switch whisperManager.state {
            case .ready:                       return .green
            case .failed, .absent, .unknown:   return .orange
            default:                           return .secondary
            }
        case .llm:
            switch llmManager.state {
            case .ready:                                 return .green
            case .downloading, .verifying, .preparing:   return .blue
            case .failed:                                return .red
            default:                                     return .secondary
            }
        }
    }

    private var statusSubline: String {
        switch kind {
        case .stt:
            switch whisperManager.state {
            case .ready(_, let size):
                let fmt = ByteCountFormatter(); fmt.countStyle = .file
                let sizeStr = fmt.string(fromByteCount: size)
                if whisperManager.isPipeReady {
                    return "Ready · \(sizeStr) on disk"
                } else {
                    return "Optimizing for your Mac (one-time, ~10–30 s) · \(sizeStr) on disk"
                }
            case .downloading(let p):  return "Downloading \(Int(p * 100))%"
            case .preparing:           return "Optimizing for your Mac (one-time, ~10–30 s)"
            case .failed(let msg):     return msg
            case .absent, .unknown:    return "Not downloaded — dictation will not work"
            }
        case .llm:
            switch llmManager.state {
            case .unknown:                   return "Status not checked yet."
            case .absent:                    return "Not downloaded."
            case .downloading(let p):        return "Downloading… \(Int(p * 100))%"
            case .verifying:                 return "Verifying integrity (SHA-256)…"
            case .preparing:                 return "Preparing model…"
            case .ready(_, let sizeBytes):   return "Ready · \(formatBytes(sizeBytes)) on disk"
            case .failed(let err):           return err.errorDescription ?? "Setup failed."
            }
        }
    }

    // MARK: Quality picker

    @ViewBuilder
    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quality")
                .font(.caption).foregroundColor(.secondary)
            switch kind {
            case .stt:
                Picker("", selection: Binding(
                    get: { appState.settings.localWhisperModel },
                    set: { newValue in
                        appState.settings.localWhisperModel = newValue
                        appState.saveSettings()
                        whisperManager.refreshState(for: newValue)
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
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .llm:
                // Phase 1 ships Gemma 3 1B only; 2B / 4B placeholders are
                // disabled so users see the trajectory. Re-enable in a
                // follow-up sprint when the larger specs land.
                Picker("", selection: Binding(
                    get: { appState.settings.localLLMModel },
                    set: { newValue in
                        appState.settings.localLLMModel = newValue
                        appState.saveSettings()
                    }
                )) {
                    Text("Gemma 3 1B — 0.8 GB").tag(LocalLLMModelSpec.defaultSpec.id)
                    Text("Gemma 2 2B — coming soon").tag("gemma-2-2b-it-q4_k_m")
                    Text("Gemma 3 4B — coming soon").tag("gemma-3-4b-it-q4_k_m")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(true)
                if case .eligible = hardwareTier {
                    Text("Quality presets (2B / 4B) unlock on 16 GB+ Macs in a future update.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: Missing-model warning

    private var shouldShowMissingWarning: Bool {
        switch kind {
        case .stt:
            // Only warn when the user has actually picked Local STT.
            guard appState.settings.sttProvider.isLocal else { return false }
            switch whisperManager.state {
            case .ready, .downloading, .preparing: return false
            case .absent, .unknown, .failed:       return true
            }
        case .llm:
            guard appState.settings.llmProvider.isLocal else { return false }
            if case .ready = llmManager.state { return false }
            if llmManager.state.isBusy { return false }
            return true
        }
    }

    @ViewBuilder
    private var missingModelWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(warningTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(warningSubtitle)
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5))
    }

    private var warningTitle: String {
        switch kind {
        case .stt: return "Local dictation won't work until the model is downloaded."
        case .llm: return "Formal and Custom modes won't work until the AI model is downloaded."
        }
    }

    private var warningSubtitle: String {
        switch kind {
        case .stt:
            if let option = WhisperModelCatalog.option(for: appState.settings.localWhisperModel) {
                return "Click Download above. ~\(option.approxSizeMB) MB, one-time."
            }
            return "Click Download above."
        case .llm:
            return "Default (Literal) mode keeps working — it doesn't use the AI cleanup model. Tap Download above when you're on Wi-Fi."
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
