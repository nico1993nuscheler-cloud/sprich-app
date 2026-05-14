import SwiftUI
import AppKit

/// Sprint 2C onboarding: 4 cards.
///   0 — Welcome + Sign in (magic-link / OAuth via SignInPanel)
///   1 — Permissions (Accessibility + Microphone on one card)
///   2 — Provider + Preparing Sprich (provider radio + isPipeReady strip)
///   3 — Try it now (guided dictation test → confetti)
///
/// Sprint 3 P1-PRD-11 will redesign this further toward OpenWhisper's
/// 2-card model. Sprint 2C only adds what the funnel requires.
struct OnboardingView: View {
    /// PipelineCoordinator passed in from AppDelegate at window creation
    /// time — passing explicitly avoids the brittle
    /// `(NSApp.delegate as? AppDelegate)?.pipeline` lookup which was
    /// returning nil intermittently during onboarding scene-graph
    /// construction.
    let pipeline: PipelineCoordinator

    @EnvironmentObject var appState: AppState
    @StateObject private var auth = AuthService.shared
    @StateObject private var trial = TrialState.shared
    @ObservedObject private var whisperManager = WhisperModelManager.shared

    @State private var currentStep = 0

    @State private var groqKey = ""
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted()
    @State private var microphoneGranted = Permissions.isMicrophoneGranted()
    @State private var providerChoice: STTProviderType = .local
    @State private var cloudDisclosureExpanded = false

