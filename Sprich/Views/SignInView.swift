import SwiftUI

/// Standalone sign-in window. Wraps `SignInPanel` with a fixed-size
/// frame so it slots into an `NSWindow` without resizing chrome.
///
/// Inline rendering inside `OnboardingView` step 0 uses `SignInPanel`
/// directly so it can size to its container.
///
/// OAuth provider configuration lives in the Supabase dashboard under
/// Authentication → Providers. Until a provider is configured server-
/// side, clicking the button takes the user to a Supabase error page
/// in the auth sheet — soft fail, they can dismiss and pick another
/// method.
struct SignInView: View {
    var body: some View {
        VStack(spacing: 0) {
            SignInPanel(showsHeader: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 420, height: 560)
    }
}
