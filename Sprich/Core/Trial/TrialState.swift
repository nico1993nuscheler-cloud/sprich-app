import Foundation
import Combine
import AppKit

/// Server-tracked 7-day trial state with a 24-hour offline grace.
///
/// Authority is the server. The Mac app calls `start-trial` once, then
/// `validate-trial` at sign-in / app focus / on-demand. We cache the
/// server's view in `UserDefaults` and treat the cache as authoritative
/// for up to 24 h since `lastServerSync`. After that grace, the app
/// falls back to "needs reconnect" — recording is still allowed if the
/// last known state was active and we're inside the 24-h window;
/// otherwise the hard-lock view shows.
///
/// Hard-lock at expiry is enforced in two places:
///   1. `PipelineCoordinator.startRecording(mode:)` — refuses to record
///      and surfaces a blocking error pointing at the upgrade flow.
///   2. UI affordances (menubar header, optional modal) reflect the
///      same `entitlement` value.
@MainActor
final class TrialState: ObservableObject {
    static let shared = TrialState()

    // MARK: - Public observable state

    @Published private(set) var entitlement: Entitlement = .unknown
    @Published private(set) var trial: TrialSnapshot?
    @Published private(set) var hasLicense: Bool = false
    @Published private(set) var lastServerSync: Date?
    @Published private(set) var lastError: String?

    /// True if we're allowed to use the product right now.
    /// - Has license: always true.
    /// - Active trial: true.
    /// - Expired trial: false.
    /// - Unknown + offline within 24 h grace: true (best-effort).
    var isEntitled: Bool {
        switch entitlement {
        case .licensed, .trialActive: return true
        case .trialExpired, .signedOut, .deviceBlocked: return false
        case .unknown:
            // Grace path: if we have a cached active trial and are
            // still inside the 24-h offline window, allow.
            guard let trial, let lastServerSync else { return false }
            let withinGrace = Date().timeIntervalSince(lastServerSync) < (24 * 3600)
            let cachedlyActive = trial.expiresAt > Date() && trial.status == "active"
            return withinGrace && cachedlyActive
        }
    }

    /// Days remaining in the trial (0 if expired or no trial).
    var daysRemaining: Int {
        guard let trial else { return 0 }
        let seconds = trial.expiresAt.timeIntervalSinceNow
        guard seconds > 0 else { return 0 }
        return max(0, Int(ceil(seconds / 86_400)))
    }

    // MARK: - UserDefaults persistence

    private enum DefaultsKey {
        static let trialSnapshot = "sprich.trial.snapshot.v1"
        static let lastServerSync = "sprich.trial.lastServerSync.v1"
        static let hasLicense = "sprich.trial.hasLicense.v1"
    }

    private var refreshTimer: Timer?

    // MARK: - Init

    private init() {
        loadCache()
        recomputeEntitlement()
        scheduleBackgroundRefresh()
    }

    // MARK: - Lifecycle hooks

    /// Called by AppDelegate on launch and when the auth state flips.
    func bootstrapAfterLaunch() {
        if AuthService.shared.isSignedIn {
            Task { await self.validateNow() }
        } else {
            entitlement = .signedOut
        }
    }