    /// Try-it-now state: text captured via PipelineCoordinator.interceptOutput,
    /// plus a one-shot `confettiActive` trigger.
    @State private var capturedText: String = ""
    @State private var confettiActive: Bool = false

    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch currentStep {
                case 0: welcomeSignInStep
                case 1: permissionsStep
                case 2: providerPreparingStep
                default: tryItNowStep
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
            providerChoice = appState.settings.sttProvider
            cloudDisclosureExpanded = !providerChoice.isLocal
        }
        .onReceive(permissionTimer) { _ in
            accessibilityGranted = Permissions.isAccessibilityGranted()
            microphoneGranted = Permissions.isMicrophoneGranted()
        }
        .onChange(of: auth.isSignedIn) { signedIn in
            // SwiftUI .onChange of a computed property derived from a
            // @Published is one signal — but in practice it has been
            // observed to miss the transition (especially when the
            // window isn't key during the OAuth/magic-link callback
            // round-trip). The .onReceive below is the reliable path;
            // this stays as a secondary trigger.
            if signedIn {
                #if DEBUG
                print("[Sprich][Onboarding] .onChange(isSignedIn=true) — advancing from step \(currentStep)")
                #endif
                advanceFromWelcomeIfSignedIn()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sprichAuthStateChanged)) { _ in
            // Primary auto-advance trigger. AuthService.completeSignIn
            // posts this notification on @MainActor immediately after
            // `currentSession` is set, for ALL three sign-in paths:
            // magic-link deep-link, Apple OAuth (ASWebAuth callback),
            // and Google OAuth (ASWebAuth callback). Observing the
            // notification directly avoids any flakiness in SwiftUI's
            // .onChange-of-computed-property observation.
            #if DEBUG
            print("[Sprich][Onboarding] .sprichAuthStateChanged received — isSignedIn=\(auth.isSignedIn) currentStep=\(currentStep)")
            #endif
            advanceFromWelcomeIfSignedIn()
        }
        .onChange(of: currentStep) { newStep in
            // Re-install the intercept hook every time the user actually
            // enters Try-it-now (step 3). We can't rely on tryItNowStep's
            // .onAppear alone because SwiftUI may fire it eagerly at
            // scene-graph construction time before pipeline is ready.
            // Clear it when leaving the step so a stray transcription
            // doesn't bypass the focused app's paste target.
            if newStep == 3 {
                installInterceptHook()
            } else {
                clearInterceptHook()
            }
        }
    }

    /// Auto-advance from the Welcome+Sign-in card to the Permissions card
    /// once the user is signed in. Idempotent — safe to call from
    /// multiple sources (notification + .onChange). The 0.6 s delay lets
    /// the green "Signed in as …" summary flash briefly so the user
    /// sees a confirmation beat before the card swaps.
    private func advanceFromWelcomeIfSignedIn() {
        guard AuthService.shared.isSignedIn else { return }
        guard currentStep == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard currentStep == 0 else { return }
            #if DEBUG
            print("[Sprich][Onboarding] advance: step 0 → 1")
            #endif
            currentStep = 1
        }
    }

    // MARK: - Shared header / progress

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

    // MARK: - Step 0 — Welcome + Sign in

    private var welcomeSignInStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Sprich").font(.title).fontWeight(.bold)

            Text("Turn your voice into clean text in any app — emails, chats, docs, code comments. Hold a shortcut, speak, release. Done.")
                .foregroundColor(.secondary)

            if auth.isSignedIn {
                signedInSummary
            } else {
                SignInPanel(showsHeader: false)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if auth.isSignedIn {
                    Button("Continue") { currentStep = 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip — sign in later") { currentStep = 1 }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var signedInSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("Signed in as **\(auth.currentUserEmail ?? "")**")
                    .font(.callout)
            }
            switch trial.entitlement {
            case .trialActive:
                Text("Your 7-day trial is active — \(trial.daysRemaining) day\(trial.daysRemaining == 1 ? "" : "s") left.")
                    .font(.caption).foregroundColor(.secondary)
            case .licensed:
                Text("Lifetime license attached. Welcome aboard.")
                    .font(.caption).foregroundColor(.secondary)
            case .unknown:
                Text("Starting your trial…")
                    .font(.caption).foregroundColor(.secondary)
            case .trialExpired, .signedOut:
                Text("Reach out to support@sprichapp.com if you don't see a trial here — we'll sort it out.")
                    .font(.caption).foregroundColor(.secondary)
            case .deviceBlocked:
                Text(trial.lastError
                     ?? "This Mac is already linked to another Sprich account. Sign in with that account, or email support@sprichapp.com to release the device.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.08))
        )
    }

    // MARK: - Step 1 — Permissions (Accessibility + Microphone combined)

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.title2).fontWeight(.semibold)

            Text("Sprich needs two macOS permissions to listen for your shortcut and capture your voice. Audio is sent to your chosen provider only — never written to disk.")
                .font(.callout)
                .foregroundColor(.secondary)

            permissionRow(
                title: "Accessibility",
                explanation: "Lets Sprich listen for your global shortcut and paste transcribed text into the focused app.",
                granted: accessibilityGranted,
                cta: "Open Accessibility Settings",
                action: { Permissions.promptAccessibility() }
            )

            permissionRow(
                title: "Microphone",
                explanation: "Records audio while you hold the shortcut. Released audio is processed and discarded.",
                granted: microphoneGranted,
                cta: "Grant Microphone Access",
                action: {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        microphoneGranted = Permissions.isMicrophoneGranted()
                    }
                }
            )

            Spacer()

            navRow(primaryLabel: "Continue") { currentStep = 2 }
        }
    }

    private func permissionRow(
        title: String,
        explanation: String,
        granted: Bool,
        cta: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .orange)
                .font(.system(size: 18))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(granted ? "Granted" : "Not granted")
                        .font(.caption.weight(.medium))
                        .foregroundColor(granted ? .green : .orange)
                }
                Text(explanation)
                    .font(.caption).foregroundColor(.secondary)
                if !granted {
                    Button(cta, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 0.5)
        )
    }

    // MARK: - Step 2 — Provider + Preparing

    private var providerPreparingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your transcription").font(.title2).fontWeight(.semibold)

            Text("Sprich can transcribe fully on your Mac (default) or use a cloud API (recommended for the fastest, most polished output).")
                .foregroundColor(.secondary)

            providerOptionCard(
                choice: .local,
                icon: "lock.shield.fill",
                title: "Local (default)",
                badge: "No account · No API key · ~\(WhisperModelCatalog.balanced.approxSizeMB) MB one-time download",
                description: "Runs Whisper on your Mac with Apple Silicon acceleration. Best privacy, zero per-dictation cost."
            )

            DisclosureGroup(isExpanded: $cloudDisclosureExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A cloud key unlocks faster STT and the AI cleanup used in Formal/Custom modes. Groq's free tier is generous.")
                        .font(.caption).foregroundColor(.secondary)

                    providerOptionCard(
                        choice: .groq,
                        icon: "bolt.fill",
                        title: "Cloud — Groq (recommended)",
                        badge: "Free tier · powers STT + Formal cleanup",
                        description: "One key drives both transcription and Formal-mode polish."
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
                }
                .padding(.top, 8)
            } label: {
                Text("Cloud — recommended for fastest speed and Formal-mode cleanup")
                    .font(.system(size: 13, weight: .medium))
            }

            // Inline preparing-progress strip — shows when Local is the
            // active provider AND the model isn't already Ready. We
            // start the download as soon as the user lands on this step
            // so the bar climbs while they pick options.
            if providerChoice == .local {
                preparingStrip
            }

            Spacer()

            navRow(
                primaryLabel: providerPrimaryLabel,
                primaryDisabled: providerPrimaryDisabled
            ) {
                commitProviderChoice()
                currentStep = 3
            }
        }
        .onChange(of: providerChoice) { choice in
            if choice == .local {
                let model = appState.settings.localWhisperModel
                Task { @MainActor in
                    try? await WhisperModelManager.shared.ensureReady(model: model)
                }
            }
        }
        .onAppear {
            if providerChoice == .local {
                let model = appState.settings.localWhisperModel
                Task { @MainActor in
                    try? await WhisperModelManager.shared.ensureReady(model: model)
                }
            }
        }
    }

    private var providerPrimaryLabel: String {
        switch providerChoice {
        case .local:
            return whisperManager.isPipeReady ? "Continue — Sprich is ready" : "Continue — finish in the background"
        case .groq:
            return groqKey.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Continue"
                : "Save Key & Continue"
        default:
            return "Continue"
        }
    }

    private var providerPrimaryDisabled: Bool {
        if providerChoice == .groq {
            return groqKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return false
    }

    @ViewBuilder
    private var preparingStrip: some View {
        switch whisperManager.state {
        case .ready:
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Whisper is ready.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.08)))
        case .downloading(let p):
            HStack(spacing: 10) {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
                Text("Preparing Whisper… \(Int(p * 100))%")
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Compiling Core ML graph (one-time, ~10–30 s)…")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        case .failed(let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Whisper download failed: \(msg). Open Settings → Providers → Local to retry.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        default:
            EmptyView()
        }
    }

    private func commitProviderChoice() {
        appState.settings.sttProvider = providerChoice
        appState.saveSettings()
        switch providerChoice {
        case .local:
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

    // MARK: - Step 3 — Try it now

    private var tryItNowStep: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Try it now").font(.title2).fontWeight(.bold)

                Text("Hold the shortcut, say a sentence, release. Your transcription will appear right here in this window — not in another app.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                shortcutHintRow

                tryItOutputBox

                Spacer()

                HStack {
                    Button("Skip") { finish() }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(capturedText.isEmpty ? "Waiting for your voice…" : "You're all set") {
                        finish()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(capturedText.isEmpty)
                }
            }

            if confettiActive {
                ConfettiView()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear { installInterceptHook() }
        .onDisappear { clearInterceptHook() }
    }

    private var shortcutHintRow: some View {
        HStack(spacing: 12) {
            keycap(symbol: "globe", label: "fn")
            Text("+").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            keycap(symbol: "shift", label: "shift")
            Text("Hold and say a sentence")
                .font(.callout).foregroundColor(.secondary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }

    private var tryItOutputBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Your dictation will appear here")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if capturedText.isEmpty {
                    Text("LISTENING")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                }
            }
            ScrollView {
                Text(capturedText.isEmpty
                     ? "Hold Fn+Shift, say something — the transcription will land here, not in another app."
                     : capturedText)
                    .font(.system(size: 14, design: capturedText.isEmpty ? .default : .monospaced))
                    .foregroundColor(capturedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 90, maxHeight: 130)
            .padding(12)
            // Cream-alt-like fill so it reads as a "transcript readout"
            // rather than an editable text field. Dashed border underlines
            // that this isn't a click-and-type input.
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.gray.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            // Disable hit testing so clicks don't even register a focus
            // attempt — fewer false signals to the user that this is
            // editable.
            .allowsHitTesting(false)
        }
    }

    private func installInterceptHook() {
        #if DEBUG
        print("[Sprich][Onboarding] installInterceptHook: setting interceptOutput on pipeline")
        #endif
        pipeline.interceptOutput = { text in
            #if DEBUG
            print("[Sprich][Onboarding] interceptOutput closure fired with \(text.count) chars: \(text.prefix(60))")
            #endif
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async {
                capturedText = trimmed
                withAnimation(.easeOut(duration: 0.2)) { confettiActive = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeOut(duration: 0.5)) { confettiActive = false }
                }
            }
        }
    }

    private func clearInterceptHook() {
        #if DEBUG
        print("[Sprich][Onboarding] clearInterceptHook: zeroing interceptOutput")
        #endif
        pipeline.interceptOutput = nil
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
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.35), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.15), radius: 1, y: 1)
    }

    // MARK: - Finish

    private func finish() {
        UserDefaults.standard.set(true, forKey: "sprich.hasCompletedOnboarding")
        clearInterceptHook()
        NotificationCenter.default.post(name: .sprichOnboardingComplete, object: nil)
    }
}

