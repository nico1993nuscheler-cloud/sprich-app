import SwiftUI

/// Settings → Dictionary (P1-PRD-24). Surfaces:
///   1. The Auto-learn toggle.
///   2. A list of all `glossaryReplacements` (deletable).
///   3. An inline "Add" row for manual entries.
///
/// Closes the Sprint 3 Decision-8 gap: dictionary editing was cut from
/// Sprint 3 on the promise that Auto-learn would be its successor
/// surface. This is that surface.
struct DictionarySection: View {
    @EnvironmentObject var appState: AppState

    @State private var newFrom: String = ""
    @State private var newTo: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionHeader(icon: "text.book.closed", title: "Dictionary")

                Text("Words and phrases Sprich should always rewrite a certain way. Whisper biases toward these on transcription, then Sprich applies them as exact find-and-replace.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                autoLearnCard
                replacementsCard
                addRowCard

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var autoLearnCard: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.blue)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Learn from my corrections", isOn: $appState.settings.autoLearnEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: appState.settings.autoLearnEnabled) { _, _ in
                            appState.saveSettings()
                        }
                    Text("When you retype a dictated word in the next 30 seconds, Sprich proposes adding the correction to your dictionary.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var replacementsCard: some View {
        SettingsCard {
            HStack {
                Text("Replacements")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(appState.settings.glossaryReplacements.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if appState.settings.glossaryReplacements.isEmpty {
                Text("No replacements yet. Accept a proposed correction from the banner, or add one below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(appState.settings.glossaryReplacements) { entry in
                        replacementRow(entry: entry)
                        if entry.id != appState.settings.glossaryReplacements.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func replacementRow(entry: GlossaryReplacement) -> some View {
        HStack(spacing: 8) {
            Text(entry.from)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(entry.to)
                .font(.system(size: 12, design: .monospaced))
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            Button {
                appState.settings.glossaryReplacements.removeAll { $0.id == entry.id }
                appState.saveSettings()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove replacement")
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var addRowCard: some View {
        SettingsCard {
            Text("Add manually")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("", text: $newFrom, prompt: Text("Heard as…"))
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                TextField("", text: $newTo, prompt: Text("Replace with…"))
                    .textFieldStyle(.roundedBorder)
                Button {
                    addReplacement()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
        }
    }

    private var canAdd: Bool {
        let f = newFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = newTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty else { return false }
        return !appState.settings.glossaryReplacements
            .contains(where: { $0.from.lowercased() == f.lowercased() })
    }

    private func addReplacement() {
        let f = newFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = newTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty else { return }
        appState.settings.glossaryReplacements.append(GlossaryReplacement(from: f, to: t))
        appState.saveSettings()
        newFrom = ""
        newTo = ""
    }
}
