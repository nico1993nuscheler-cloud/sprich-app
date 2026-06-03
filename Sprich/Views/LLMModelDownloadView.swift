import SwiftUI

/// Sheet presented when the user enables Local (offline) LLM for the
/// first time, or when the expected model is missing.
///
/// Mirrors `ModelDownloadView`'s shape so the two on-device-download UIs
/// feel like one design system. The differences vs the Whisper sheet:
/// - `LLMModelManager`'s state machine has an extra `.verifying` step
///   (SHA-256 check that llama.cpp loaders don't perform themselves —
///   see distribution plan § C3).
/// - Copy emphasises that the SHA-256 check is the integrity belt over the
///   network's suspenders, so a user who sees "Verifying…" understands it
///   isn't another wait-for-no-reason.
/// - Failure UX names the specific failure mode (no network, disk full,
///   SHA mismatch) per the prereqs UX-constraint list § C6.
struct LLMModelDownloadView: View {
    let spec: LocalLLMModelSpec
    let onDone: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var manager = LLMModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download AI cleanup model")
                .font(.headline)

            Text("The model runs entirely on your Mac. Your transcribed text never leaves the device while Local is selected — there is no online fallback.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.displayName)
                        .font(.system(.body, design: .monospaced))
                    Text(subline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            switch manager.state {
            case .unknown, .absent, .failed:
                EmptyView()
            case .downloading(let p):
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                Text("\(Int(p * 100))% downloaded · \(Self.humanByteFormatter.string(fromByteCount: spec.expectedSize)) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying integrity (SHA-256)…")
                        .font(.caption)
                }
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing model (first-time load)…")
                        .font(.caption)
                }
            case .ready:
                Label("Ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if case .failed(let err) = manager.state {
                failureMessage(err)
            }

            Spacer(minLength: 4)

            HStack {
                Button("Keep online provider") {
                    manager.cancelDownload()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if manager.state.isReady {
                    Button("Done") { onDone() }
                        .keyboardShortcut(.defaultAction)
                } else if case .failed = manager.state {
                    Button("Retry") {
                        Task { try? await manager.ensureReady(spec: spec) }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Download") {
                        Task { try? await manager.ensureReady(spec: spec) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(manager.state.isBusy)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 500)
        .task { manager.refreshState(for: spec) }
    }

    /// Explicit-not-silent failure UX (prereqs § C6). Each failure mode
    /// names itself so a user can act without spelunking error codes.
    @ViewBuilder
    private func failureMessage(_ err: LLMModelManagerError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failureHeadline(err), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12, weight: .semibold))
            Text(err.errorDescription ?? "Unknown error")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }

    private func failureHeadline(_ err: LLMModelManagerError) -> String {
        switch err {
        case .unpinnedSpec:        return "Internal error — model not pinned"
        case .invalidURL:          return "Invalid download URL"
        case .httpError(let code):
            return code == 404 ? "Model file not found" : "Download failed (HTTP \(code))"
        case .sha256Mismatch:      return "Integrity check failed — partial file removed"
        case .unknown:             return "Download failed"
        }
    }

    private var subline: String {
        switch manager.state {
        case .ready(_, let size):
            return "\(Self.humanByteFormatter.string(fromByteCount: size)) · stored locally"
        case .downloading:
            return "Downloading from Hugging Face…"
        case .verifying:
            return "Confirming the file matches the pinned SHA-256…"
        case .preparing:
            return "Loading model into memory…"
        case .failed:
            return "Setup failed — see below"
        default:
            return "\(Self.humanByteFormatter.string(fromByteCount: spec.expectedSize)) · one-time download"
        }
    }

    private static let humanByteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
