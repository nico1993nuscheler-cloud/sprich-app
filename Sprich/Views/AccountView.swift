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
///
/// 2026-05-15 follow-up (post-v1.0.4 testing audit): added a
/// `.deviceBlocked` branch — the device-fingerprint anti-trial-abuse
/// gate (HTTP 409 from `start-trial`) was a dead-end surface. Now we
/// acknowledge the state and offer two recovery paths (sign back into
/// the original account, or buy a license — which `redeem-license`
/// attaches by email, freeing the user up). Mirrors TrialLockView's
/// visual language since both are "we acknowledge your bad state +
/// here's a way out" surfaces.
struct AccountView: View {
    @StateObject private var auth = AuthService.shared
    @StateObject private var trial = TrialState.shared

    /// Closure provided by `AppDelegate.showAccountWindow` so the same
    /// confirm-then-sign-out alert used by the menubar sign-out row is
    /// reused here — avoids duplicating the confirmation copy.
    let onSignOut: () -> Void

    /// "Restore purchase" recovery state. Re-runs validate-trial, which
    /// also auto-attaches any pending LemonSqueezy order parked under this
    /// account's email. Self-serve fix for "I paid but it didn't unlock".
    @State private var isRestoring = false
    @State private var restoreResult: String?

    var body: some View {
        Group {
            if trial.entitlement == .deviceBlocked {
                deviceBlockedBody
            } else {
                standardBody
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Standard signed-in body (trialActive / licensed / unknown)

    private var standardBody: some View {
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

            restoreRow

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
    }

    // MARK: - Device-blocked body

    /// Shown when the server's anti-trial-abuse fingerprint check has
    /// already attached this Mac to another account. Two recovery
    /// affordances + a support-mailto footnote so a legitimate buyer
    /// is never stuck.
    private var deviceBlockedBody: some View {
        let currentEmail = auth.currentUserEmail ?? ""
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac is linked to another Sprich account")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(
                    "We bind the 7-day trial to your device to prevent abuse. "
                    + "To use Sprich on this Mac with **\(currentEmail)**, you have two options:"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                recoveryCard(
                    title: "Sign in to the original account",
                    body: "If you have access to the email this Mac was originally registered under, sign back in with that account. Your trial / license state will be restored immediately.",
                    button: AnyView(
                        Button("Sign out and try another email") {
                            onSignOut()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    )
                )

                recoveryCard(
                    title: "Buy a license for this account",
                    body: "Lifetime licenses follow your Sprich account, not your device — buy now and you can use this account on any Mac (after the device is freed).",
                    button: AnyView(
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://sprichapp.com/pricing")!)
                        } label: {
                            Text("Buy lifetime license →")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .keyboardShortcut(.defaultAction)
                    )
                )
            }

            supportFootnote(currentEmail: currentEmail)

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 460, height: 460)
    }

    private func recoveryCard(title: String, body: String, button: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            button
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func supportFootnote(currentEmail: String) -> some View {
        // mailto with pre-filled subject so Nico's eventual triage is
        // cleaner. URL-encode the subject so addresses with `+` or
        // spaces don't break the link.
        let subject = "Move device — \(currentEmail)"
        let encoded = subject.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? subject
        let mailto = URL(string: "mailto:support@sprichapp.com?subject=\(encoded)")
            ?? URL(string: "mailto:support@sprichapp.com")!

        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Lost access to the original account? Email")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("support@sprichapp.com", destination: mailto)
                .font(.caption)
            Text("with this device's email and we'll move it manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Restore purchase / refresh license

    /// Shown unless already licensed. A buyer whose purchase didn't attach
    /// (paid with a different email, signed up after paying) clicks this to
    /// force a fresh validate-trial — which auto-attaches any pending order
    /// matching their account email. If still nothing attaches, points them
    /// at support so they're never stuck.
    @ViewBuilder
    private var restoreRow: some View {
        if trial.entitlement != .licensed {
            VStack(spacing: 6) {
                Button {
                    Task { await restoreLicense() }
                } label: {
                    HStack(spacing: 6) {
                        if isRestoring {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRestoring ? "Checking…" : "Restore purchase")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isRestoring)

                if let restoreResult {
                    Text(restoreResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @MainActor
    private func restoreLicense() async {
        isRestoring = true
        restoreResult = nil
        await trial.validateNow()
        isRestoring = false
        if trial.entitlement == .licensed {
            restoreResult = "Purchase restored — lifetime access is active."
        } else if let err = trial.lastError {
            restoreResult = "Couldn't reach the server (\(err)). Check your connection and try again."
        } else {
            let email = auth.currentUserEmail ?? "this account"
            restoreResult = "No purchase found for \(email). If you paid with a different email, email support@sprichapp.com."
        }
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
