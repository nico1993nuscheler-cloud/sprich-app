import Foundation
import ServiceManagement
import AppKit

/// Thin wrapper around `SMAppService.mainApp` for the "Launch at login"
/// Settings toggle (P1-PRD-16).
///
/// `isEnabled` is the source of truth — no separate `UserDefaults` flag.
/// macOS persists the registration in `~/Library/Application Support/...`
/// and surfaces it under System Settings → General → Login Items, so a
/// user who toggles it off externally is reflected on next read.
enum LaunchAtLoginManager {

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register / unregister at login. Throws if the system refuses — most
    /// common cause is the user denying the permission prompt that fires
    /// the very first time we register, in which case macOS sets the status
    /// to `.requiresApproval` and the caller should surface that in the UI.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// True when this process was started by launchd at login, rather than
    /// by the user clicking the app icon (Finder, Spotlight, Dock, etc.).
    ///
    /// User-driven launches dispatch a `kAEOpenApplication` Apple Event
    /// before `applicationDidFinishLaunching:` returns; launchd-spawned
    /// login items don't. Reading `currentAppleEvent` during launch gives
    /// us a reliable signal that AppKit doesn't expose more directly.
    static var wasLaunchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            // No Apple Event in flight = launchd started us headless.
            return true
        }
        return event.eventID != AEEventID(kAEOpenApplication)
    }
}
