import SwiftUI

/// Hard-lock screen shown when the user's 7-day trial has expired and
/// no license is attached. Per D4 (decisions log 2026-05-04), the
/// trial-end behavior is a hard lock with a "buy now" CTA — no
/// degraded mode, no read-only.
///
/// The Buy CTA opens `https://sprichapp.com/pricing` in the browser;
/// Sprint 2C wires the LemonSqueezy checkout overlay into the funnel.
struct TrialLockView: View {
    @StateObject private var auth = AuthService.shared
    @StateObject private var trial = TrialState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your 7-day trial has ended")
                    .font(.title2.weight(.semibold))
                Text("Buy a Sprich lifetime license to keep dictating. Pay once, use forever — no subscription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://sprichapp.com/pricing")!)
                } label: {
                    Text("Buy lifetime license")
                        .frame(minWidth: 180)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                Button("Already bought? Refresh") {
                    Task { await trial.validateNow() }
                }
            }

            if let email = auth.currentUserEmail {
                Text("Signed in as **\(email)**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Sign out") { auth.signOut() }
                    .controlSize(.small)
                Spacer()
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 460, height: 280)
    }
}
