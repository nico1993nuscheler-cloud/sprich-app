import Foundation

/// Supabase project coordinates for the Sprich Mac app.
///
/// The publishable key is intentionally embedded in the binary — it's the
/// modern equivalent of the anon key and is designed to be public. Server
/// authority lives in RLS policies + Edge Function service-role calls,
/// not in keeping this string secret.
enum SupabaseConfig {
    /// `sprich-prod` project ref (eu-central-1, Frankfurt).
    static let projectURL = URL(string: "https://djiixtplbsutuiuxfhiy.supabase.co")!

    /// Modern publishable key (`sb_publishable_…`). Rotatable independently of
    /// the legacy JWT anon. Fetched 2026-05-04 via Supabase MCP
    /// `get_publishable_keys`. Rotate via Supabase dashboard → Settings →
    /// API; replace this constant when rotated.
    static let publishableKey = "sb_publishable_uM-K5KnQmXhD12C6iU3KLg_X6E_ddSj"

    /// Custom URL scheme registered in Info.plist. The magic-link redirect
    /// target — Supabase appends the access/refresh tokens to the fragment.
    static let authCallbackURL = "sprich://auth/callback"

    static var authBaseURL: URL { projectURL.appendingPathComponent("auth/v1") }
    static var functionsBaseURL: URL { projectURL.appendingPathComponent("functions/v1") }
}
