import SwiftUI

/// Sheet presented when the user enables Local (offline) STT for the
/// first time, or when the expected model is missing. Drives the
/// download via `WhisperModelManager.shared` and returns control to the
/// caller once the model is ready.
struct ModelDownloadView: View {
    let model: String
    let onDone: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var manager = WhisperModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Whisper model")
                .font(.headline)

            Text("The model runs entirely on your Mac. No audio leaves the device once it's downloaded.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model)
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
                Text("\(Int(p * 100))% downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Optimizing for your Mac (one-time, ~10–30 s)…")
                        .font(.caption)
                }
            case .ready:
                Label("Ready.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if case .failed(let msg) = manager.state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
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
                        Task { try? await manager.ensureReady(model: model) }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Download") {
                        Task { try? await manager.ensureReady(model: model) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(manager.state.isBusy)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460)
        .task { manager.refreshState(for: model) }
        .onChange(of: manager.state) { _, newValue in
            if case .ready = newValue { /* leave the sheet open; user clicks Done */ }
        }
    }

    private var subline: String {
        switch manager.state {
        case .ready(_, let size):
            return "\(Self.humanByteFormatter.string(fromByteCount: size)) · stored locally"
        case .downloading:
            return "Downloading from Hugging Face…"
        case .preparing:
            return "Optimizing for your Mac (one-time, ~10–30 s)…"
        case .failed:
            return "Download failed"
        default:
            if let option = WhisperModelCatalog.option(for: model) {
                return "~\(option.approxSizeMB) MB one-time download"
            }
            return "One-time download"
        }
    }

    private static let humanByteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}
