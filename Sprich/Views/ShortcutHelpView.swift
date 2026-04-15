import SwiftUI
import AppKit

/// Standalone "How to use Sprich" window content.
/// Mirrors the final onboarding step — shortcut cheat-sheet — so users can
/// re-open it any time from the menu bar.
struct ShortcutHelpView: View {
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .frame(width: 500, height: 520)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let logo = NSImage(named: "SprichLogo") {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("How to use Sprich").font(.title2).fontWeight(.semibold)
                Text("Hold the combo, speak, release.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your shortcuts").font(.title3).fontWeight(.bold)

            Text("Hold the combo, speak, release. The cleaned text is pasted into whatever app is focused.")
                .foregroundColor(.secondary).font(.callout)

            VStack(spacing: 10) {
                shortcutCard(
                    symbols: ["globe", "shift"],
                    labels:  ["fn",     "shift"],
                    title:   "Literal",
                    subtitle: "Clean transcription — fillers removed, grammar fixed.",
                    useCases: "Chats · Notes · Code comments",
                    accent:  Color(red: 0.35, green: 0.85, blue: 0.65)
                )
                shortcutCard(
                    symbols: ["globe", "control"],
                    labels:  ["fn",     "control"],
                    title:   "Formal",
                    subtitle: "Restructured into polished written language.",
                    useCases: "Emails · Documents · Proposals",
                    accent:  Color(red: 0.55, green: 0.45, blue: 0.95)
                )
                shortcutCard(
                    symbols: ["globe", "command"],
                    labels:  ["fn",     "cmd"],
                    title:   "Custom",
                    subtitle: "Your own prompt (enable in Settings).",
                    useCases: "Slack tone · Bullet points · Any niche style",
                    accent:  Color(red: 0.95, green: 0.65, blue: 0.35)
                )
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
                Text("Tip: change shortcuts, prompts and providers in Settings → ⌘,")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func shortcutCard(
        symbols: [String],
        labels: [String],
        title: String,
        subtitle: String,
        useCases: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(zip(symbols, labels).enumerated()), id: \.offset) { idx, pair in
                    if idx > 0 {
                        Text("+").font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    keycap(symbol: pair.0, label: pair.1)
                }
            }
            .frame(width: 128, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary)
                Text(useCases)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accent.opacity(0.85))
                    .padding(.top, 1)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func keycap(symbol: String, label: String) -> some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
        }
        .foregroundColor(.primary)
        .frame(width: 44, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.gray.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 1, y: 1)
    }
}
