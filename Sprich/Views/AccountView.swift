import SwiftUI
import AppKit

/// Minimal account surface opened from the menubar account row when the
/// user is already signed in. Replaces the prior `handleAccountClick`
/// fallthrough to `SignInView` (which confusingly read
/// "Sign in to start your 7-day trial" for users who *were* signed in).
///
/// Sprint 2E L1.4 scope (locked 2026-05-15) is intentionally minimal:
/// SprichMark + email + one-line trial state + Upgrade button (active
/// trial only) + Sign out. The richer panel (receipts, devices, support
/// links) waits for Sprint 3.
struct AccountView: View {
    @StateObject private var auth = AuthService.shared
    @StateObject private var trial = TrialState.shared

    /// Closure provided by `AppDelegate.showAccountWindow` so the same
    /// confirm-then-sign-out alert used by the menubar sign-out row is
    /// reused here — avoids duplicating the confirmation copy.
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            SprichMark()
                .frame(width: 52, height: 52)
                .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Your Sprich account")
                    .font(.title2.weight(.semibold))
            }

            VStack(spacing: 10) {
                emailRow
                trialStateRow
            }
            .frame(maxWidth: .infinity)

            if trial.entitlement == .trialActive {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://sprichapp.com/pricing")!)
                } label: {
                    Text("Upgrade to lifetime")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            Spacer(minLength: 0)

            Button("Sign out") {
                onSignOut()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(28)
        .frame(width: 420, height: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Email row

    private var emailRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.accentColor)
            Text(auth.currentUserEmail ?? "")
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    // MARK: - Trial state row

    private var trialStateRow: some View {
        HStack(spacing: 8) {
            Image(systemName: trialStateIcon)
                .foregroundStyle(trialStateTint)
            Text(trialStateLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var trialStateLine: String {
        switch trial.entitlement {
        case .licensed:
            return "Lifetime license active"
        case .trialActive:
            let days = trial.daysRemaining
            return days == 1
                ? "Trial active — 1 day left"
                : "Trial active — \(days) days left"
        case .unknown:
            return "Trial syncing…"
        case .deviceBlocked:
            return "Device linked to another account"
        case .trialExpired:
            // Routed away to TrialLockView by handleAccountClick, but
            // keep a sensible string for defensive rendering.
            return "Trial ended"
        case .signedOut:
            return "Signed out"
        }
    }

    private var trialStateIcon: String {
        switch trial.entitlement {
        case .licensed: return "checkmark.seal.fill"
        case .trialActive: return "clock.fill"
        case .unknown: return "arrow.triangle.2.circlepath"
        case .deviceBlocked: return "person.crop.circle.badge.exclamationmark"
        case .trialExpired: return "exclamationmark.triangle.fill"
        case .signedOut: return "person.crop.circle"
        }
    }

    private var trialStateTint: Color {
        switch trial.entitlement {
        case .licensed: return .green
        case .trialActive: return .accentColor
        case .deviceBlocked, .trialExpired: return .orange
        default: return .secondary
        }
    }
}
