import SwiftUI
import AppKit

/// Settings → Home (P1-PRD-12). The History view — 30-day rolling
/// window of dictations, text-only, click-to-copy, search-by-text.
/// No audio persistence. Lives at the top of the sidebar.
struct HomeSection: View {
    // P1-BUG-01 (v1.0.8 hotfix): kept as @StateObject. Switching to
    // @ObservedObject for "correctness with a singleton" actually broke
    // NavigationSplitView's detail rendering (entire detail column went
    // blank on mount). @StateObject works fine here in practice — the
    // real bug was HistoryStore.init() publishing to @Published.entries
    // synchronously during the first view render. Fixed there by deferring
    // the initial reload() to DispatchQueue.main.async.
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
        // P1-BUG-01 (v1.0.9 fix): outer frame must NOT include
        // `maxHeight: .infinity`. Every other Settings section uses just
        // `.frame(maxWidth: .infinity, alignment: .topLeading)` — only
        // HomeSection had `maxHeight: .infinity`, and that was the cause
        // of the Settings sidebar collapsing on Home click. The infinite-
        // height request inside NavigationSplitView's detail column
        // triggered macOS's auto-collapse heuristic (decides the detail
        // is "large enough" to deserve the whole window).
        //
        // The inner ScrollView still gets the available height because
        // SettingsView's outer Group has its own `maxHeight: .infinity`
        // (SettingsView.swift:121) and propagates it via topLeading.
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
            SettingsSectionHeader(icon: "house", title: "Home")
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
        ScrollView {
            LazyVStack(spacing: 0) {
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
