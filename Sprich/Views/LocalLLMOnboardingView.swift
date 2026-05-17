import SwiftUI

/// First-run onboarding for the on-device LLM (Sprint 2F Decision 8, Option C).
///
/// Three screens, all reachable as a sheet from either the main onboarding
/// flow OR from Settings → Local LLM:
///   1. **Eligibility + storage disclosure** — HardwareProbe tier badge,
///      itemised model sizes (WhisperKit ~1.5 GB + Gemma ~0.8 GB = ~2.3 GB
///      total per prereqs § C6).
///   2. **Download timing choice** — Now / Wait until Wi-Fi / Later from
///      Settings. Option C is "optional with re-prompt": picking "Later"
///      is honored, the app proceeds to Default mode, and first Formal/Custom
///      use re-prompts.
///   3. **Active download + outcome** — progress, verifying, ready, failure
///      modes per spec.
///
/// Non-negotiable UX constraints from `local-llm-scoping-session-agenda.md`
/// Decision 8 (constant across all three onboarding options):
///   - Disclose total install footprint before any download starts.
///   - Default mode is usable while LLM is missing — the "Later" exit path
///     respects that.
///   - Per-model progress, pause/cancel/resume, cross-session resume.
///   - Failure UX is explicit per `LLMModelManagerError`.
struct LocalLLMOnboardingView: View {

    /// Called when the user finishes (ready) OR explicitly chooses "Later".
    /// The host re-prompts on first Formal/Custom use either way.
    let onClose: () -> Void

    @ObservedObject private var manager = LLMModelManager.shared
    @State private var step: Step = .eligibility
    @State private var tier: HardwareProbe.Tier = .recommended
    @State private var declinedReason: DeclinedReason?

    private enum Step { case eligibility, timing, downloading }

    private enum DeclinedReason {
        case waitForWiFi
        case later

        var copy: String {
            switch self {
            case .waitForWiFi: return "We'll wait until your Mac is on Wi-Fi. You can also start the download manually from Settings → Providers → Local LLM."
            case .later:       return "You can start the download anytime from Settings → Providers → Local LLM. Default mode keeps working without it."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Group {
                switch step {
                case .eligibility:   eligibilityScreen
                case .timing:        timingScreen
                case .downloading:   downloadingScreen
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 520, height: 520)
        .onAppear {
            tier = HardwareProbe.evaluate()
            manager.refreshState(for: LocalLLMModelSpec.defaultSpec)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Set up offline AI cleanup")
                .font(.headline)
            Spacer()
            Text(stepBreadcrumb)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var stepBreadcrumb: String {
        switch step {
        case .eligibility:   return "Step 1 of 3"
        case .timing:        return "Step 2 of 3"
        case .downloading:   return "Step 3 of 3"
        }
    }

    // MARK: - Screen 1: Eligibility + storage disclosure

    @ViewBuilder
    private var eligibilityScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Mac")
                .font(.subheadline).fontWeight(.semibold)

            HStack(alignment: .top, spacing: 10) {
                Text(tier == .recommended ? "🟢" : (tier.supportsLocalLLM ? "🟡" : "🔴"))
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.displayLabel)
                        .font(.system(size: 14, weight: .semibold))
                    Text(tier.latencyExpectationCopy)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

            if tier.supportsLocalLLM {
                Text("Storage required")
                    .font(.subheadline).fontWeight(.semibold)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    storageRow(label: "Whisper (speech-to-text)", size: "~1.5 GB")
                    storageRow(label: "Gemma 3 1B (AI cleanup)", size: "~0.8 GB")
                    Divider().padding(.vertical, 2)
                    storageRow(label: "Total", size: "~2.3 GB", bold: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))

                Text("Both models live in `~/Library/Application Support/Sprich/`. They never leave your Mac.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                // 🔴 — Intel / <8 GB / <macOS 13. Steer them to cloud LLM
                // without making it feel like a downgrade.
                Text("Cloud LLM is an option")
                    .font(.subheadline).fontWeight(.semibold)
                    .padding(.top, 6)
                Text("Your Mac can still use Sprich with a cloud LLM provider. Speech-to-text stays local (audio never leaves the device); only the text-cleanup step uses a provider you configure with your own API key.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(tier.supportsLocalLLM ? "Continue" : "OK, use cloud") {
                    if tier.supportsLocalLLM { step = .timing } else { onClose() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func storageRow(label: String, size: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(bold ? .system(size: 13, weight: .semibold) : .system(size: 13))
            Spacer()
            Text(size)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(bold ? .primary : .secondary)
        }
    }

    // MARK: - Screen 2: Download timing choice (Option C)

    @ViewBuilder
    private var timingScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When should we download?")
                .font(.subheadline).fontWeight(.semibold)
            Text("You're in control. Sprich won't download on a metered connection — you choose when.")
                .font(.caption).foregroundColor(.secondary)

            timingChoice(
                title: "Download now",
                subtitle: "~2.3 GB over your current connection. Best if you're on Wi-Fi already.",
                primary: true
            ) {
                Task { try? await manager.ensureReady(spec: LocalLLMModelSpec.defaultSpec) }
                step = .downloading
            }

            timingChoice(
                title: "Wait until I'm on Wi-Fi",
                subtitle: "We'll only start the download when Sprich detects a non-metered Wi-Fi connection."
            ) {
                declinedReason = .waitForWiFi
                onClose()
            }

            timingChoice(
                title: "Later — from Settings",
                subtitle: "Default mode works right now. Open Settings → Providers → Local LLM to download whenever you're ready."
            ) {
                declinedReason = .later
                onClose()
            }

            Spacer()

            HStack {
                Button("Back") { step = .eligibility }
                Spacer()
            }
        }
    }

    private func timingChoice(
        title: String,
        subtitle: String,
        primary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: primary ? "arrow.down.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(primary ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(primary ? 0.10 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Screen 3: Active download + outcome

    @ViewBuilder
    private var downloadingScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Downloading model")
                .font(.subheadline).fontWeight(.semibold)
            Text("This is a one-time download. It runs entirely on your Mac after this.")
                .font(.caption).foregroundColor(.secondary)

            switch manager.state {
            case .unknown, .absent:
                ProgressView().controlSize(.small)
                Text("Starting…").font(.caption).foregroundColor(.secondary)

            case .downloading(let p):
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                Text("\(Int(p * 100))% · \(byteString(Int64(p * Double(LocalLLMModelSpec.defaultSpec.expectedSize)))) of \(byteString(LocalLLMModelSpec.defaultSpec.expectedSize))")
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()

            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying integrity (SHA-256)…").font(.caption)
                }

            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing model…").font(.caption)
                }

            case .ready:
                Label("Ready. Formal and Custom modes now run on-device.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .failed(let err):
                Label("Setup failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err.errorDescription ?? "Unknown error")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                switch manager.state {
                case .downloading, .verifying, .preparing:
                    Button("Cancel") { manager.cancelDownload() }
                case .failed:
                    Button("Retry") {
                        Task { try? await manager.ensureReady(spec: LocalLLMModelSpec.defaultSpec) }
                    }
                    Button("Set up later") { onClose() }
                default:
                    EmptyView()
                }
                Spacer()
                if manager.state.isReady {
                    Button("Done") { onClose() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
