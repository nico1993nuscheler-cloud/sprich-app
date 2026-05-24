import Foundation
import SwiftData

/// SwiftData record for a single completed dictation. Text-only —
/// audio is never persisted (sidesteps audio-retention policy questions).
/// 30-day rolling window enforced by `HistoryStore.prune()`.
///
/// P1-PRD-12.
@Model
final class HistoryEntry {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    /// `TranscriptionMode.rawValue` ("literal" / "formal" / "custom").
    /// Stored as String so a future mode rename doesn't orphan records.
    var modeRaw: String
    /// Localized display name of the app that was frontmost at hotkey-
    /// press time (e.g. "Slack"). nil when capture failed.
    var targetApp: String?
    /// The full final text that was pasted. No truncation — list views
    /// snapshot a preview themselves.
    var fullText: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        modeRaw: String,
        targetApp: String?,
        fullText: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modeRaw = modeRaw
        self.targetApp = targetApp
        self.fullText = fullText
    }
}

/// Manages the SwiftData container for dictation history (P1-PRD-12).
/// Single source of truth; views observe `entries` directly.
///
/// Auto-prune of >30-day entries runs in `pruneOldEntries()`, called
/// by `AppDelegate.applicationDidFinishLaunching`.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Days to keep before auto-prune. The dev plan locked 30 d; a
    /// future Privacy section toggle (P1-PRD-21) can override this.
    static let retentionDays: Int = 30

    @Published private(set) var entries: [HistoryEntry] = []

    private let container: ModelContainer

    private init() {
        // ApplicationSupport/Sprich/history.sqlite — same directory the
        // app already writes settings.json into.
        let fm = FileManager.default
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Sprich", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("history.sqlite")
        let config = ModelConfiguration(url: storeURL)
        do {
            container = try ModelContainer(for: HistoryEntry.self, configurations: config)
        } catch {
            // SwiftData failure is non-recoverable for history — fall
            // back to in-memory so the app still launches. The user
            // sees an empty history; restart often clears the issue.
            #if DEBUG
            print("[Sprich][History] persistent container init failed: \(error) — falling back to in-memory")
            #endif
            let mem = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: HistoryEntry.self, configurations: mem)
        }
        reload()
    }

    /// Re-fetch all entries, newest first. Called after every mutation
    /// so `@Published entries` stays in sync without `@Query` plumbing.
    private func reload() {
        let descriptor = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        entries = (try? container.mainContext.fetch(descriptor)) ?? []
    }

    /// Append a new dictation record. Called from `PipelineCoordinator`
    /// immediately after a successful paste / deliver.
    /// No-op when `fullText` is empty (Whisper-empty path).
    func record(text: String, mode: TranscriptionMode, targetApp: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = HistoryEntry(
            modeRaw: mode.rawValue,
            targetApp: targetApp,
            fullText: text
        )
        container.mainContext.insert(entry)
        try? container.mainContext.save()
        reload()
    }

    /// Delete entries older than `retentionDays`. Runs on app launch.
    func pruneOldEntries() {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate<HistoryEntry> { $0.timestamp < cutoff }
        )
        let stale = (try? container.mainContext.fetch(descriptor)) ?? []
        guard !stale.isEmpty else { return }
        for entry in stale {
            container.mainContext.delete(entry)
        }
        try? container.mainContext.save()
        reload()
    }

    func delete(_ entry: HistoryEntry) {
        container.mainContext.delete(entry)
        try? container.mainContext.save()
        reload()
    }

    func clearAll() {
        for entry in entries {
            container.mainContext.delete(entry)
        }
        try? container.mainContext.save()
        reload()
    }
}
