import SwiftUI
import AppKit

/// Settings → History (P1-PRD-12). 30-day rolling window of dictations,
/// text-only, click-to-copy, search-by-text. No audio persistence. Lives
/// at the top of the sidebar.
///
/// v1.0.10 rename: was `HomeSection`. The section was always the History
/// view per P1-PRD-12 — "Home" was a vestigial sidebar label without
/// matching multi-card content. Honest naming, no functional change.
struct HistorySection: View {
    // P1-BUG-01: `@StateObject` is correct here — switching to
    // `@ObservedObject` broke detail rendering in the NavigationSplitView
    // era (now retired in v1.0.10 — see SettingsView.body for full bug
    // history). The synchronous-publish-during-render issue this property
    // wrapper choice originally got blamed for was actually fixed in
    // `HistoryStore.init` (deferred-reload via `DispatchQueue.main.async`).
    @StateObject private var store = HistoryStore.shared

    @State private var query: String = ""
    @State private var justCopiedID: UUID? = nil
    @State private var confirmClear: Bool = false

    private var filteredEntries: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.fullText.localizedCaseInsensitiveContains(q)
                || (entry.targetApp ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchAndActions
            Divider().padding(.top, 4)

            if store.entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                noResults
            } else {
                entryList
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .alert("Clear all history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                store.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all \(store.entries.count) dictation\(store.entries.count == 1 ? "" : "s") from this Mac. This cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsSectionHeader(icon: "clock.arrow.circlepath", title: "History")
            Text("Everything Sprich has dictated in the last 30 days. Text only — no audio is ever stored. Click any entry to copy it back to your clipboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var searchAndActions: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
            )

            Spacer()

            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Clear all", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private var entryList: some View {
        // P1-BUG-01 (v1.0.10): `VStack` (eager), not `LazyVStack`. LazyVStack
        // inside ScrollView caused two symptoms: (1) the scrollbar's thumb
        // resized as rows materialized below the fold — the content height
        // estimate kept growing — feeling "weird" to scroll; (2) newly recorded
        // entries didn't reliably reflow to the top because Lazy stacks
        // memoize off-screen children and don't re-sort on `@Published`
        // changes. 30-day retention caps the worst case at a few hundred rows,
        // so eager layout is fine.
        ScrollView {
            VStack(spacing: 0) {
                ForEach(filteredEntries) { entry in
                    HistoryRow(
                        entry: entry,
                        wasJustCopied: justCopiedID == entry.id,
                        onCopy: { copy(entry) },
                        onDelete: { store.delete(entry) }
                    )
                    Divider()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No dictations yet")
                .font(.system(size: 14, weight: .medium))
            Text("Press your dictation hotkey to start. Everything you dictate appears here for 30 days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No matches")
                .font(.system(size: 13, weight: .medium))
            Text("Nothing in your last 30 days contains \"\(query)\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func copy(_ entry: HistoryEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.fullText, forType: .string)
        justCopiedID = entry.id
        // Fade the "Copied" hint after a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if justCopiedID == entry.id {
                justCopiedID = nil
            }
        }
    }
}

// MARK: - HistoryRow

private struct HistoryRow: View {
    let entry: HistoryEntry
    let wasJustCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var hovering: Bool = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var modeLabel: String {
        switch entry.modeRaw {
        case "literal": return "Literal"
        case "formal":  return "Formal"
        case "custom":  return "Custom"
        default:        return entry.modeRaw.capitalized
        }
    }

    private var preview: String {
        // Strip newlines for the one-line preview so the row height
        // stays predictable. Full text is what gets copied.
        entry.fullText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(modeLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.15))
                            )
                        if let app = entry.targetApp, !app.isEmpty {
                            Text(app)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(Self.relativeFormatter.localizedString(for: entry.timestamp, relativeTo: Date()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(preview)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                trailingAction
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.gray.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { onCopy() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if wasJustCopied {
            Label("Copied", systemImage: "checkmark")
                .font(.caption2)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else if hovering {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
