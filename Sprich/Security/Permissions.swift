import Foundation
import AppKit
import AVFoundation

/// Handles macOS permission checks and prompts.
enum Permissions {

    // MARK: - Accessibility

    /// Check if Accessibility permission is granted (required for global hotkeys + paste simulation).
    static func isAccessibilityGranted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt user to enable Accessibility permission.
    /// Opens System Settings directly to the Accessibility privacy pane.
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings to Accessibility pane.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Microphone

    /// Check current microphone authorization status.
    static func microphoneStatus() -> AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Request microphone permission. Returns true if granted.
    ///
    /// Sprich runs as a menubar agent (`LSUIElement`). When the very first
    /// microphone request fires from a global-hotkey dictation while another
    /// app is frontmost, the macOS TCC consent prompt can fail to surface —
    /// the user sees nothing, never answers, and because no TCC entry is
    /// created until the user answers a prompt, Sprich never even appears in
    /// System Settings → Privacy & Security → Microphone. (This is what the
    /// first paying customer hit.) Activating Sprich first makes the request
    /// come from the frontmost app, so the prompt is reliably presented and
    /// the TCC entry is created.
    static func requestMicrophone() async -> Bool {
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Whether microphone permission has been granted.
    static func isMicrophoneGranted() -> Bool {
        return microphoneStatus() == .authorized
    }

    /// True when the mic has been explicitly denied or restricted. macOS
    /// will NOT re-prompt in this state — `requestMicrophone()` returns
    /// false immediately — so the only recovery is sending the user to
    /// System Settings via `openMicrophoneSettings()`.
    static func microphoneNeedsSettingsRecovery() -> Bool {
        switch microphoneStatus() {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Open System Settings to the Microphone privacy pane. Unlike
    /// Accessibility (which has `openAccessibilitySettings()` + a Diagnostics
    /// entry), a denied mic had no in-app recovery affordance — once the
    /// user clicked "Don't Allow", macOS never re-prompts and there was no
    /// way back. This is that way back.
    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
