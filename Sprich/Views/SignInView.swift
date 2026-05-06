import SwiftUI

/// Sign-in surface. Three OAuth providers (Apple / Google / Microsoft)
/// plus a magic-link email fallback. All paths route back through the
/// same `sprich://auth/callback` deep-link.
///
/// OAuth provider configuration lives in the Supabase dashboard under
/// Authentication → Providers. Until a provider is configured server-
/// side, clicking the button takes the user to a Supabase error page
/// in the auth sheet — soft fail, they can dismiss and pick another
/// method.
struct SignInView: View {
    @StateObject private var auth = AuthService.shared

    @State private var email: String = ""
    @State private var linkRequested: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            header

            if !linkRequested {
                providerButtons
                orDivider
                emailEntry
            } else {
                awaitingCallback
            }

            if let err = auth.lastError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 420, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            SprichMark()
                .frame(width: 52, height: 52)

            VStack(spacing: 4) {
                Text("Welcome to Sprich")
                    .font(.title2.weight(.semibold))
                Text("Sign in to start your 7-day free trial.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - OAuth buttons

    private var providerButtons: some View {
        VStack(spacing: 10) {
            ForEach(AuthService.OAuthProvider.allCases) { provider in
                ProviderButton(provider: provider) {
                    auth.signInWithOAuth(provider: provider)
                }
            }
        }
    }

    // MARK: - Divider

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
            Text("OR")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
    }

    // MARK: - Email

    private var emailEntry: some View {
        VStack(spacing: 10) {
            TextField("you@example.com", text: $email)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .disableAutocorrection(true)
                .onSubmit { Task { await requestLink() } }

            Button {
                Task { await requestLink() }
            } label: {
                HStack {
                    if auth.isRequestingLink {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Sending…").font(.callout.weight(.medium))
                    } else {
                        Text("Continue with email").font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.callout.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(emailIsValid ? Color.accentColor : Color.gray.opacity(0.4))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(auth.isRequestingLink || !emailIsValid)
        }
    }

    private var emailIsValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.contains("@") && trimmed.contains(".")
    }

    private var awaitingCallback: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("Check your inbox")
                    .font(.headline)
                Text("We sent a sign-in link to **\(email)**. Click it from this Mac — you'll come right back here, signed in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Send again") {
                    Task { await requestLink() }
                }
                .disabled(auth.isRequestingLink)

                Button("Use a different email") {
                    linkRequested = false
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    private func requestLink() async {
        await auth.requestMagicLink(email: email)
        if auth.lastError == nil {
            linkRequested = true
        }
    }
}

// MARK: - Provider button

private struct ProviderButton: View {
    let provider: AuthService.OAuthProvider
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                providerGlyph
                    .frame(width: 18, height: 18)
                Text("Continue with \(provider.displayName)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var providerGlyph: some View {
        switch provider {
        case .apple:
            Image(systemName: "applelogo")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        case .google:
            GoogleGMark()
        case .azure:
            MicrosoftMark()
        }
    }
}

// MARK: - Google G mark
//
// Official Google "G" brand mark, loaded from Assets.xcassets as a
// vector SVG (Contents.json: preserves-vector-representation = true).
// The asset scales cleanly at any button size without rasterizing.
//
// The earlier Canvas-drawn version got the arc geometry wrong — easier
// and more accurate to ship the canonical SVG that Google publishes for
// Sign-in flows in their brand guidelines.
private struct GoogleGMark: View {
    var body: some View {
        Image("GoogleG")
            .resizable()
            .renderingMode(.original)
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Microsoft 4-square mark
//
// Official brand colors for the Microsoft tiles (confirmed against
// Microsoft Brand Central guidelines).
private struct MicrosoftMark: View {
    var body: some View {
        VStack(spacing: 1.5) {
            HStack(spacing: 1.5) {
                Rectangle().fill(Color(red: 0.95, green: 0.32, blue: 0.13)) // F25022
                Rectangle().fill(Color(red: 0.49, green: 0.78, blue: 0.0))  // 7FBA00
            }
            HStack(spacing: 1.5) {
                Rectangle().fill(Color(red: 0.0,  green: 0.65, blue: 0.94)) // 00A4EF
                Rectangle().fill(Color(red: 1.0,  green: 0.73, blue: 0.0))  // FFB900
            }
        }
    }
}

// MARK: - Sprich mark (header)
//
// The forest-green rounded square + cream "S" mark from `ModeTokens`.
// Reproduced here so the sign-in window doesn't need an Assets.xcassets
// PNG dependency.
private struct SprichMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 31/255, green: 95/255, blue: 75/255))
            Text("S")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 250/255, green: 250/255, blue: 247/255))
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
