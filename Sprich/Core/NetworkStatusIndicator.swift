import Foundation
import Combine

/// Real-time "where does this dictation's data go?" indicator.
///
/// The Phase 1 positioning brief (Part 4) names a user-visible network-egress
/// indicator as a ship-blocker — the "no data leaves your device" claim is
/// only honest if a user can verify it from inside the app, in real time.
/// This type is the source of truth that the recording overlay, the menubar
/// glyph, and the Settings → Privacy panel all subscribe to.
///
/// **Pure derivation — no new outbound calls.** The indicator reads existing
/// state (selected providers + license-check beacon) and reports the truth.
/// If a sharp reader runs Sprich behind Little Snitch and sees an outbound
/// packet while this indicator shows `.offline`, that's a bug in the
/// reporting (or in another subsystem), not in the indicator's signal.
@MainActor
final class NetworkStatusIndicator: ObservableObject {

    static let shared = NetworkStatusIndicator()

    /// Network routing state for the *configured-for-next-dictation* set
    /// of providers. The recording overlay + menubar glyph render this
    /// directly; the dictation-time view doesn't change state mid-dictation
    /// because Sprich blocks Settings changes during recording (existing UX).
    enum Route: Equatable {
        /// 🟢 — both STT and LLM run on-device. No network egress for the
        /// dictation pipeline. (License heartbeat is a separate concern;
        /// see `.licenseHeartbeat`.)
        case offline

        /// 🔵 — Whisper transcription goes to an online provider.
        case cloudSTT(provider: String)

        /// 🔵 — text cleanup goes to an online provider. STT stays local.
        case cloudLLM(provider: String)

        /// 🔵 — both legs go online.
        case both(sttProvider: String, llmProvider: String)

        /// ⚪ — a license validation call is in flight. Transient — returns
        /// to the prior state when the call completes. Separate from the
        /// dictation pipeline so users don't conflate the license heartbeat
        /// with dictation egress.
        case licenseHeartbeat

        /// Color semantics for view callers. We deliberately do NOT call
        /// online `.red` — a user who explicitly chose an online LLM should not
        /// see "you are doing something bad" theming. Blue is informational.
        var glyph: String {
            switch self {
            case .offline:          return "🟢"
            case .cloudSTT,
                 .cloudLLM,
                 .both:             return "🔵"
            case .licenseHeartbeat: return "⚪"
            }
        }

        /// User-facing short label. The `.offline` case reads **"On this Mac"**,
        /// not "Offline": v1.0.6 QA confirmed users parse "Offline" as
        /// "Sprich itself isn't working" rather than "this dictation never
        /// leaves my Mac." The internal enum case stays `.offline` for code
        /// clarity, but every user-visible surface (menubar, Settings →
        /// Privacy, tooltip) speaks the same provider-card language
        /// ("On this Mac") as `STTProviderType.local.displayName`.
        var shortLabel: String {
            switch self {
            case .offline:                       return "On this Mac"
            case .cloudSTT:                      return "Online STT"
            case .cloudLLM:                      return "Online LLM"
            case .both:                          return "Online STT + LLM"
            case .licenseHeartbeat:              return "Network check"
            }
        }

        /// Tooltip / hover copy. Honest plain-English version of the state.
        var tooltip: String {
            switch self {
            case .offline:
                return "On this Mac: your audio and text stayed on your Mac during this dictation. Nothing was sent online."
            case .cloudSTT(let p):
                return "Online STT (\(p)): Whisper transcription goes to \(p) for this dictation. LLM cleanup is local."
            case .cloudLLM(let p):
                return "Online LLM (\(p)): Whisper transcription is local; text cleanup goes to \(p) for this dictation."
            case .both(let s, let l):
                return "Online STT (\(s)) + online LLM (\(l)): both legs of this dictation use the network."
            case .licenseHeartbeat:
                return "Network check: a brief license validation call is in flight. No dictation data is sent."
            }
        }
    }

    @Published private(set) var route: Route = .offline

    /// True while the recording overlay should *show* the indicator.
    /// Set by `PipelineCoordinator` at dictation start/stop. The indicator
    /// itself stays current regardless — this flag just controls visibility
    /// in the overlay surface (the menubar glyph is always visible).
    @Published private(set) var isDictationActive: Bool = false

    private var dictationCancellation: AnyCancellable?
    /// The route we were on before a license heartbeat fired. Restored
    /// when the heartbeat ends so a license tick doesn't bump us from
    /// 🟢 to 🟡 visually.
    private var routeBeforeHeartbeat: Route?

    private init() {}

    // MARK: - Public API

    /// Re-evaluate `route` from the user's current Settings selection.
    /// Call this whenever `AppSettings.sttProvider` or `.llmProvider`
    /// changes — `AppState.saveSettings()` already runs on every mutation
    /// so this can sit on the same code path.
    ///
    /// Deferred to the next runloop tick because `saveSettings` is invoked
    /// from inside SwiftUI view-binding mutations (provider picker, etc.).
    /// Mutating a `@Published` synchronously from inside a view update
    /// triggers the "Publishing changes from within view updates is not
    /// allowed" SwiftUI warning seen in QA 2026-05-17. Same pattern
    /// `WhisperModelManager.markPipeReady` uses at lines 64-68 for the
    /// identical reason.
    func refresh(from settings: AppSettings) {
        let next = Self.derive(from: settings)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Don't clobber an in-flight license heartbeat — restore
            // happens in `endLicenseHeartbeat` instead.
            if case .licenseHeartbeat = self.route {
                self.routeBeforeHeartbeat = next
                return
            }
            self.route = next
        }
    }

    /// Called by `PipelineCoordinator` at dictation start.
    func markDictationStarted() {
        isDictationActive = true
    }

    /// Called by `PipelineCoordinator` at dictation end.
    func markDictationEnded() {
        isDictationActive = false
    }

    /// Called by `TrialState` (or the license-validation code path) when
    /// it kicks off a heartbeat. The indicator briefly flips to `⚪` so
    /// the user understands the packet they may have seen wasn't dictation
    /// data. `endLicenseHeartbeat` restores the baseline.
    func beginLicenseHeartbeat() {
        if case .licenseHeartbeat = route { return }  // already in heartbeat
        routeBeforeHeartbeat = route
        route = .licenseHeartbeat
    }

    func endLicenseHeartbeat() {
        if let prior = routeBeforeHeartbeat {
            route = prior
            routeBeforeHeartbeat = nil
        }
    }

    // MARK: - Derivation

    /// Pure function that maps a settings snapshot to the route the
    /// indicator should display. Unit-testable: every Settings combination
    /// produces a single, predictable Route.
    static func derive(from settings: AppSettings) -> Route {
        let sttLocal = settings.sttProvider.isLocal
        let llmLocal = settings.llmProvider.isLocal
        switch (sttLocal, llmLocal) {
        case (true, true):
            return .offline
        case (false, true):
            return .cloudSTT(provider: settings.sttProvider.displayName)
        case (true, false):
            return .cloudLLM(provider: settings.llmProvider.displayName)
        case (false, false):
            return .both(
                sttProvider: settings.sttProvider.displayName,
                llmProvider: settings.llmProvider.displayName
            )
        }
    }
}
