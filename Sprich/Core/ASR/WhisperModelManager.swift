import Foundation
import Combine
import WhisperKit

/// Lifecycle manager for on-device Whisper models.
///
/// Responsibilities:
/// - Resolve where a model lives on disk (Application Support, not Caches —
///   Caches is evictable under disk pressure and would trigger silent
///   re-download of an ~800 MB asset).
/// - Report download + prepare progress to SwiftUI via `@Published state`.
/// - Delete models on user request.
///
/// Does NOT hold the loaded `WhisperKit` pipe — that's `LocalWhisperService`'s
/// job. Keeping lifecycle separate from inference lets the UI show "model
/// downloading…" without blocking on pipe creation, and lets the pipe
/// reload without re-downloading.
@MainActor
final class WhisperModelManager: ObservableObject {

    static let shared = WhisperModelManager()

    enum ModelState: Equatable {
        case unknown
        case absent                          // model dir missing on disk
        case downloading(progress: Double)   // 0.0 ... 1.0
        case preparing                       // downloaded, awaiting first Core ML compile
        case ready(model: String, sizeBytes: Int64)
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true } else { return false }
        }

        var isBusy: Bool {
            switch self {
            case .downloading, .preparing: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: ModelState = .unknown

    /// Absolute URL WhisperKit will download into. A model ends up at
    /// `<baseURL>/argmaxinc/whisperkit-coreml/openai_whisper-<variant>/...`.
    let baseURL: URL

    private var downloadTask: Task<URL, Error>?

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appDir = support
            .appendingPathComponent("Sprich", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.baseURL = appDir
    }

    // MARK: - Public API

    /// Returns the on-disk folder for `model`, downloading it if missing.
    /// Progress is published via `state`.
    @discardableResult
    func ensureReady(model: String) async throws -> URL {
        if let existing = existingFolder(for: model) {
            state = .ready(model: model, sizeBytes: folderSize(existing))
            return existing
        }

        if let task = downloadTask {
            return try await task.value
        }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            self.state = .downloading(progress: 0)
            do {
                let base = self.baseURL
                let folder = try await WhisperKit.download(
                    variant: model,
                    downloadBase: base,
                    progressCallback: { progress in
                        Task { @MainActor [weak self] in
                            self?.state = .downloading(progress: progress.fractionCompleted)
                        }
                    }
                )
                self.state = .preparing
                // `.ready` is signalled once the bytes are on disk. Core ML
                // first-compile happens inside LocalWhisperService when it
                // constructs the WhisperKit pipe; that keeps "download"
                // observable separately from "model loadable".
                let size = self.folderSize(folder)
                self.state = .ready(model: model, sizeBytes: size)
                return folder
            } catch {
                self.state = .failed(error.localizedDescription)
                throw error
            }
        }
        downloadTask = task
        defer { downloadTask = nil }
        return try await task.value
    }

    /// Check disk for a previously downloaded model. Returns nil if absent.
    func existingFolder(for model: String) -> URL? {
        let candidate = baseURL
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(model)", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    func refreshState(for model: String) {
        if existingFolder(for: model) != nil {
            if let f = existingFolder(for: model) {
                state = .ready(model: model, sizeBytes: folderSize(f))
            }
        } else {
            state = .absent
        }
    }

    func deleteModel(_ model: String) throws {
        guard let folder = existingFolder(for: model) else { return }
        try FileManager.default.removeItem(at: folder)
        state = .absent
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .absent
    }

    // MARK: - Helpers

    private func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}
