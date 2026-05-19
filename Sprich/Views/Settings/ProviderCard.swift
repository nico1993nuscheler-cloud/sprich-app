import SwiftUI

/// Reusable two-card selector used by both Onboarding (card 3) and
/// Settings → AI Models (P1-UX-02 / P1-UX-08 / P1-UX-09).
///
/// Decision 2 in sprint-3-settings-ux.md: the load-bearing AI Models
/// page is two stacked sections (Speech recognition + AI cleanup), each
/// rendered as a 2-card selector (Cloud / On this Mac). The same shape
/// lifts into onboarding so the user sees a single design pattern from
/// first launch through Settings.
///
/// `ProviderCard` is the individual card (one of Cloud / On this Mac).
/// `ProviderCardPair` wires two cards side-by-side, drives selection.
///
/// Visual lineage: lifted and generalised from
/// `OnboardingView.providerOptionCard` (Sprint 2C).

/// One side of a `ProviderCardPair`. Owns its selected/unselected
/// styling; the parent owns the selection binding.
struct ProviderCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 22))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .frame(width: 28)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.08)
                          : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.2),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// Two cards side-by-side: Cloud and On-this-Mac. Generic over the
/// caller's notion of "selected" via a Bool plus two action closures.
/// Callers keep their own enum (e.g. `STTProviderType.isLocal`) and
/// translate to this Bool — keeps the component decoupled from
/// provider-enum changes.
struct ProviderCardPair: View {
    /// `true` if On-this-Mac is currently selected; `false` for Cloud.
    let isLocalSelected: Bool

    let cloudTitle: String
    let cloudIcon: String
    let cloudSubtitle: String
    let cloudDescription: String

    let localTitle: String
    let localIcon: String
    let localSubtitle: String
    let localDescription: String

    let onSelectCloud: () -> Void
    let onSelectLocal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderCard(
                icon: cloudIcon,
                title: cloudTitle,
                subtitle: cloudSubtitle,
                description: cloudDescription,
                isSelected: !isLocalSelected,
                action: onSelectCloud
            )
            ProviderCard(
                icon: localIcon,
                title: localTitle,
                subtitle: localSubtitle,
                description: localDescription,
                isSelected: isLocalSelected,
                action: onSelectLocal
            )
        }
    }
}
