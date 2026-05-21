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
    /// Local LLM manager — used by the On-Mac AI cleanup subsections
    /// (P1-UX-18) so card 3 can show eligibility + start a download
    /// without leaving the onboarding window.
    @ObservedObject private var llmManager = LLMModelManager.shared
    /// HardwareProbe result for the LLM eligibility badge (P1-UX-18).
    /// Probed once on appear; re-checking is a less common need during
    /// onboarding than in Settings, so we don't surface a Re-check button
    /// here.
    @State private var hardwareTier: HardwareProbe.Tier = HardwareProbe.evaluate()

    @State private var currentStep = 0

    /// Cloud-provider API keys. The STT picker exposes Groq / OpenAI /
    /// Deepgram; the LLM picker adds Claude + Gemini. Some keychain keys
    /// are shared across providers (e.g. `sprich.api.groq` for both Groq
    /// STT and Groq LLM, `sprich.api.openai` for both OpenAI STT and
    /// OpenAI LLM) — `cloudProviderPanel` dedupes the input fields when
    /// the selected pair share a keychain key.
    @State private var groqKey = ""
    @State private var openAIKey = ""
    @State private var deepgramKey = ""
    @State private var anthropicKey = ""
    @State private var googleKey = ""
    @State private var accessibilityGranted = Permissions.isAccessibilityGranted()
    @State private var microphoneGranted = Permissions.isMicrophoneGranted()
    /// STT provider chosen on card 3. `.local` defaults so the
    /// privacy-first card lights up before the user does anything.
    @State private var providerChoice: STTProviderType = .local
    /// LLM provider chosen on card 3. `.local` per the v1.0.6 local-first
    /// stance — the picker pre-selects "On this Mac" so the Phase 1 wedge
    /// is the visible recommended path. `.onAppear` still reads
    /// `appState.settings.llmProvider` afterwards, so a returning user
    /// with a different saved choice keeps it. Committed to
    /// `appState.settings.llmProvider` when the user advances past
    /// the provider card.
    @State private var llmProviderChoice: LLMProviderType = .local

    /// Controls the "Customize speech & AI cleanup separately" disclosure
    /// on card 2. Collapsed by default so the unified Local/Cloud picker
    /// is the only thing competing for attention; auto-opened in
    /// `.onAppear` if a returning user already has a mixed STT/LLM
    /// combination saved.
    @State private var showCustomize: Bool = false

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
            llmProviderChoice = appState.settings.llmProvider
        }
        .onDisappear {
            // Catches the red-⊗ dismissal while on step 3 — neither the
            // inner step's onDisappear nor the currentStep onChange fires
            // in that path, leaving the intercept closure orphaned on the
            // singleton PipelineCoordinator and swallowing all subsequent
            // transcriptions.
            clearInterceptHook()
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

            Text("Turn your voice into clean text in any app.")
                .foregroundColor(.secondary)

            if auth.isSignedIn {
                signedInSummary
            } else {
                SignInPanel(showsHeader: false)
                // Sprint 2E L2.1 — sign-in is mandatory to advance past
                // welcome. Without it the user has no trial → "Try it
                // now" silently fails (audit P0 #1). Reassurance trimmed
                // to a single visible line; the EU-auth / no-marketing
                // detail moved to the `.help(...)` tooltip so it's
                // available on hover without bulking up the card.
                Text("Required for your 7-day free trial.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("EU-hosted auth via Supabase. No marketing emails.")
            }

            Spacer(minLength: 0)

            // Only render a nav row when signed in. The signed-out path
            // intentionally has no Continue / Skip — the SignInPanel is
            // the only way forward, and `.onChange(of: auth.isSignedIn)`
            // auto-advances to step 1 once sign-in lands.
            if auth.isSignedIn {
                HStack {
                    Spacer()
                    Button("Continue") { currentStep = 1 }
                        .buttonStyle(.borderedProminent)
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

            // Description trimmed to one short sentence; the privacy
            // reassurance ("audio never written to disk") moved to the
            // hover tooltip so it's discoverable without crowding the
            // card.
            Text("Sprich needs two macOS permissions.")
                .font(.callout)
                .foregroundColor(.secondary)
                .help("Audio is sent to your chosen provider only — never written to disk.")

            permissionRow(
                title: "Accessibility",
                explanation: "Required for your global shortcut and to paste into apps.",
                granted: accessibilityGranted,
                cta: "Open Accessibility Settings",
                action: { Permissions.promptAccessibility() }
            )

            permissionRow(
                title: "Microphone",
                explanation: "Records only while you hold the shortcut.",
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

    // MARK: - Step 2 — Provider (Speech recognition + AI cleanup)

    /// Sprint 3 redesign (Option B from 2026-05-20 UX session):
    /// the v1.0.6 layout stacked two `ProviderCardPair` selectors plus
    /// four conditional panels (Whisper preparing strip, hardware
    /// eligibility, storage breakdown, download CTA) and a Groq key
    /// field in a 500×600 window — way too much for one screen.
    ///
    /// New shape:
    ///   1. One big unified Local-vs-Cloud picker that flips both
    ///      providers in lockstep (the choice 95% of users actually
    ///      want to make).
    ///   2. A collapsed "Customize speech & AI cleanup separately"
    ///      disclosure that reveals the original two-`ProviderCardPair`
    ///      UI for mix-and-match users. Auto-opens if a returning user
    ///      already has a mixed combination saved.
    ///   3. ONE consolidated detail panel below — `localModelsPanel`
    ///      when either provider is local (hardware probe + per-model
    ///      status rows + download CTA), `groqKeyField` when either is
    ///      cloud, `steerToCloudCopy` when local LLM was picked on
    ///      unsupported hardware.
    ///
    /// Underlying state (`providerChoice` + `llmProviderChoice`) is
    /// unchanged so `commitProviderChoice` and the Settings → AI Models
    /// page keep working without edits.
    private var providerPreparingStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick where Sprich runs")
                    .font(.title2).fontWeight(.semibold)

                Text("Stay on your Mac, or use a cloud provider.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("You can change either of these later in Settings → AI Models.")

                unifiedProviderPicker

                customizeDisclosure

                if providerChoice == .local || llmProviderChoice.isLocal {
                    localModelsPanel
                }

                if llmProviderChoice.isLocal && !hardwareTier.supportsLocalLLM {
                    steerToCloudCopy
                }

                if !providerChoice.isLocal || !llmProviderChoice.isLocal {
                    cloudProviderPanel
                }

                Spacer(minLength: 0)

                navRow(
                    primaryLabel: providerPrimaryLabel,
                    primaryDisabled: providerPrimaryDisabled
                ) {
                    commitProviderChoice()
                    currentStep = 3
                }
            }
            .padding(.vertical, 2)
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
            // Refresh local LLM state so the inline subsections reflect
            // on-disk truth (e.g. user downloaded earlier — the badge
            // should already say "Ready").
            llmManager.refreshState(for: LocalLLMModelSpec.defaultSpec)
            // Auto-open the customize disclosure if a returning user has
            // a mix-and-match combination saved, so they see their
            // current state instead of a unified picker that doesn't
            // match either tile.
            if !isUnifiedSelection {
                showCustomize = true
            }
            // Pre-fill any keys we already have in keychain so a
            // returning user sees their saved values and `Continue`
            // doesn't gate them on re-entering what they already
            // provided. Mirrors the Settings → AI Models `loadKeys()`
            // flow so the two surfaces stay in sync.
            groqKey      = KeychainManager.retrieve(key: "sprich.api.groq")      ?? groqKey
            openAIKey    = KeychainManager.retrieve(key: "sprich.api.openai")    ?? openAIKey
            deepgramKey  = KeychainManager.retrieve(key: "sprich.api.deepgram")  ?? deepgramKey
            anthropicKey = KeychainManager.retrieve(key: "sprich.api.anthropic") ?? anthropicKey
            googleKey    = KeychainManager.retrieve(key: "sprich.api.google")    ?? googleKey
        }
    }

    /// True when STT and LLM are both local or both cloud — i.e. one of
    /// the two big unified-picker tiles can light up. Drives both the
    /// tile selection state and whether the customize disclosure auto-
    /// opens on appear.
    private var isUnifiedSelection: Bool {
        bothLocalSelected || bothCloudSelected
    }

    private var bothLocalSelected: Bool {
        providerChoice == .local && llmProviderChoice == .local
    }

    /// Cloud tile is selected for ANY non-local combo (Groq+Groq,
    /// Deepgram+Claude, OpenAI+Gemini, etc.) — not just Groq+Groq. This
    /// keeps the tile visually selected when the user picks a non-default
    /// provider pair via the cloud dropdowns.
    private var bothCloudSelected: Bool {
        !providerChoice.isLocal && !llmProviderChoice.isLocal
    }

    /// The new big-picker — a single decision that flips both providers
    /// in lockstep. Visually selected when both providers match; both
    /// tiles read as unselected when the user has gone into customize
    /// and split them, with the "Custom" badge in the disclosure header
    /// signalling that state.
    @ViewBuilder
    private var unifiedProviderPicker: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderCard(
                icon: "laptopcomputer",
                title: "On this Mac",
                subtitle: "Private · Free · No API key",
                description: "Runs locally. ~2.3 GB download.",
                isSelected: bothLocalSelected,
                action: {
                    providerChoice = .local
                    llmProviderChoice = .local
                }
            )
            ProviderCard(
                icon: "cloud",
                title: "Cloud",
                subtitle: "Fastest · Bring your API key",
                description: "One key for speech + AI cleanup.",
                isSelected: bothCloudSelected,
                action: {
                    // Only flip the LOCAL halves to Groq — preserve any
                    // existing cloud choice (e.g. user already picked
                    // Deepgram for STT, then clicked the unified tile).
                    if providerChoice.isLocal { providerChoice = .groq }
                    if llmProviderChoice.isLocal { llmProviderChoice = .groq }
                }
            )
        }
    }

    /// Collapsed "Customize speech & AI cleanup separately" section.
    /// Opens to reveal the two original `ProviderCardPair`s so power
    /// users can pick e.g. local Whisper + cloud LLM. The Custom badge
    /// surfaces when state diverges from a unified pick — important
    /// because both unified tiles read as unselected in that case, and
    /// the disclosure header is the only thing telling the user where
    /// their actual selection lives.
    @ViewBuilder
    private var customizeDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showCustomize.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showCustomize ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 10)
                    Text("Customize speech & AI cleanup separately")
                        .font(.caption)
                    if !isUnifiedSelection {
                        Text("Custom")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundColor(.accentColor)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            if showCustomize {
                speechRecognitionPair
                aiCleanupPair
            }
        }
    }

    @ViewBuilder
    private var speechRecognitionPair: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speech recognition")
                .font(.system(size: 13, weight: .semibold))
            ProviderCardPair(
                isLocalSelected: providerChoice.isLocal,
                cloudTitle: "Cloud",
                cloudIcon: "cloud",
                cloudSubtitle: "API Key required / Fastest response time",
                cloudDescription: "Audio sent to chosen provider for transcription.",
                localTitle: "On this Mac",
                localIcon: "laptopcomputer",
                localSubtitle: "Private / No API Key",
                localDescription: "Runs fully on-device. Slightly slower.",
                onSelectCloud: { providerChoice = .groq },
                onSelectLocal: { providerChoice = .local }
            )
        }
    }

    @ViewBuilder
    private var aiCleanupPair: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI cleanup (Formal + Custom modes)")
                .font(.system(size: 13, weight: .semibold))
            ProviderCardPair(
                isLocalSelected: llmProviderChoice.isLocal,
                cloudTitle: "Cloud",
                cloudIcon: "cloud",
                cloudSubtitle: "API Key required / Fastest response time",
                cloudDescription: "Transcribed text is sent to chosen provider for cleanup. No storage required.",
                localTitle: "On this Mac",
                localIcon: "laptopcomputer",
                localSubtitle: "Private / No API Key",
                localDescription: "Requires Gemma model download. ~0.8 GB storage on your device + hardware requirements.",
                onSelectCloud: { llmProviderChoice = .groq },
                onSelectLocal: { llmProviderChoice = .local }
            )
        }
    }

    /// Consolidated "Local models" panel — replaces the v1.0.6 stack of
    /// preparingStrip + hardwareEligibilityRow + storageBreakdown +
    /// downloadOrDeferRow. Renders only the rows that are actually
    /// required by the user's current STT/LLM choice:
    ///   - Hardware one-liner only when LLM is local (Whisper has no
    ///     eligibility gate).
    ///   - Per-model status row only when that specific model is needed.
    ///   - Download CTA only when LLM is local AND hardware supports it
    ///     (otherwise `steerToCloudCopy` handles the dead-end).
    /// The single panel is visually one block instead of four, which is
    /// the main density win in the redesign.
    @ViewBuilder
    private var localModelsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if llmProviderChoice.isLocal {
                hardwareOneLiner
            }

            VStack(spacing: 8) {
                if providerChoice == .local {
                    modelStatusRow(
                        label: "Whisper (speech-to-text)",
                        size: "~1.5 GB",
                        statusView: AnyView(whisperStatusBadge)
                    )
                }
                if llmProviderChoice.isLocal && hardwareTier.supportsLocalLLM {
                    modelStatusRow(
                        label: "Gemma 3 1B (AI cleanup)",
                        size: "~0.8 GB",
                        statusView: AnyView(gemmaStatusBadge)
                    )
                }
            }

            if llmProviderChoice.isLocal && hardwareTier.supportsLocalLLM {
                HStack {
                    downloadActionButton
                    Spacer()
                }
                .padding(.top, 2)
            }

            Text("Literal mode works without the AI cleanup model.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("Models live in ~/Library/Application Support/Sprich/ and never leave your Mac. You can download AI cleanup later from Settings → AI Models.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    /// Compact one-line hardware verdict — replaces the v1.0.6
    /// hardwareEligibilityRow box. Same `HardwareProbe` data, just laid
    /// out as a single line so it doesn't dominate the panel.
    @ViewBuilder
    private var hardwareOneLiner: some View {
        HStack(spacing: 8) {
            Text(hardwareTierGlyph).font(.system(size: 14))
            Text("Your Mac: \(hardwareTier.displayLabel)")
                .font(.system(size: 12, weight: .semibold))
            Text("·").foregroundColor(.secondary)
            Text(hardwareTier.latencyExpectationCopy)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var hardwareTierGlyph: String {
        switch hardwareTier {
        case .recommended:  return "🟢"
        case .eligible:     return "🟡"
        case .notSupported: return "🔴"
        }
    }

    /// One row in `localModelsPanel`. Inline status badge sits on the
    /// right edge so the user reads "what's needed" → "how big" →
    /// "where it stands" left-to-right.
    private func modelStatusRow(label: String, size: String, statusView: AnyView) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Text(size)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            statusView
        }
    }

    /// Whisper status, condensed into the per-row badge in
    /// `localModelsPanel`. Mirrors the v1.0.6 `preparingStrip` states but
    /// stripped to a trailing badge rather than a full-width strip.
    @ViewBuilder
    private var whisperStatusBadge: some View {
        switch whisperManager.state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 70)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().foregroundColor(.secondary)
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Optimizing…").font(.caption).foregroundColor(.secondary)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundColor(.orange)
                .lineLimit(1)
        default:
            Text("Preparing…").font(.caption).foregroundColor(.secondary)
        }
    }

    /// Gemma (local LLM) status badge — mirrors `whisperStatusBadge` for
    /// visual symmetry inside `localModelsPanel`.
    @ViewBuilder
    private var gemmaStatusBadge: some View {
        switch llmManager.state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 70)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().foregroundColor(.secondary)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying…").font(.caption).foregroundColor(.secondary)
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").font(.caption).foregroundColor(.secondary)
            }
        case .failed(let err):
            Label(err.errorDescription ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundColor(.orange)
                .lineLimit(1)
        default:
            Text("Not downloaded").font(.caption).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var downloadActionButton: some View {
        switch llmManager.state {
        case .ready:
            Label("AI model ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .downloading, .verifying, .preparing:
            Button("Cancel download") { llmManager.cancelDownload() }
                .controlSize(.small)
        default:
            Button("Download AI model now (~0.8 GB)") {
                Task { @MainActor in
                    try? await llmManager.ensureReady(spec: LocalLLMModelSpec.defaultSpec)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    /// Hardware tier `.notSupported` — steer to cloud LLM rather than
    /// dead-ending the user with a "your Mac can't do this" message.
    /// The inline action flips ONLY the LLM to cloud, keeping STT on the
    /// user's Mac. The v1.0.6 copy ("Pick Cloud above") pointed at the
    /// two-picker UI, but with the unified picker that would flip both
    /// providers and lose the local-STT intent — so we expose a direct
    /// button instead and auto-open the customize disclosure so the user
    /// can see the resulting mixed state.
    @ViewBuilder
    private var steerToCloudCopy: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac isn't a match for on-device AI cleanup.")
                    .font(.system(size: 12, weight: .semibold))
                    .help("Speech-to-text still runs on your Mac. Only AI cleanup needs a cloud provider with your own API key.")
                Button("Use cloud for AI cleanup") {
                    llmProviderChoice = .groq
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showCustomize = true
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
    }

    /// Cloud provider sub-picker + API key input(s). Replaces the
    /// Groq-only key field from v1.0.6, which silently committed every
    /// "Cloud" user to Groq with no UI hint that OpenAI / Deepgram /
    /// Claude / Gemini were also options. The panel now:
    ///   • surfaces a Picker for the STT cloud provider (when STT is
    ///     cloud) and a Picker for the LLM cloud provider (when LLM is
    ///     cloud) — both omit `.local`,
    ///   • renders ONE SecureField per *unique* keychainKey actually
    ///     needed by the current selection (Groq STT + Groq LLM share
    ///     `sprich.api.groq` → one field; same for OpenAI STT + OpenAI
    ///     LLM via `sprich.api.openai`),
    ///   • shows a per-provider "Get a key at …" link pointing at the
    ///     API-keys page (not the billing dashboard) so the user can
    ///     get unblocked in one click.
    /// Helper line up top names the trade-off ("Groq covers both with
    /// one key") so the user knows why Groq is pre-selected.
    @ViewBuilder
    private var cloudProviderPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a provider and paste its API key.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("More providers (Deepgram, Claude, Gemini) available later in Settings → AI Models.")

            // When both halves are cloud (the common case), one combined
            // picker is enough — both STT and LLM flip in lockstep to
            // the chosen provider. When the user is mixed (e.g. local
            // STT + cloud LLM via customize), there's nothing to pick
            // between, so we render no picker at all and let the key
            // field below speak for the single cloud half.
            if bothCloudSelected {
                cloudProviderPicker
            }

            ForEach(requiredKeychainKeys, id: \.self) { keychainKey in
                cloudKeyField(for: keychainKey)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    /// STT cloud-provider options exposed in onboarding. Restricted to
    /// Groq + OpenAI — both share their keychain key with their LLM
    /// counterpart, so picking either keeps the panel to a single key
    /// field. Deepgram is still available post-onboarding in Settings →
    /// AI Models. Returning users who already saved Deepgram are
    /// preserved by `sttCloudOptions` rather than silently downgraded.
    private static let onboardingCloudSTTOptions: [STTProviderType] = [.groq, .openai]

    /// Effective picker contents — base set plus the user's current
    /// saved choice if it's a non-default cloud provider (e.g. a
    /// returning user who configured Deepgram in Settings). Without
    /// this preservation, SwiftUI's Picker would render blank for a
    /// saved selection that's missing from the menu.
    private var sttCloudOptions: [STTProviderType] {
        var options = Self.onboardingCloudSTTOptions
        if !providerChoice.isLocal && !options.contains(providerChoice) {
            options.append(providerChoice)
        }
        return options
    }

    /// Combined STT+LLM provider picker. Replaces the two separate
    /// dropdowns from the earlier design — Groq and OpenAI both share
    /// their keychain key across STT + LLM, so a single decision covers
    /// both roles. The custom Binding reads from `providerChoice` (the
    /// STT side wins ties when state is split) and writes to BOTH
    /// `providerChoice` and `llmProviderChoice` so a flip unifies any
    /// split-cloud state from a returning user. Mix-and-match cloud
    /// (e.g. Groq STT + OpenAI LLM) remains achievable from Settings →
    /// AI Models — it's an advanced shape, not an onboarding one.
    @ViewBuilder
    private var cloudProviderPicker: some View {
        HStack(spacing: 10) {
            Text("Cloud provider")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 140, alignment: .leading)
            Picker("", selection: unifiedCloudProviderBinding) {
                ForEach(sttCloudOptions, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            Spacer()
        }
    }

    /// Binding for `cloudProviderPicker` — reads `providerChoice` and on
    /// write mirrors the STT choice into the corresponding LLM choice.
    /// Only Groq and OpenAI need the mirror; Deepgram falls through to
    /// leaving the LLM half untouched (Deepgram is STT-only and only
    /// reaches this picker for a saved returning user, who already has
    /// some LLM choice we shouldn't clobber).
    private var unifiedCloudProviderBinding: Binding<STTProviderType> {
        Binding(
            get: {
                // STT wins for the displayed value when state is split.
                if !providerChoice.isLocal { return providerChoice }
                // Fall back to inferring from the LLM side so the picker
                // still shows something sensible if STT happens to be
                // local while we're rendering (shouldn't happen given
                // bothCloudSelected gate, but defensive is cheap here).
                return llmProviderChoice == .openai ? .openai : .groq
            },
            set: { newValue in
                providerChoice = newValue
                switch newValue {
                case .groq:   llmProviderChoice = .groq
                case .openai: llmProviderChoice = .openai
                default:
                    // Saved non-default (e.g. Deepgram). Don't touch the
                    // LLM half — Deepgram has no LLM counterpart and
                    // the user's existing LLM choice is the better
                    // default than a forced flip.
                    break
                }
            }
        )
    }

    /// Ordered, deduplicated list of keychain keys the current cloud
    /// selection requires. Order is STT-first then LLM-second so the
    /// field for the user's earliest-encountered choice renders at the
    /// top; the dedupe handles Groq+Groq and OpenAI+OpenAI sharing one
    /// physical key.
    private var requiredKeychainKeys: [String] {
        var keys: [String] = []
        if !providerChoice.isLocal {
            keys.append(providerChoice.keychainKey)
        }
        if !llmProviderChoice.isLocal {
            let k = llmProviderChoice.keychainKey
            if !keys.contains(k) { keys.append(k) }
        }
        return keys
    }

    /// One SecureField row inside `cloudProviderPanel`, keyed by the
    /// underlying keychain key (so shared keys collapse to a single row).
    @ViewBuilder
    private func cloudKeyField(for keychainKey: String) -> some View {
        let spec = cloudKeySpec(for: keychainKey)
        VStack(alignment: .leading, spacing: 4) {
            Text(spec.label)
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField(spec.placeholder, text: binding(for: keychainKey))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundColor(.accentColor)
                Link(spec.linkLabel, destination: spec.apiKeysURL)
                    .font(.caption)
            }
        }
    }

    /// Binding into the per-keychain `@State` strings. Centralising the
    /// switch keeps `cloudKeyField` free of pre-existing-key knowledge.
    private func binding(for keychainKey: String) -> Binding<String> {
        switch keychainKey {
        case "sprich.api.groq":      return $groqKey
        case "sprich.api.openai":    return $openAIKey
        case "sprich.api.deepgram":  return $deepgramKey
        case "sprich.api.anthropic": return $anthropicKey
        case "sprich.api.google":    return $googleKey
        default:                     return $groqKey
        }
    }

    /// Display metadata for one cloud-provider key field — label,
    /// placeholder, "where to get a key" URL + caption. Keyed by the
    /// stable keychain string so STT + LLM rows that share a provider
    /// (e.g. Groq) trivially share metadata too.
    private struct CloudKeySpec {
        let label: String
        let placeholder: String
        let apiKeysURL: URL
        let linkLabel: String
    }

    private func cloudKeySpec(for keychainKey: String) -> CloudKeySpec {
        // No "(used for both)" suffix anymore — the single combined
        // cloud picker upstream already communicates that one provider
        // handles both roles. Suffix was load-bearing back when STT and
        // LLM had separate dropdowns; redundant now.
        switch keychainKey {
        case "sprich.api.groq":
            return CloudKeySpec(
                label: "Groq API key",
                placeholder: "gsk_…",
                apiKeysURL: URL(string: "https://console.groq.com/keys")!,
                linkLabel: "Get a free Groq key at console.groq.com"
            )
        case "sprich.api.openai":
            return CloudKeySpec(
                label: "OpenAI API key",
                placeholder: "sk-…",
                apiKeysURL: URL(string: "https://platform.openai.com/api-keys")!,
                linkLabel: "Get an OpenAI key at platform.openai.com"
            )
        case "sprich.api.deepgram":
            return CloudKeySpec(
                label: "Deepgram API key",
                placeholder: "Deepgram key…",
                apiKeysURL: URL(string: "https://console.deepgram.com/api-keys")!,
                linkLabel: "Get a Deepgram key at console.deepgram.com"
            )
        case "sprich.api.anthropic":
            return CloudKeySpec(
                label: "Anthropic API key",
                placeholder: "sk-ant-…",
                apiKeysURL: URL(string: "https://console.anthropic.com/settings/keys")!,
                linkLabel: "Get an Anthropic key at console.anthropic.com"
            )
        case "sprich.api.google":
            return CloudKeySpec(
                label: "Google AI API key",
                placeholder: "AI…",
                apiKeysURL: URL(string: "https://aistudio.google.com/apikey")!,
                linkLabel: "Get a Google AI key at aistudio.google.com"
            )
        default:
            return CloudKeySpec(
                label: "API key",
                placeholder: "",
                apiKeysURL: URL(string: "https://console.groq.com/keys")!,
                linkLabel: "Get a key"
            )
        }
    }

    /// Trimmed value of the @State string backing a given keychain key —
    /// used by both the gate and the commit path. Centralising it keeps
    /// the empty-check logic in one place.
    private func enteredKey(for keychainKey: String) -> String {
        let raw: String
        switch keychainKey {
        case "sprich.api.groq":      raw = groqKey
        case "sprich.api.openai":    raw = openAIKey
        case "sprich.api.deepgram":  raw = deepgramKey
        case "sprich.api.anthropic": raw = anthropicKey
        case "sprich.api.google":    raw = googleKey
        default:                     raw = ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if every cloud provider in the current selection has either
    /// a key already in keychain (returning user) or a freshly-entered
    /// value in the corresponding @State field.
    private var allCloudKeysProvided: Bool {
        for keychainKey in requiredKeychainKeys {
            let fresh = !enteredKey(for: keychainKey).isEmpty
            let stored = (KeychainManager.retrieve(key: keychainKey)?.isEmpty == false)
            if !(fresh || stored) { return false }
        }
        return true
    }

    private var providerPrimaryLabel: String {
        // Local STT gate stays the same shape: until Whisper is ready,
        // the button reflects the warming state. This applies even when
        // the LLM half is cloud — the user still can't transcribe yet.
        if providerChoice.isLocal {
            if whisperManager.isPipeReady {
                // Whisper is ready. If the LLM half needs a cloud key,
                // we still want the user to fill it before advancing,
                // but `providerPrimaryDisabled` enforces that — here we
                // just give the button a sensible label.
                return llmProviderChoice.isLocal
                    ? "Continue — Sprich is ready"
                    : (allCloudKeysProvided ? "Save Key & Continue" : "Continue")
            }
            switch whisperManager.state {
            case .downloading(let p):
                return "Whisper is finishing setup… \(Int(p * 100))%"
            case .preparing:
                return "Whisper is finishing setup…"
            case .failed:
                return "Whisper setup failed — see below"
            default:
                return "Whisper is finishing setup…"
            }
        }
        // STT is cloud (any provider). The label hints that we'll save
        // the key(s) into keychain on advance, but only once at least
        // one key has been freshly entered — otherwise plain "Continue".
        let anyFresh = requiredKeychainKeys.contains { !enteredKey(for: $0).isEmpty }
        return anyFresh ? "Save Key & Continue" : "Continue"
    }

    private var providerPrimaryDisabled: Bool {
        if providerChoice.isLocal {
            // Sprint 2E L2.2 — Block advancing until Whisper is fully
            // ready, otherwise Try-it-now silently no-ops.
            if !whisperManager.isPipeReady { return true }
        }
        // For every cloud half of the selection, require a key.
        return !allCloudKeysProvided
    }

    /// Persist the user's card-3 picks when they advance to card 4.
    /// Sprint 3 P1-UX-19 — both providers commit here. The On-Mac LLM
    /// branch is honored regardless of whether the user clicked
    /// "Download now" inside the local-LLM subsection: the provider
    /// flips to `.local` and the first Formal/Custom dictation re-prompts
    /// to download (Sprint 2F Decision 8 Option C, wired in
    /// PipelineCoordinator's local-LLM-not-ready path).
    ///
    /// Note: `AppSettings.defaults.llmProvider` stays `.groq` — the
    /// factory default is the safety net for users who skip onboarding
    /// entirely (closing the window before reaching card 3) and for
    /// fresh-install hardware-not-supported users. Flipping the static
    /// default to `.local` would break both paths.
    private func commitProviderChoice() {
        // STT provider + Whisper warmup.
        appState.settings.sttProvider = providerChoice

        // LLM provider — flip to `.local` when the user picked On-Mac
        // for AI cleanup, regardless of whether they triggered the
        // download inside card 3 ("Wait" and "Later" both end up here
        // with .local persisted and the model bytes still absent;
        // dictation-time re-prompt picks it up).
        appState.settings.llmProvider = llmProviderChoice

        appState.saveSettings()

        if providerChoice.isLocal {
            let model = appState.settings.localWhisperModel
            Task { @MainActor in
                try? await WhisperModelManager.shared.ensureReady(model: model)
            }
        }

        // Persist every freshly-entered cloud key, regardless of which
        // halves are cloud — the v1.0.6 path only wrote groqKey, which
        // silently dropped OpenAI/Deepgram/Claude/Gemini onboarding
        // entries. We walk the @State strings (not requiredKeychainKeys)
        // because the user may have entered a key for a provider they
        // then deselected — saving it costs nothing and helps if they
        // come back to that provider in Settings later.
        let entries: [(String, String)] = [
            ("sprich.api.groq",      groqKey),
            ("sprich.api.openai",    openAIKey),
            ("sprich.api.deepgram",  deepgramKey),
            ("sprich.api.anthropic", anthropicKey),
            ("sprich.api.google",    googleKey),
        ]
        for (keychainKey, raw) in entries {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                KeychainManager.store(key: keychainKey, value: trimmed)
            }
        }
    }

    // MARK: - Step 3 — Try it now

    private var tryItNowStep: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Try it now").font(.title2).fontWeight(.bold)

                Text("Hold the shortcut, say a sentence, release.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .help("Your transcription will appear in this window — not in another app.")

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
                     ? "Hold Fn+Shift and say something."
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
