import Foundation
import Combine
import CryptoKit

/// Lifecycle manager for on-device LLM weight files.
///
/// Responsibilities:
/// - Resolve where a model lives on disk (Application Support, not Caches —
///   Caches is evictable under disk pressure and would trigger silent
///   re-download of an ~0.8 GB GGUF asset).
/// - Download from the pinned Hugging Face revision (model card →
///   `https://huggingface.co/{repo}/resolve/{revision}/{file}`).
/// - **Verify the on-disk file's SHA-256** against the pinned digest in
///   `LocalLLMModelSpec`. This is the addition over `WhisperModelManager`'s
///   state machine — llama.cpp loaders do not verify integrity, so the
///   manager must.
/// - Prewarm the inference pipe (via `prewarmHook`) BEFORE marking `.ready`,
///   so first-Formal-mode dictation is instant rather than a 1–3 s cold-load
///   wait. Lesson copied verbatim from `WhisperModelManager.swift:142–167`.
/// - Report download / verify / prepare progress to SwiftUI via `@Published`.
/// - Delete models on user request.
///
/// Does NOT hold the loaded llama.cpp context — that's `LocalLLMService`'s
/// job (P2-LLM-07). Keeping lifecycle separate from inference lets the UI
/// show "model downloading…" without blocking on context creation, and lets
/// the context reload without re-downloading.
@MainActor
final class LLMModelManager: ObservableObject {

    static let shared = LLMModelManager()

    enum ModelState: Equatable {
        case unknown
        case absent                          // model file missing on disk
        case downloading(progress: Double)   // 0.0 ... 1.0
        case verifying                       // bytes on disk; computing SHA-256
        case preparing                       // verified; llama.cpp context loading (via prewarmHook)
        case ready(model: String, sizeBytes: Int64)
        case failed(LLMModelManagerError)

        var isReady: Bool {
            if case .ready = self { return true } else { return false }
        }

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .preparing: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: ModelState = .unknown

    /// Separate from `state` because "verified bytes on disk" (which
    /// `state == .ready` signals) does NOT imply "llama.cpp context
    /// loaded in memory and ready to infer." Mirrors the lesson in
    /// `WhisperModelManager.isPipeReady` — observers (Settings chip,
    /// menubar, `PipelineCoordinator` guard) use this flag to surface
    /// a friendly "still warming up" message instead of silently
    /// blocking inside `LocalLLMService.cleanup`.
    @Published private(set) var isPipeReady: Bool = false

    /// Called by `LocalLLMService` when a context successfully loads.
    func markPipeReady() {
        DispatchQueue.main.async { [weak self] in
            self?.isPipeReady = true
        }
    }

    /// Called by `LocalLLMService` when it unloads (idle timer fired,
    /// app backgrounded long enough per scoping Decision 6, or user
    /// switched model in Settings).
    func markPipeNotReady() {
        DispatchQueue.main.async { [weak self] in
            self?.isPipeReady = false
        }
    }

    /// Optional prewarm callback wired by `LocalLLMService` at construction
    /// (P2-LLM-07). When set, `ensureReady` invokes it during the
    /// `.preparing` state, so the first Formal-mode dictation is instant.
    /// Until P2-LLM-07 lands this stays nil — the manager simply transitions
    /// from `.verifying → .ready` without paying the prewarm cost up front.
    /// First dictation will then pay a one-time ~1.5 s cold-load.
    var prewarmHook: ((LocalLLMModelSpec, URL) async throws -> Void)?

    /// Absolute URL the manager downloads into.
    /// `<baseURL>/<spec.id>-<sha[0..8]>/<spec.gguf>`. Versioning by SHA
    /// means a future spec update sits alongside the old version without
    /// overwriting it mid-inference (distribution plan § C5).
    let baseURL: URL

    private var downloadTask: Task<URL, Error>?

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appDir = support
            .appendingPathComponent("Sprich", isDirectory: true)
            .appendingPathComponent("LLMModels", isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.baseURL = appDir
    }

    // MARK: - Public API

