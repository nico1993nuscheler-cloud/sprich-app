import Foundation
import AppKit
import CoreGraphics
import UserNotifications

/// Inserts text into the currently focused text field by simulating Cmd+V paste.
/// Saves and restores the original clipboard contents.
enum TextInserter {

    /// Insert text into the captured target app's focused text field.
    /// Uses clipboard + Cmd+V simulation (same approach as Raycast, Alfred, TextExpander).
    ///
    /// Single choke-point for *all* paste paths (Literal / Formal / Custom) — input
    /// is run through `InputSanitizer.sanitizeForPaste` here so no caller can forget.
    ///
    /// `targetPid`/`targetBundleID`/`targetAppName` identify the app that was
    /// frontmost when the user started dictating (captured by
    /// `PipelineCoordinator`). During a long LLM wait the user may switch
    /// apps; before pasting we re-activate the captured target so the Cmd+V
    /// lands where they dictated. If the target is gone / can't be
    /// re-activated, we never paste blind into the wrong app — instead we
    /// leave the text on the clipboard and post a notification so the
    /// transcription is never silently lost. All params default to nil for
    /// the legacy "paste into frontmost" behavior (onboarding sample path).
    static func insert(
        _ text: String,
        targetPid: pid_t? = nil,
        targetBundleID: String? = nil,
        targetAppName: String? = nil
    ) async {
        let pasteboard = NSPasteboard.general

        // Defense-in-depth: strip control chars, NULL bytes, and Unicode bidi
        // overrides (Trojan Source, CVE-2021-42574). Whitespace is preserved.
        let safeText = InputSanitizer.sanitizeForPaste(text)

        // Ensure the captured target is frontmost before we synthesize Cmd+V.
        let targetReady = await ensureTargetFrontmost(
            targetPid: targetPid,
            targetBundleID: targetBundleID
        )

        guard targetReady else {
            // Target app is gone or wouldn't re-activate. Do NOT paste blind.
            // Leave the transcription on the clipboard (no restore) + notify.
            #if DEBUG
            print("[Sprich] paste: target not frontmost — clipboard + notification fallback")
            #endif
            pasteboard.clearContents()
            pasteboard.setString(safeText, forType: .string)
            await notifyCopiedToClipboard(appName: targetAppName)
            return
        }

        // 1. Save current clipboard contents
        let savedContents = savePasteboard(pasteboard)

        // Guarantee restoration even if anything below throws or is cancelled.
        defer {
            restorePasteboard(pasteboard, from: savedContents)
        }

        // 2. Set our text on the clipboard
        pasteboard.clearContents()
        pasteboard.setString(safeText, forType: .string)

        // 3. Small delay to ensure pasteboard is ready
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // 4. Simulate Cmd+V keystroke
        simulatePaste()

        // 5. Wait for target app to process the paste
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
    }

    // MARK: - Target re-activation

    /// Bring the captured target app to the front if it isn't already, so the
    /// synthetic Cmd+V lands where the user dictated. Returns `true` when the
    /// target is frontmost (or there is no captured target — the legacy
    /// "paste into frontmost" path). Returns `false` when the target is gone
    /// or refuses to activate within the timeout, signalling the caller to
    /// fall back to clipboard + notification.
    private static func ensureTargetFrontmost(
        targetPid: pid_t?,
        targetBundleID: String?
    ) async -> Bool {
        guard let targetPid else { return true }  // no target → legacy behavior

        let workspace = NSWorkspace.shared
        // Already frontmost (the common case — Sprich's panel is
        // non-activating, so focus normally stays on the target).
        if workspace.frontmostApplication?.processIdentifier == targetPid { return true }

        // Resolve the running app by PID, falling back to bundle ID in case
        // the PID was recycled (app relaunched during the wait).
        let running = NSRunningApplication(processIdentifier: targetPid)
            ?? targetBundleID.flatMap { bid in
                workspace.runningApplications.first { $0.bundleIdentifier == bid }
            }
        guard let running, !running.isTerminated else { return false }

        running.activate(options: [.activateIgnoringOtherApps])

        // Poll for the activation to take effect (up to ~500 ms).
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            if workspace.frontmostApplication?.processIdentifier == running.processIdentifier {
                return true
            }
        }
        return false
    }

    /// Post a user notification telling them the transcription is on the
    /// clipboard. Reuses the same `UNUserNotificationCenter` the app already
    /// uses for the missing-key banner. Best-effort: if notifications aren't
    /// authorized the text is still on the clipboard and recoverable via ⌘V.
    private static func notifyCopiedToClipboard(appName: String?) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let content = UNMutableNotificationContent()
        content.title = "Transcription copied to clipboard"
        if let appName, !appName.isEmpty {
            content.body = "Couldn't switch back to \(appName). Press ⌘V where you want it."
        } else {
            content.body = "Press ⌘V where you want to paste it."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "SprichPasteFallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    // MARK: - Private

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = 'V' on US keyboard layout
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        // Apps with aggressive IME (Slack, Discord, Word autocorrect, some Electron
        // surfaces) coalesce or drop zero-gap key events. 8 ms matches OW v1.7.1.
        usleep(8_000)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Save all pasteboard items for later restoration.
    private static func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var saved: [[NSPasteboard.PasteboardType: Data]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var itemData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData[type] = data
                }
            }
            saved.append(itemData)
        }

        return saved
    }

    /// Restore previously saved pasteboard contents.
    private static func restorePasteboard(
        _ pasteboard: NSPasteboard,
        from saved: [[NSPasteboard.PasteboardType: Data]]
    ) {
        pasteboard.clearContents()

        if saved.isEmpty { return }

        var items: [NSPasteboardItem] = []
        for itemData in saved {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            items.append(item)
        }

        pasteboard.writeObjects(items)
    }
}
