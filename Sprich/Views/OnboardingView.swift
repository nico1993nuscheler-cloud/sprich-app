import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0
    @State private var groqKey = ""

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
                case 3: apiKeyStep
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
                if Permissions.isAccessibilityGranted() {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Granted").font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.orange)
                    Text("Not granted yet").font(.system(size: 13, weight: .semibold))
                }
            }

            if !Permissions.isAccessibilityGranted() {
                Button("Open Accessibility Settings") {
                    Permissions.promptAccessibility()
                }
                .buttonStyle(.bordered)

                Text("A system prompt will appear. Click **Open System Settings**, then toggle Sprich on. You may need to relaunch Sprich afterwards.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            navRow(primaryLabel: Permissions.isAccessibilityGranted() ? "Continue" : "I've granted access") {
                currentStep = 2
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
                if Permissions.isMicrophoneGranted() {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Granted").font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "mic.slash.fill").foregroundColor(.orange)
                    Text("Not granted yet").font(.system(size: 13, weight: .semibold))
                }
            }

            if !Permissions.isMicrophoneGranted() {
                Button("Grant Microphone Access") {
                    Task { _ = await Permissions.requestMicrophone() }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            navRow(primaryLabel: "Continue") { currentStep = 3 }
        }
    }

    // MARK: - Step 3 — Groq key

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 3 — Groq API Key").font(.title2).fontWeight(.semibold)

            Text("Sprich uses Groq by default — the fastest and cheapest cloud Whisper (≈ €0.0007/min). The same key powers the Formal-mode cleanup. That's all you need to get started.")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Groq API key")
                    .font(.caption).foregroundColor(.secondary)
                SecureField("gsk_…", text: $groqKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundColor(.accentColor)
                Link("Get a free Groq key at console.groq.com",
                     destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
            }

            Text("You can add OpenAI, Deepgram, Claude or Gemini later from Settings → API Keys.")
                .font(.caption).foregroundColor(.secondary).padding(.top, 2)

            Spacer()

            HStack {
                if currentStep > 0 {
                    Button("Back") { currentStep -= 1 }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
                Spacer()
                Button("Skip for now") { currentStep = 4 }
                    .buttonStyle(.plain).foregroundColor(.secondary)
                Button("Save & Continue") {
                    let trimmed = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        KeychainManager.store(
                            key: STTProviderType.groq.keychainKey,
                            value: trimmed
                        )
                    }
                    currentStep = 4
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(groqKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Step 4 — Shortcut cheat-sheet

    private var finalStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your shortcuts").font(.title2).fontWeight(.bold)

            Text("Hold the combo, speak, release. The cleaned text is pasted into whatever app is focused.")
                .foregroundColor(.secondary).font(.callout)

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