    /// Returns the on-disk path for `spec`, downloading and verifying if missing.
    /// Progress is published via `state`. Idempotent — overlapping calls dedupe
    /// onto the same in-flight download task.
    @discardableResult
    func ensureReady(spec: LocalLLMModelSpec) async throws -> URL {
        // Refuse to download against an unpinned source. The spec ships
        // with empty `revision` + `sha256` placeholders until P2-LLM-05's
        // wiring captures real values — failing loudly is strictly better
        // than fetching HEAD against an unpinned commit.
        guard !spec.revision.isEmpty, !spec.sha256.isEmpty else {
            let err = LLMModelManagerError.unpinnedSpec(spec.id)
            state = .failed(err)
            throw err
        }

        if let existing = existingFile(for: spec) {
            state = .ready(model: spec.id, sizeBytes: fileSize(existing))
            return existing
        }

        if let task = downloadTask {
            return try await task.value
        }

        let task = Task<URL, Error> { [weak self, spec] in
            guard let self else { throw CancellationError() }
            do {
                let destination = try await self.download(spec: spec)
                try await self.verify(spec: spec, at: destination)
                try await self.prepare(spec: spec, at: destination)
                let size = self.fileSize(destination)
                self.state = .ready(model: spec.id, sizeBytes: size)
                return destination
            } catch {
                let wrapped = (error as? LLMModelManagerError) ?? .unknown(error.localizedDescription)
                self.state = .failed(wrapped)
                throw wrapped
            }
        }
        downloadTask = task
        defer { downloadTask = nil }
        return try await task.value
    }