// MARK: - Confetti

/// Tiny self-contained particle confetti — Canvas + TimelineView, no
/// third-party dependency. Fires for ~2.5s, ~50 particles.
private struct ConfettiView: View {
    private struct Particle: Identifiable {
        let id = UUID()
        let x0: CGFloat       // launch x as a fraction of width
        let dx: CGFloat       // horizontal drift
        let rotationSpeed: Double
        let color: Color
        let size: CGFloat
        let delay: Double
        let lifetime: Double
    }

    @State private var start: Date = .now
    private let particles: [Particle] = (0..<55).map { _ in
        Particle(
            x0: CGFloat.random(in: 0.1...0.9),
            dx: CGFloat.random(in: -0.25...0.25),
            rotationSpeed: Double.random(in: 1.5...4.0),
            color: [Color.pink, .orange, .yellow, .green, .blue, .purple].randomElement()!,
            size: CGFloat.random(in: 5...10),
            delay: Double.random(in: 0...0.4),
            lifetime: Double.random(in: 1.6...2.2)
        )
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSince(start)
                for p in particles {
                    let t = now - p.delay
                    guard t > 0 else { continue }
                    let progress = min(t / p.lifetime, 1.0)
                    let x = p.x0 * size.width + p.dx * size.width * CGFloat(progress)
                    // Easing: drop accelerates with gravity. progress^2 keeps the shape natural.
                    let y = size.height * CGFloat(progress * progress)
                    let rotation = Angle(degrees: p.rotationSpeed * t * 360)
                    let rect = CGRect(x: x - p.size / 2, y: y - p.size / 2, width: p.size, height: p.size * 0.6)
                    ctx.drawLayer { layer in
                        layer.translateBy(x: rect.midX, y: rect.midY)
                        layer.rotate(by: rotation)
                        layer.translateBy(x: -rect.midX, y: -rect.midY)
                        layer.opacity = max(0, 1 - progress)
                        layer.fill(Path(rect), with: .color(p.color))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}