    /// Called from AuthService.signOut().
    func handleSignOut() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.trialSnapshot)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.lastServerSync)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.hasLicense)
        trial = nil
        hasLicense = false
        lastServerSync = nil
        entitlement = .signedOut
    }

    // MARK: - Server interactions

    /// Starts the trial (idempotent — Edge Function returns existing one
    /// if already started). Called on first sign-in.
    func startOrFetchTrial() async {
        guard AuthService.shared.isSignedIn else { return }
        guard let fingerprint = DeviceFingerprint.currentHash() else {
            self.lastError = "Could not derive a device fingerprint. Trial cannot start."
            return
        }

        do {
            let token = try await AuthService.shared.validAccessToken()
            let url = SupabaseConfig.functionsBaseURL.appendingPathComponent("start-trial")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_fingerprint_hash": fingerprint
            ])

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                self.lastError = "Unexpected response from server."
                return
            }
            if http.statusCode == 409 {
                // Device already used by another account. This is a distinct
                // failure mode from "trial expired" — surface it as such so
                // the user sees "sign in with the original account" rather
                // than a misleading "trial ended, buy now" prompt.
                let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                self.lastError = (body["reason"] as? String)
                    ?? "This device is already linked to another Sprich account."
                self.entitlement = .deviceBlocked
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                self.lastError = "start-trial failed: HTTP \(http.statusCode)"
                return
            }

            // After start-trial we always do a fresh validate-trial to
            // get the canonical license + trial state in one shape.
            await validateNow()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Calls validate-trial and updates local state.
    func validateNow() async {
        guard AuthService.shared.isSignedIn else {
            self.entitlement = .signedOut
            return
        }
        do {
            let token = try await AuthService.shared.validAccessToken()
            let url = SupabaseConfig.functionsBaseURL.appendingPathComponent("validate-trial")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Network or server error. Don't clobber cached state —
                // the 24-h grace window in `isEntitled` covers the gap.
                self.lastError = "validate-trial failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.lastError = "validate-trial returned malformed JSON"
                return
            }

            // Trial.
            if let trialJSON = json["trial"] as? [String: Any],
               let startedAtStr = trialJSON["started_at"] as? String,
               let expiresAtStr = trialJSON["expires_at"] as? String,
               let status = trialJSON["status"] as? String,
               let startedAt = Self.iso8601(startedAtStr),
               let expiresAt = Self.iso8601(expiresAtStr) {
                self.trial = TrialSnapshot(
                    startedAt: startedAt,
                    expiresAt: expiresAt,
                    status: status
                )
            } else {
                self.trial = nil
            }

            // License.
            self.hasLicense = (json["license"] is [String: Any])

            self.lastServerSync = Date()
            self.lastError = nil
            persistCache()
            recomputeEntitlement()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Background refresh

    private func scheduleBackgroundRefresh() {
        // Refresh every 6 hours when the app is open + signed in.
        // App-focus refresh happens via the AppDelegate observer.
        let timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in
                guard AuthService.shared.isSignedIn else { return }
                await TrialState.shared.validateNow()
            }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer
    }

    // MARK: - Cache

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.trialSnapshot),
           let snapshot = try? JSONDecoder().decode(TrialSnapshot.self, from: data) {
            self.trial = snapshot
        }
        if let interval = UserDefaults.standard.object(forKey: DefaultsKey.lastServerSync) as? Double {
            self.lastServerSync = Date(timeIntervalSince1970: interval)
        }
        self.hasLicense = UserDefaults.standard.bool(forKey: DefaultsKey.hasLicense)
    }

    private func persistCache() {
        if let trial, let data = try? JSONEncoder().encode(trial) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.trialSnapshot)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.trialSnapshot)
        }
        if let lastServerSync {
            UserDefaults.standard.set(lastServerSync.timeIntervalSince1970, forKey: DefaultsKey.lastServerSync)
        }
        UserDefaults.standard.set(hasLicense, forKey: DefaultsKey.hasLicense)
    }

    private func recomputeEntitlement() {
        if !AuthService.shared.isSignedIn {
            entitlement = .signedOut
            return
        }
        if hasLicense {
            entitlement = .licensed
            return
        }
        if let trial {
            if trial.expiresAt > Date() && trial.status == "active" {
                entitlement = .trialActive
            } else {
                entitlement = .trialExpired
            }
            return
        }
        // Preserve a sticky .deviceBlocked across validate-trial responses
        // that don't carry a trial/license payload — start-trial set this
        // state for a reason and a no-data validate response shouldn't
        // silently downgrade it to .unknown ("syncing…").
        if entitlement == .deviceBlocked { return }
        entitlement = .unknown
    }

    // MARK: - Date parsing

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }()

    private static func iso8601(_ s: String) -> Date? {
        for f in isoFormatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Models

extension TrialState {
    enum Entitlement: Equatable {
        case unknown
        case signedOut
        case trialActive
        case trialExpired
        case licensed
        /// `start-trial` returned 409 device_already_used. The user is
        /// signed in but cannot record on this device under this account.
        /// Resolution: sign in with the account that first claimed this
        /// device, or contact support to release the fingerprint binding.
        case deviceBlocked
    }

    struct TrialSnapshot: Codable, Equatable {
        let startedAt: Date
        let expiresAt: Date
        let status: String
    }
}