    /// Check disk for a previously downloaded + verified model. Returns nil
    /// if absent. Does NOT re-verify — that happens during `.verifying`
    /// inside `ensureReady`. A verified file's path encodes the SHA prefix,
    /// so the presence of the file at the expected path is itself a weak
    /// integrity claim (a tampered file at the right path won't re-verify
    /// on the next launch's re-hash, but routine code doesn't burn 0.8 GB
    /// of I/O on every Formal dictation just to confirm).
    func existingFile(for spec: LocalLLMModelSpec) -> URL? {
        let url = filePath(for: spec)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func refreshState(for spec: LocalLLMModelSpec) {
        if let url = existingFile(for: spec) {
            state = .ready(model: spec.id, sizeBytes: fileSize(url))
        } else {
            state = .absent
        }
    }

    func deleteModel(_ spec: LocalLLMModelSpec) throws {
        // Unload the inference context before yanking the file out from
        // under llama.cpp. The hook owner (LocalLLMService) is responsible
        // for handling a nil-context state cleanly.
        if isPipeReady {
            markPipeNotReady()
        }
        let folder = folderPath(for: spec)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        state = .absent
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .absent
    }

    // MARK: - Pipeline steps

    /// HF download → temp file in the model folder, atomically renamed on
    /// completion so a partial download never looks like a complete one.
    /// `URLSession` is ephemeral and matches `LLMService`'s hardening:
    /// no on-disk URL cache, no cookies, no credential storage. Matches
    /// the existing `LLMService` pattern at `LLMService.swift:10–17` so
    /// nothing about the local-model download leaks to disk caches.
    private func download(spec: LocalLLMModelSpec) async throws -> URL {
        state = .downloading(progress: 0)

        let folder = folderPath(for: spec)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = filePath(for: spec)
        let temp = folder.appendingPathComponent(spec.gguf + ".part")
        // Remove any leftover partial from a previous crashed run.
        try? FileManager.default.removeItem(at: temp)

        let urlString = "https://huggingface.co/\(spec.hfRepo)/resolve/\(spec.revision)/\(spec.gguf)"
        guard let url = URL(string: urlString) else {
            throw LLMModelManagerError.invalidURL(urlString)
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60 * 60  // 1 h — a flaky cafe Wi-Fi 0.8 GB
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let (tempDownload, response) = try await session.download(from: url) { progress in
            Task { @MainActor [weak self] in
                self?.state = .downloading(progress: progress)
            }
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LLMModelManagerError.httpError(http.statusCode)
        }

        // URLSession.download writes to a system tmp path; move it into
        // our model folder before returning.
        if FileManager.default.fileExists(atPath: temp.path) {
            try FileManager.default.removeItem(at: temp)
        }
        try FileManager.default.moveItem(at: tempDownload, to: temp)
        // Atomically rename .part → final so an observer that races to
        // read the file never sees a half-finished download.
        if FileManager.default.fileExists(atPath: final.path) {
            try FileManager.default.removeItem(at: final)
        }
        try FileManager.default.moveItem(at: temp, to: final)
        return final
    }

    /// SHA-256 the on-disk file in 1 MiB chunks (so we don't pull 0.8 GB
    /// into RAM) and compare against `spec.sha256`. On mismatch: delete the
    /// file so the next `ensureReady` re-downloads instead of looping on
    /// a corrupted artifact.
    private func verify(spec: LocalLLMModelSpec, at url: URL) async throws {
        state = .verifying
        let actual = try await Self.sha256(of: url)
        guard actual.caseInsensitiveCompare(spec.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: url)
            throw LLMModelManagerError.sha256Mismatch(expected: spec.sha256, actual: actual)
        }
    }

    /// Prewarm the inference context if a hook is wired. Until P2-LLM-07
    /// lands `prewarmHook` is nil and this is a no-op — the first
    /// dictation pays a one-time cold-load instead.
    private func prepare(spec: LocalLLMModelSpec, at url: URL) async throws {
        state = .preparing
        guard let hook = prewarmHook else { return }
        do {
            try await hook(spec, url)
        } catch {
            // Mirror the WhisperModelManager pattern at lines 158–167:
            // prewarm failure is non-fatal. Bytes are on disk and verified;
            // the next cleanup call retries the context load. The user
            // just loses the first-dictation-is-instant property.
            #if DEBUG
            print("[Sprich][LLM] Prewarm after download failed — will retry on first dictation: \(error)")
            #endif
        }
    }

    // MARK: - Helpers

    /// Disk path for the model folder. Versioned by the first 8 chars of
    /// the SHA so two specs with different revisions don't collide.
    private func folderPath(for spec: LocalLLMModelSpec) -> URL {
        let shaPrefix = String(spec.sha256.prefix(8))
        return baseURL.appendingPathComponent("\(spec.id)-\(shaPrefix)", isDirectory: true)
    }

    /// Disk path for the GGUF file inside its versioned folder.
    private func filePath(for spec: LocalLLMModelSpec) -> URL {
        folderPath(for: spec).appendingPathComponent(spec.gguf)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// Stream-hash a file in 1 MiB chunks. Heavy work runs on a detached
    /// task so the MainActor isolation doesn't make us block the UI for
    /// the ~1 s hash on M1 Pro.
    private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

// MARK: - URLSession async download with progress

private extension URLSession {

    /// `URLSession.download(from:)` doesn't expose progress as an async
    /// stream — wrap the delegate-based API with a continuation so the
    /// manager can publish `state = .downloading(progress:)` as bytes
    /// arrive. Calls `progressHandler` on a background queue; the
    /// handler is responsible for hopping to MainActor.
    func download(
        from url: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            var observation: NSKeyValueObservation?
            let task = self.downloadTask(with: url) { tempURL, response, error in
                observation?.invalidate()
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                // The temp file is auto-deleted when this completion returns,
                // so move it somewhere durable BEFORE returning.
                let durable = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sprich-llm-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: durable)
                    continuation.resume(returning: (durable, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                progressHandler(progress.fractionCompleted)
            }
            task.resume()
        }
    }
}

// MARK: - Errors

enum LLMModelManagerError: Error, Equatable, LocalizedError {
    case unpinnedSpec(String)
    case invalidURL(String)
    case httpError(Int)
    case sha256Mismatch(expected: String, actual: String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unpinnedSpec(let id):
            return "Local LLM spec '\(id)' is not pinned (missing revision or SHA-256). Refusing to download against an unpinned source — see LocalLLMModelSpec for the wiring TODO."
        case .invalidURL(let s):
            return "Invalid model download URL: \(s)"
        case .httpError(let code):
            return "Model download failed with HTTP \(code). Check your network or try again."
        case .sha256Mismatch(let expected, let actual):
            return "Downloaded model SHA-256 did not match the pinned digest.\nExpected: \(expected)\nActual:   \(actual)\nThe partial file has been removed; retry the download."
        case .unknown(let detail):
            return "Local LLM model setup failed: \(detail)"
        }
    }
}
