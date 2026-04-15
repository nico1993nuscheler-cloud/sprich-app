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
    static func requestMicrophone() async -> Bool {
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Whether microphone permission has been granted.
    static func isMicrophoneGranted() -> Bool {
        return microphoneStatus() == .authorized
    }
}
