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
    /// `<baseURL>/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>/...`.
    /// (The extra `/models/` segment is inserted by `HubApi` inside
    /// swift-transformers; we resolve paths through `existingFolder(for:)`
    /// rather than hard-coding the layout in call sites.)
    let baseURL: URL

    private var downloadTask: Task<URL, Error>?

    /// Cache of resolved on-disk folders per model name. Populated by
    /// `ensureReady` (from the URL `WhisperKit.download` returns) and by
    /// `existingFolder(for:)` when it scans disk. Cleared on delete.
    private var knownFolders: [String: URL] = [:]

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
                // Cache the actual URL HubApi wrote to. This is the ground
                // truth — `existingFolder(for:)`'s path reconstruction used
                // to miss the `models/` prefix that HubApi inserts, which
                // made the status chip flicker back to "Not downloaded" the
                // moment the download sheet closed. Caching side-steps any
                // future HubApi path convention changes too.
                self.knownFolders[model] = folder
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
    ///
    /// Resolution order (stop at first hit):
    /// 1. In-memory cache (set by a successful `ensureReady` or previous
    ///    scan). The URL HubApi actually wrote to — ground truth.
    /// 2. A couple of conventional paths we know HubApi has used. Handles
    ///    both the current layout (`models/argmaxinc/…`) and a legacy one
    ///    without the `models/` prefix, so this keeps working if/when
    ///    WhisperKit tweaks its layout.
    /// 3. Filesystem scan under `baseURL` for a directory whose last
    ///    component equals `openai_whisper-<variant>`. Defensive catch-all.
    func existingFolder(for model: String) -> URL? {
        if let cached = knownFolders[model],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let variantFolder = "openai_whisper-\(model)"
        let conventionalPaths: [URL] = [
            baseURL
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(variantFolder, isDirectory: true),
            baseURL
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(variantFolder, isDirectory: true),
        ]
        for candidate in conventionalPaths
        where FileManager.default.fileExists(atPath: candidate.path) {
            knownFolders[model] = candidate
            return candidate
        }
        return scanBaseURL(for: variantFolder, model: model)
    }

    /// Fallback for when neither the cache nor the conventional paths hit.
    /// Walks the download root looking for a directory matching the
    /// variant folder name. Skips the HubApi-internal `.cache` tree so
    /// we don't accidentally resolve the pre-snapshot download staging
    /// area as the real model.
    private func scanBaseURL(for variantFolder: String, model: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.pathComponents.contains(".cache") {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == variantFolder else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                knownFolders[model] = url
                return url
            }
        }
        return nil
    }

    func refreshState(for model: String) {
        if let folder = existingFolder(for: model) {
            state = .ready(model: model, sizeBytes: folderSize(folder))
        } else {
            state = .absent
        }
    }

    func deleteModel(_ model: String) throws {
        guard let folder = existingFolder(for: model) else { return }
        try FileManager.default.removeItem(at: folder)
        knownFolders.removeValue(forKey: model)
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
