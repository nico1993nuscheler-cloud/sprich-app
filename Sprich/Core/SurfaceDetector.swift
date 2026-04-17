import Foundation
import AppKit

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

    /// Resolve the captured bundle ID (plus, for browsers, the active tab
    /// URL) to a `Surface`. Never throws — any failure returns `.generic`
    /// so today's formal-mode behavior is preserved as a safe fallback.
    static func resolveSurface(bundleID: String?) async -> Surface {
        guard let bundleID = bundleID else { return .generic }

        if let native = SurfaceMapping.fromNativeBundleID(bundleID) {
            return native
        }

        if SurfaceMapping.isAppleScriptBrowser(bundleID) {
            if let urlString = await readActiveTabURL(browserBundleID: bundleID),
               let surface = SurfaceMapping.fromURL(urlString) {
                return surface
            }
        }

        return .generic
    }

    // MARK: - AppleScript browser tab reads

    /// Ask a browser (via AppleScript) for the URL of its frontmost tab.
    /// Returns `nil` on any failure — denied TCC permission, scripting
    /// not supported, browser not running, timeout.
    private static func readActiveTabURL(browserBundleID: String) async -> String? {
        let script = appleScriptForBrowser(bundleID: browserBundleID)
        guard let script = script else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> String? in
            var errorInfo: NSDictionary?
            guard let nsScript = NSAppleScript(source: script) else { return nil }
            let descriptor = nsScript.executeAndReturnError(&errorInfo)
            if errorInfo != nil { return nil }
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
