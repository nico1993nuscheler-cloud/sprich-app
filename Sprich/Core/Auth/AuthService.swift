import Foundation
import Combine
import AppKit
import AuthenticationServices

/// Magic-link authentication against Supabase EU (`sprich-prod`).
///
/// Flow (P1-PRD-07):
///   1. User enters email → `requestMagicLink(email:)` POSTs to
///      `/auth/v1/otp` with `email_redirect_to = sprich://auth/callback`.
///   2. Supabase emails a one-time link. Click → browser → 302 →
///      `sprich://auth/callback#access_token=…&refresh_token=…&expires_in=…`.
///   3. macOS routes the URL to Sprich via the registered URL scheme.
///      `AppDelegate.application(_:open:)` calls `handleDeepLink(url:)`.
///   4. We parse the URL fragment, store both tokens in Keychain, set
///      `currentSession` and notify observers (TrialState, UI).
///
/// Tokens live in the same Keychain as STT API keys — silent-fail ACL
/// behavior (KeychainManager docs) applies.
///
/// Refresh: `expires_in` is typically 3600 s. We refresh when within
/// 60 s of expiry on every request, and at app foreground. The 24-h
/// offline grace lives in TrialState — the auth token itself only
/// matters when we actually call the server.
@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    /// Holds the current OAuth web session so it isn't deallocated mid-flow.
    private var oauthSession: ASWebAuthenticationSession?

    // MARK: - Public state

    @Published private(set) var currentSession: Session?
    @Published private(set) var isRequestingLink = false
    @Published private(set) var lastError: String?

    var isSignedIn: Bool { currentSession != nil }
    var currentUserEmail: String? { currentSession?.userEmail }
    var currentUserID: String? { currentSession?.userID }

    // MARK: - Keychain key names

    private enum KC {
        static let accessToken = "supabase.access_token"
        static let refreshToken = "supabase.refresh_token"
        static let userID = "supabase.user_id"
        static let userEmail = "supabase.user_email"
        static let expiresAt = "supabase.expires_at"
    }

    // MARK: - Init

    private override init() {
        super.init()
        self.currentSession = Self.loadFromKeychain()
    }

    // MARK: - Magic-link request

    /// Sends a magic-link email to `email`. The user clicks the link;
    /// we receive the redirect via `handleDeepLink(url:)`.
    func requestMagicLink(email: String) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isPlausibleEmail(trimmed) else {
            self.lastError = "That email doesn't look right. Please check and try again."
            return
        }

        self.isRequestingLink = true
        self.lastError = nil
        defer { self.isRequestingLink = false }

        // Supabase's REST `/auth/v1/otp` endpoint reads `redirect_to` from
        // the query string. The JS SDK accepts an `options.emailRedirectTo`
        // shape and rewrites it into a query param under the hood — talking
        // to REST directly we have to put it on the URL ourselves, otherwise
        // Supabase silently falls back to the project's Site URL.
        var components = URLComponents(
            url: SupabaseConfig.authBaseURL.appendingPathComponent("otp"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "redirect_to", value: SupabaseConfig.authCallbackURL),
        ]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")

        let payload: [String: Any] = [
            "email": trimmed,
            "create_user": true,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw AuthError.requestFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(detail)")
            }
        } catch {
            self.lastError = (error as? AuthError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - OAuth (Apple / Google / Microsoft)

    /// Drives the OAuth round-trip via `ASWebAuthenticationSession`.
    ///
    /// Why not `NSWorkspace.open(url)`: a plain Safari tab dispatches
    /// the final `sprich://` redirect to macOS (the app gets signed in
    /// fine) but the tab itself has nowhere to navigate to, so it sits
    /// in an indefinite loading state. ASWebAuthenticationSession opens
    /// a contained Safari sheet, intercepts the custom-scheme callback
    /// directly, dismisses the sheet, and returns the URL to us — same
    /// security model as Safari (uses the system cookie jar by default
    /// so already-signed-in providers skip the credential prompt).
    func signInWithOAuth(provider: OAuthProvider) {
        var components = URLComponents(
            url: SupabaseConfig.authBaseURL.appendingPathComponent("authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: SupabaseConfig.authCallbackURL),
        ]
        guard let authURL = components.url else { return }
        self.lastError = nil

        #if DEBUG
        print("[Sprich][OAuth] signInWithOAuth(\(provider.rawValue)) — building ASWebAuthenticationSession")
        print("[Sprich][OAuth]   authorize URL: \(authURL.absoluteString)")
        #endif

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "sprich"
        ) { [weak self] callbackURL, error in
            guard let self else { return }
            Task { @MainActor in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    // User dismissed the sheet — not an error worth showing.
                    self.oauthSession = nil
                    return
                }
                if let error {
                    self.lastError = error.localizedDescription
                    self.oauthSession = nil
                    return
                }
                guard let callbackURL else {
                    self.lastError = "Sign-in did not complete. Please try again."
                    self.oauthSession = nil
                    return
                }
                _ = self.handleDeepLink(url: callbackURL)
                self.oauthSession = nil
            }
        }
        session.presentationContextProvider = self
        // Ephemeral session: no shared Safari cookies, no system-wide
        // "Sprich wants to use supabase.co to sign in" consent prompt
        // (macOS only shows that dialog when the session would touch
        // existing cookies). Trade-off — users already signed in to
        // their provider in Safari have to enter credentials in the
        // auth sheet. Acceptable because Sprich sign-in is once per
        // device, not recurring; and the consent prompt with a
        // "supabase.co" reference reads as confusing to end users
        // until we move to the Supabase Pro custom domain
        // `auth.sprichapp.com`.
        session.prefersEphemeralWebBrowserSession = true
        self.oauthSession = session
        let started = session.start()
        #if DEBUG
        print("[Sprich][OAuth] session.start() returned \(started)")
        #endif
        if !started {
            self.lastError = "Could not start the sign-in window. Try again, or sign in with email."
        }
    }

    // MARK: - Deep-link callback

    /// Handle `sprich://auth/callback#access_token=…&refresh_token=…`.
    /// Returns true if the URL was a recognized auth callback.
    @discardableResult
    func handleDeepLink(url: URL) -> Bool {
        #if DEBUG
        print("[Sprich][Auth] handleDeepLink scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil") path=\(url.path) fragment-len=\(url.fragment?.count ?? 0)")
        #endif
        guard url.scheme?.lowercased() == "sprich" else { return false }
        guard let host = url.host?.lowercased(), host == "auth" else { return false }

        // Supabase implicit flow puts tokens in the URL fragment. Some
        // OS handlers preserve the fragment in `url.fragment`; if
        // Supabase ever switches a particular flow to query params,
        // fall back to the query string.
        let pairs = parseFragmentOrQuery(url: url)
        if let errCode = pairs["error"] ?? pairs["error_code"] {
            self.lastError = pairs["error_description"]?.removingPercentEncoding ?? errCode
            return true
        }
        guard let accessToken = pairs["access_token"],
              let refreshToken = pairs["refresh_token"] else {
            self.lastError = "Sign-in link did not include credentials. Please request a new link."
            return true
        }

        let expiresIn = Double(pairs["expires_in"] ?? "") ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        Task { await self.completeSignIn(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt) }
        return true
    }

    // MARK: - Sign out

    func signOut() {
        // Best-effort revoke on the server; we don't block on it.
        if let token = currentSession?.accessToken {
            Task {
                var req = URLRequest(url: SupabaseConfig.authBaseURL.appendingPathComponent("logout"))
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
                _ = try? await URLSession.shared.data(for: req)
            }
        }

        Self.clearKeychain()
        self.currentSession = nil
        self.lastError = nil
        TrialState.shared.handleSignOut()
        NotificationCenter.default.post(name: .sprichAuthStateChanged, object: nil)
    }

    // MARK: - Token access for downstream callers

    /// Returns a valid access token, refreshing if it's within 60 s of
    /// expiry. Throws if there's no session or refresh fails.
    func validAccessToken() async throws -> String {
        guard let session = currentSession else { throw AuthError.notSignedIn }
        if session.expiresAt.timeIntervalSinceNow > 60 {
            return session.accessToken
        }
        let refreshed = try await refresh(refreshToken: session.refreshToken)
        return refreshed.accessToken
    }

    // MARK: - Refresh

    @discardableResult
    func refresh(refreshToken: String) async throws -> Session {
        var components = URLComponents(url: SupabaseConfig.authBaseURL.appendingPathComponent("token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.requestFailed("Refresh failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let newRefresh = json["refresh_token"] as? String else {
            throw AuthError.requestFailed("Refresh response malformed")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let user = json["user"] as? [String: Any]
        let userID = (user?["id"] as? String) ?? currentSession?.userID ?? ""
        let userEmail = (user?["email"] as? String) ?? currentSession?.userEmail ?? ""

        let session = Session(
            accessToken: accessToken,
            refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userID: userID,
            userEmail: userEmail
        )
        Self.persist(session: session)
        self.currentSession = session
        return session
    }

    // MARK: - Internal: complete sign-in

    private func completeSignIn(accessToken: String, refreshToken: String, expiresAt: Date) async {
        // Decode the JWT to get userID + email without an extra round-trip.
        // (Supabase JWT payload always includes `sub` + `email`.)
        let (userID, userEmail) = decodeUser(fromAccessToken: accessToken) ?? ("", "")

        let session = Session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            userID: userID,
            userEmail: userEmail
        )
        Self.persist(session: session)
        self.currentSession = session
        self.lastError = nil

        #if DEBUG
        print("[Sprich][Auth] completeSignIn: session set (user=\(userEmail.isEmpty ? "?" : userEmail)); posting .sprichAuthStateChanged")
        #endif
        NotificationCenter.default.post(name: .sprichAuthStateChanged, object: nil)

        // Trial start happens server-side. Fire it now so the user lands
        // in a working trial without an extra UI step.
        await TrialState.shared.startOrFetchTrial()
    }

    // MARK: - Helpers

    private func parseFragmentOrQuery(url: URL) -> [String: String] {
        var result: [String: String] = [:]
        let candidates: [String?] = [url.fragment, url.query]
        for raw in candidates {
            guard let raw, !raw.isEmpty else { continue }
            for pair in raw.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let key = parts[0].removingPercentEncoding ?? parts[0]
                    let val = parts[1].removingPercentEncoding ?? parts[1]
                    result[key] = val
                }
            }
        }
        return result
    }

    private func decodeUser(fromAccessToken jwt: String) -> (id: String, email: String)? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload += "=" }
        let urlSafe = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: urlSafe),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let id = (json["sub"] as? String) ?? ""
        let email = (json["email"] as? String) ?? ""
        return (id, email)
    }

    private func isPlausibleEmail(_ s: String) -> Bool {
        guard s.count <= 254 else { return false }
        let parts = s.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return false }
        return true
    }

    // MARK: - Keychain persistence

    private static func loadFromKeychain() -> Session? {
        guard let access = KeychainManager.retrieve(key: KC.accessToken),
              let refresh = KeychainManager.retrieve(key: KC.refreshToken),
              let expiresStr = KeychainManager.retrieve(key: KC.expiresAt),
              let expiresInterval = TimeInterval(expiresStr) else {
            return nil
        }
        let userID = KeychainManager.retrieve(key: KC.userID) ?? ""
        let userEmail = KeychainManager.retrieve(key: KC.userEmail) ?? ""
        return Session(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date(timeIntervalSince1970: expiresInterval),
            userID: userID,
            userEmail: userEmail
        )
    }

    private static func persist(session: Session) {
        KeychainManager.store(key: KC.accessToken, value: session.accessToken)
        KeychainManager.store(key: KC.refreshToken, value: session.refreshToken)
        KeychainManager.store(key: KC.expiresAt, value: String(session.expiresAt.timeIntervalSince1970))
        KeychainManager.store(key: KC.userID, value: session.userID)
        KeychainManager.store(key: KC.userEmail, value: session.userEmail)
    }

    private static func clearKeychain() {
        // Only the session secrets (Supabase JWT + refresh + user metadata)
        // get wiped on sign-out. User-configured third-party API keys
        // (`sprich.api.*`) are deliberately preserved — they're local
        // configuration, not session-scoped data. This matches peers
        // (Cursor, Raycast, Aider) and means a user who signs out and
        // back in keeps their Groq/OpenAI/etc. keys intact.
        //
        // The threat we're explicitly accepting: on a SHARED macOS user
        // account with two different Sprich accounts, user B can inherit
        // user A's provider keys after A signs out. Out-of-scope for v1.0.6
        // because (a) macOS users have separate Keychains by default —
        // cross-OS-user inheritance is already prevented; (b) the
        // same-OS-user/different-Sprich-account scenario is rare on Mac.
        // If it becomes a real complaint, fix by tagging each provider
        // key with the setting-user's `user_id` rather than wiping.
        KeychainManager.delete(key: KC.accessToken)
        KeychainManager.delete(key: KC.refreshToken)
        KeychainManager.delete(key: KC.expiresAt)
        KeychainManager.delete(key: KC.userID)
        KeychainManager.delete(key: KC.userEmail)
    }
}

