import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

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

    var body: some View {
        TabView {
            apiKeysTab
                .tabItem { Label("API Keys", systemImage: "key") }

            providersTab
                .tabItem { Label("Providers", systemImage: "server.rack") }

            modesTab
                .tabItem { Label("Modes", systemImage: "text.quote") }

            dictionaryTab
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            generalTab
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 620, height: 620)
        .onAppear(perform: loadKeys)
        .alert("Settings Saved", isPresented: $showSavedAlert) {
            Button("OK", role: .cancel) {}
        }
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
                    providerDescription(for: appState.settings.sttProvider)

                    if !hasKey(forSTT: appState.settings.sttProvider) {
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
                        Text("Auto-detect").tag("auto")
                        Text("Deutsch").tag("de")
                        Text("English").tag("en")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
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
                    HStack {
                        Image("SprichLogo")
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sprich v1.0.0").font(.system(size: 13, weight: .semibold))
                            Text("Open-source speech-to-text for macOS")
                                .font(.caption).foregroundColor(.secondary)
                        }
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
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    // MARK: - Key validation

    private func hasKey(forSTT provider: STTProviderType) -> Bool {
        // Re-read from Keychain each body re-eval; cheap and always current.
        _ = groqKey; _ = openAIKey; _ = deepgramKey  // force dependency on @State
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
