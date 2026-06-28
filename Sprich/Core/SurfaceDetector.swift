import Foundation
import AppKit
import CoreServices  // AEDeterminePermissionToAutomateTarget, typeWildCard

/// Detects the destination Surface (email / slack / chat / docs / …) the
/// user is dictating into, from the frontmost application at hotkey time.
///
/// Called in two phases:
///   1. `captureFrontmostBundleID()` — cheap synchronous read at hotkey
///      press, before Sprich's HUD could steal focus.
///   2. `resolveSurface(bundleID:)` — async, may launch AppleScript for
///      browsers to read the active tab URL. Runs in parallel with STT so
///      its latency is hidden.
enum SurfaceDetector {

    /// Snapshot the frontmost app's bundle identifier.
    /// `NSWorkspace.shared.frontmostApplication` stays accurate because
    /// Sprich is a non-activating accessory app — its hotkey doesn't
    /// switch focus.
    static func captureFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Resolved surface + (for browsers) the URL host that produced it.
    /// History uses `webHost` to render brand-specific labels
    /// ("Google Chrome — Gmail"); LLM tone routing only consumes `surface`.
    struct Resolved {
        let surface: Surface
        /// Lowercased URL host from the active browser tab — present only
        /// when the browser AppleScript read succeeded. `nil` for native
        /// apps, unsupported browsers, denied Automation TCC, or any read
        /// failure.
        let webHost: String?

        static let generic = Resolved(surface: .generic, webHost: nil)
    }

    /// Resolve the captured bundle ID (plus, for browsers, the active tab
    /// URL) to a `Surface` + URL host. Never throws — any failure returns
    /// `.generic` with `webHost == nil` so today's Formal-mode behavior is
    /// preserved as a safe fallback.
    static func resolve(bundleID: String?) async -> Resolved {
        guard let bundleID = bundleID else { return .generic }

        if let native = SurfaceMapping.fromNativeBundleID(bundleID) {
            return Resolved(surface: native, webHost: nil)
        }

        // Browsers need an AppleScript tab read. CRITICAL: only attempt it when
        // Automation permission for this browser is ALREADY granted. Triggering
        // the TCC Automation prompt mid-dictation gates CGEvent dispatch
        // system-wide — i.e. it silently blocks the ⌘V paste that delivers the
        // transcription (the first-customer bug). `automationAlreadyGranted`
        // queries the permission WITHOUT prompting (askUserIfNeeded: false), so
        // for undetermined/denied users we simply degrade to `.generic` — the
        // exact same safe fallback as a failed read — and the paste is never
        // put at risk. Users who have granted Automation still get the
        // destination-aware enrichment.
        if SurfaceMapping.isAppleScriptBrowser(bundleID),
           automationAlreadyGranted(forBundleID: bundleID),
           let urlString = await readActiveTabURL(browserBundleID: bundleID) {
            let host = URL(string: urlString)?.host?.lowercased()
            let surface = SurfaceMapping.fromURL(urlString) ?? .generic
            return Resolved(surface: surface, webHost: host)
        }

        return .generic
    }

    /// Whether Sprich is *already* allowed to send Apple Events to `bundleID`,
    /// determined WITHOUT showing the TCC Automation prompt
    /// (`askUserIfNeeded: false`). Returns `true` only for an explicit grant;
    /// undetermined ("would prompt"), denied, or target-not-running all return
    /// `false`. This is what keeps surface detection from ever triggering the
    /// permission dialog that would gate the paste.
    private static func automationAlreadyGranted(forBundleID bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = target.aeDesc else { return false }
        // typeWildCard / typeWildCard = "any event" — we only care whether
        // automation is permitted at all, not about a specific event.
        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc, typeWildCard, typeWildCard, false
        )
        return status == noErr
    }

    /// Back-compat wrapper for callers that only need the `Surface`
    /// (no history labelling). Prefer `resolve(bundleID:)` for new callers.
    static func resolveSurface(bundleID: String?) async -> Surface {
        await resolve(bundleID: bundleID).surface
    }

    // MARK: - AppleScript browser tab reads

    /// Ask a browser (via AppleScript) for the URL of its frontmost tab.
    /// Returns `nil` on any failure — denied TCC permission, scripting
    /// not supported, browser not running, timeout.
    ///
    /// On failure a one-line diagnostic is logged so a user testing the
    /// destination-aware Formal mode can tell apart "TCC permission denied
    /// for Sprich → <Browser>" from "host not in the mapping table".
    private static func readActiveTabURL(browserBundleID: String) async -> String? {
        let script = appleScriptForBrowser(bundleID: browserBundleID)
        guard let script = script else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> String? in
            var errorInfo: NSDictionary?
            guard let nsScript = NSAppleScript(source: script) else { return nil }
            let descriptor = nsScript.executeAndReturnError(&errorInfo)
            if let errorInfo {
                #if DEBUG
                let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                let msg  = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "?"
                print("[Sprich][Surface] AppleScript tab-URL read failed for \(browserBundleID) — code=\(code) msg=\(msg) (likely TCC denied; grant Sprich → \(browserBundleID) in System Settings → Privacy & Security → Automation)")
                #endif
                return nil
            }
            let raw = descriptor.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }.value
    }

    /// AppleScript source per browser. Chromium-family browsers all share
    /// the same "active tab of front window" dialect; Safari uses a
    /// different one; unsupported browsers return nil.
    private static func appleScriptForBrowser(bundleID: String) -> String? {
        switch bundleID {
        case "com.google.Chrome":
            return #"tell application "Google Chrome" to get URL of active tab of front window"#
        case "com.google.Chrome.canary":
            return #"tell application "Google Chrome Canary" to get URL of active tab of front window"#
        case "company.thebrowser.Browser":
            return #"tell application "Arc" to get URL of active tab of front window"#
        case "com.microsoft.edgemac":
            return #"tell application "Microsoft Edge" to get URL of active tab of front window"#
        case "com.brave.Browser":
            return #"tell application "Brave Browser" to get URL of active tab of front window"#
        case "com.vivaldi.Vivaldi":
            return #"tell application "Vivaldi" to get URL of active tab of front window"#
        case "com.apple.Safari":
            return #"tell application "Safari" to get URL of front document"#
        default:
            return nil
        }
    }
}
