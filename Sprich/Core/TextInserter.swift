import Foundation
import AppKit
import CoreGraphics
import UserNotifications
import Carbon  // IsSecureEventInputEnabled

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

        // --- Preconditions for a reliable synthetic paste -----------------
        // CGEvent-based ⌘V has NO success callback — `post()` returns Void and
        // a blocked event is a silent no-op. So instead of pasting blind and
        // hoping, we verify the few conditions that are known to gate the
        // paste up front. If any fails we never synthesise the keystroke;
        // we leave the text on the clipboard and surface a visible, actionable
        // fallback so the dictation can never just disappear (the bug that
        // cost us our first customer: text shown in the HUD, never inserted,
        // zero feedback). See `deliverToClipboardWithFallback`.

        // 1. Accessibility. Without it, AXIsProcessTrusted() is false and the
        //    system silently drops our synthetic key events — exactly the
        //    guard HotkeyManager already enforces before listening. Mirror it
        //    here so the paste path can't silently no-op.
        guard Permissions.isAccessibilityGranted() else {
            #if DEBUG
            print("[Sprich] paste: Accessibility not granted — clipboard + visible fallback")
            #endif
            await deliverToClipboardWithFallback(safeText, reason: .accessibilityDenied, appName: targetAppName)
            return
        }

        // 2. Target re-activation. If the captured target is gone or won't come
        //    back to the front, do NOT paste blind into whatever is focused.
        let targetReady = await ensureTargetFrontmost(
            targetPid: targetPid,
            targetBundleID: targetBundleID
        )
        guard targetReady else {
            #if DEBUG
            print("[Sprich] paste: target not frontmost — clipboard + visible fallback")
            #endif
            await deliverToClipboardWithFallback(safeText, reason: .targetUnavailable, appName: targetAppName)
            return
        }

        // 3. Secure input. When any app has enabled EnableSecureEventInput
        //    (password fields, some terminals, 1Password, a screen-share, or
        //    an app that left it stuck on), the OS blocks ALL synthetic
        //    keystrokes — our ⌘V would vanish with no error. Detect it and
        //    fall back visibly instead.
        guard !IsSecureEventInputEnabled() else {
            #if DEBUG
            print("[Sprich] paste: secure event input active — clipboard + visible fallback")
            #endif
            await deliverToClipboardWithFallback(safeText, reason: .secureInput, appName: targetAppName)
            return
        }

        // All preconditions satisfied — proceed with the real paste.

        // 1. Save current clipboard contents for later restoration.
        let savedContents = savePasteboard(pasteboard)

        // 2. Set our text on the clipboard and remember the resulting
        //    changeCount so the delayed restore can detect — and refuse to
        //    clobber — a fresh user copy that lands during the paste window.
        pasteboard.clearContents()
        pasteboard.setString(safeText, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // 3. Small delay to ensure the pasteboard write is visible to the target.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // 4. Simulate Cmd+V keystroke
        simulatePaste()

        // 5. Brief settle so the synthetic ⌘V is delivered before we return.
        try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms

        // 6. Restore the user's clipboard only AFTER the target has had ample
        //    time to read our text. The previous code restored on a tight
        //    `defer` ~200ms after ⌘V — under load (Chromium/Electron, busy
        //    CPU) the target's pasteboard read routinely takes longer, so the
        //    restore won the race and ⌘V pasted the OLD/empty clipboard: the
        //    dictation silently vanished. Defer the restore to a detached task
        //    with a generous delay (~700ms more → ~850ms total post-paste),
        //    and skip it if the user copied something new in the meantime
        //    (changeCount moved) so we never clobber a fresh copy. The
        //    dictation also lives in HistoryStore, so it is never truly lost.
        let restoreDelay: UInt64 = 700_000_000  // 700ms
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: restoreDelay)
            let pb = NSPasteboard.general
            guard pb.changeCount == ourChangeCount else { return }
            restorePasteboard(pb, from: savedContents)
        }
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

    // MARK: - Visible fallback (never lose the dictation)

    /// Why we couldn't synthesise the paste. Each case maps to its own
    /// banner/notification copy so the user is told *what to do* next.
    enum PasteFallbackReason {
        /// Accessibility permission is off — synthetic key events are dropped.
        case accessibilityDenied
        /// The captured target app is gone / wouldn't re-activate.
        case targetUnavailable
        /// Secure event input is active — the OS blocks synthetic keystrokes.
        case secureInput
    }

    /// The dictation could not be pasted automatically. Put it on the
    /// clipboard (without the restore step — it must stay there, recoverable)
    /// and surface it **two** ways so it can never silently vanish:
    ///   1. An in-app toast (`HintBannerController`) — always visible, needs no
    ///      permission, shown even if notifications are muted/denied.
    ///   2. A system notification — survives if the user's eyes were elsewhere.
    /// The text also lives in `HistoryStore`, so it is recoverable regardless.
    private static func deliverToClipboardWithFallback(
        _ safeText: String,
        reason: PasteFallbackReason,
        appName: String?
    ) async {
        // Leave the transcription on the clipboard — no save/restore, so the
        // delayed restore can never clobber it.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(safeText, forType: .string)

        // 1. Always-visible in-app toast. This is the surface that fixes the
        //    "zero feedback" failure — it does not depend on notification
        //    authorization or on the user looking at Notification Center.
        await MainActor.run {
            HintBannerController.shared.present(
                message: bannerMessage(for: reason),
                systemImage: "doc.on.clipboard",
                dismissAfter: 6.0
            )
        }

        // 2. System notification (best-effort), fired WITHOUT awaiting. The
        //    toast above is the primary, always-visible surface; the
        //    notification is a bonus. `requestAuthorization` can block for
        //    many seconds on the first-run system permission prompt, and we
        //    must not stall the pipeline (status stuck in .processing, overlay
        //    spinning, no new dictation possible) waiting on it. Fire-and-forget.
        Task { await notifyCopiedToClipboard(reason: reason, appName: appName) }
    }

    /// One-line toast copy — must fit `HintToastView` (single line, ~320pt).
    private static func bannerMessage(for reason: PasteFallbackReason) -> String {
        switch reason {
        case .accessibilityDenied:
            return "Accessibility off — text copied, press ⌘V"
        case .targetUnavailable:
            return "Text copied to clipboard — press ⌘V"
        case .secureInput:
            return "Can’t paste here — text copied, press ⌘V"
        }
    }

    /// Post a user notification telling them the transcription is on the
    /// clipboard. Reuses the same `UNUserNotificationCenter` the app already
    /// uses for the missing-key banner. Best-effort: if notifications aren't
    /// authorized the in-app toast above still showed and the text is still on
    /// the clipboard, recoverable via ⌘V.
    private static func notifyCopiedToClipboard(reason: PasteFallbackReason, appName: String?) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let content = UNMutableNotificationContent()
        content.title = "Transcription copied to clipboard"
        switch reason {
        case .accessibilityDenied:
            content.body = "Sprich needs Accessibility to paste for you. Enable it in System Settings → Privacy & Security → Accessibility. Your text is on the clipboard — press ⌘V."
        case .secureInput:
            content.body = "This field blocks automatic paste (secure input). Your text is on the clipboard — press ⌘V where you want it."
        case .targetUnavailable:
            if let appName, !appName.isEmpty {
                content.body = "Couldn't switch back to \(appName). Press ⌘V where you want it."
            } else {
                content.body = "Press ⌘V where you want to paste it."
            }
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
