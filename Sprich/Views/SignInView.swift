import SwiftUI

/// Sign-in surface. Offers three OAuth providers (Apple / Google /
/// Microsoft) and a magic-link email fallback. All paths route back
/// through the same `sprich://auth/callback` deep-link.
///
/// OAuth provider configuration lives in the Supabase dashboard under
/// Authentication → Providers. Each provider needs to be enabled and
/// have its client ID + secret pasted in. Until the provider is
/// configured server-side, clicking the button takes the user to a
/// Supabase error page.
struct SignInView: View {
    @StateObject private var auth = AuthService.shared

    @State private var email: String = ""
    @State private var linkRequested: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to start your 7-day trial")
                    .font(.title2.weight(.semibold))
                Text("Pick your preferred sign-in. We'll never store a password — auth tokens live in your Mac's Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !linkRequested {
                oauthButtons
                divider
                emailEntry
            } else {
                awaitingCallback
            }

            if let err = auth.lastError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 460, height: 540)
    }

    // MARK: - OAuth row

    private var oauthButtons: some View {
        VStack(spacing: 8) {
            ForEach(AuthService.OAuthProvider.allCases) { provider in
                Button {
                    auth.signInWithOAuth(provider: provider)
                } label: {
                    HStack(spacing: 10) {
                        providerGlyph(provider)
                            .frame(width: 18, height: 18)
                        Text("Continue with \(provider.displayName)")
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func providerGlyph(_ provider: AuthService.OAuthProvider) -> some View {
        switch provider {
        case .apple:
            Image(systemName: "applelogo")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
        case .google:
            // Multi-color "G" approximated with SF Symbol; real Google
            // brand-mark asset can replace this when added to Assets.
            Text("G")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LinearGradient(
                    colors: [.blue, .red, .yellow, .green],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        case .azure:
            // Microsoft 4-square mark approximated with a 2x2 grid.
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    Rectangle().fill(Color(red: 0.95, green: 0.32, blue: 0.13))
                    Rectangle().fill(Color(red: 0.49, green: 0.78, blue: 0.13))
                }
                HStack(spacing: 1) {
                    Rectangle().fill(Color(red: 0.0, green: 0.65, blue: 0.94))
                    Rectangle().fill(Color(red: 1.0, green: 0.71, blue: 0.0))
                }
            }
            .frame(width: 14, height: 14)
        }
    }

    // MARK: - Divider

    private var divider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            Text("OR")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
    }

    // MARK: - Email

    private var emailEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .onSubmit { Task { await requestLink() } }

            Button {
                Task { await requestLink() }
            } label: {
                HStack {
                    if auth.isRequestingLink {
                        ProgressView().controlSize(.small)
                    }
                    Text(auth.isRequestingLink ? "Sending…" : "Continue with email")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.callout)
                        .opacity(auth.isRequestingLink ? 0 : 0.6)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .keyboardShortcut(.defaultAction)
            .disabled(auth.isRequestingLink || email.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var awaitingCallback: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check your inbox")
                .font(.headline)
            Text("We sent a sign-in link to **\(email)**. Click the link from the same Mac and you'll come right back here, signed in.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Send again") {
                    Task { await requestLink(force: true) }
                }
                .disabled(auth.isRequestingLink)
                Button("Use a different email") {
                    linkRequested = false
                }
                Spacer()
            }
        }
    }

    private func requestLink(force: Bool = false) async {
        await auth.requestMagicLink(email: email)
        if auth.lastError == nil {
            linkRequested = true
        }
    }
}
