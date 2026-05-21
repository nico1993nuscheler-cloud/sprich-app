import Foundation

/// Real-time "where does this dictation's data go?" indicator.
///
/// The Phase 1 positioning brief (Part 4) names a user-visible network-egress
/// indicator as a ship-blocker — the "no data leaves your device" claim is
/// only honest if a user can verify it from inside the app, in real time.
/// This type is the source of truth that the recording overlay, the menubar
/// glyph, and the Settings → Privacy panel all subscribe to.
///
/// Design spec: `~/Claude/40_Projects/Sprich/network-off-proof-ui-spec.md`.
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
        /// dictation pipeline.
        case offline

        /// 🟡 — Whisper transcription goes to a cloud provider.
        case cloudSTT(provider: String)

        /// 🟡 — text cleanup goes to a cloud provider. STT stays local.
        case cloudLLM(provider: String)

        /// 🟡 — both legs go to cloud.
        case both(sttProvider: String, llmProvider: String)

        /// Color semantics for view callers. We deliberately do NOT call
        /// cloud `.red` — a user who explicitly chose cloud LLM should not
        /// see "you are doing something bad" theming. Amber is informational.
        var glyph: String {
            switch self {
            case .offline:          return "🟢"
            case .cloudSTT,
                 .cloudLLM,
                 .both:             return "🟡"
            }
        }

        var shortLabel: String {
            switch self {
            case .offline:                       return "Offline"
            case .cloudSTT:                      return "Cloud STT"
            case .cloudLLM:                      return "Cloud LLM"
            case .both:                          return "Cloud STT + LLM"
            }
        }

        /// Tooltip / hover copy. Honest plain-English version of the state.
        var tooltip: String {
            switch self {
            case .offline:
                return "Offline: your audio and text stayed on your Mac during this dictation."
            case .cloudSTT(let p):
                return "Cloud STT (\(p)): Whisper transcription goes to \(p) for this dictation. LLM cleanup is local."
            case .cloudLLM(let p):
                return "Cloud LLM (\(p)): Whisper transcription is local; text cleanup goes to \(p) for this dictation."
            case .both(let s, let l):
                return "Cloud STT (\(s)) + cloud LLM (\(l)): both legs of this dictation use the network."
            }
        }
    }

    @Published private(set) var route: Route = .offline

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
            self?.route = next
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