// MARK: - Models

extension AuthService {
    struct Session: Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userID: String
        let userEmail: String
    }

    /// Supabase OAuth provider identifiers. Must match the strings
    /// Supabase Auth recognises in the `provider=` query parameter.
    /// `azure` is Supabase's name for Microsoft (Azure AD / Entra ID).
    enum OAuthProvider: String, CaseIterable, Identifiable {
        case apple
        case google
        case azure

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .apple: return "Apple"
            case .google: return "Google"
            case .azure: return "Microsoft"
            }
        }
    }

    enum AuthError: Error {
        case notSignedIn
        case requestFailed(String)

        var message: String {
            switch self {
            case .notSignedIn: return "Not signed in."
            case .requestFailed(let s): return s
            }
        }
    }
}

extension Notification.Name {
    static let sprichAuthStateChanged = Notification.Name("sprich.auth.stateChanged")
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The framework calls this on the main thread, so we're already
        // main-actor-isolated in practice — but the protocol method is
        // declared `nonisolated`, so we need `assumeIsolated` to access
        // `@MainActor`-bound AppKit APIs without a dispatch hop.
        // (Earlier `DispatchQueue.main.sync` here was a self-deadlock —
        // syncing onto the queue you're already running on traps.)
        MainActor.assumeIsolated {
            NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? ASPresentationAnchor()
        }
    }
}
