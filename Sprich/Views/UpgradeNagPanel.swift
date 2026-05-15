import SwiftUI
import AppKit

// MARK: - Upgrade Nag Panel
//
// Day-5/6 in-app upgrade prompt (L3.3 / audit P0 #4 surface 3).
//
// Why an `NSPanel` and not a UNUserNotification:
//   - No notifications entitlement / no permission prompt to ask for
//   - No system-level nag-fatigue (the user's notification center is
//     a precious surface; we're a single-purpose app and shouldn't
//     compete with Calendar, Slack, Mail for that real estate)
//   - Native cream-pill styling matches the RecordingOverlay visual
//     language so it reads as an in-app affordance rather than an ad
//
// Visual cousin of `RecordingOverlay` — same cream + sprichBorder
// palette, same `.borderless` floating panel, same 0.12 s fade.
// Sized smaller (380 × ~110) and anchored under the menubar icon
// instead of bottom-centered.

@MainActor
final class UpgradeNagController {
    static let shared = UpgradeNagController()

    private var window: NSPanel?
    /// Auto-fade timer — kicks off on `show`, cancelled by any click,
    /// dismisses without snooze (passive dismissal is not consent).
    private var autoDismissTimer: Timer?

    private let panelWidth: CGFloat = 380
    private let panelHeight: CGFloat = 110
    private let autoFadeAfter: TimeInterval = 8

    private init() {}

    /// Show the nag, anchored under the menubar icon's status item.
    /// - Parameters:
    ///   - daysRemaining: integer days left in trial (drives title copy).
    ///   - statusItem: the app's `NSStatusItem` — we read its button's
    ///     window frame to anchor the panel just below the menubar icon.
    func show(daysRemaining: Int, anchorTo statusItem: NSStatusItem) {
        let view = UpgradeNagPanelView(
            daysRemaining: daysRemaining,
            onUpgrade: { [weak self] in self?.handleUpgrade() },
            onRemindLater: { [weak self] in self?.handleRemindLater() }
        )

        if window == nil {
            createWindow(rootView: view)
        } else {
            // Refresh root view so daysRemaining stays current if the
            // user already saw the panel earlier in the session.
            (window?.contentView as? NSHostingView<UpgradeNagPanelView>)?.rootView = view
        }

        positionWindow(anchorTo: statusItem)
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.window?.animator().alphaValue = 1
        }

        scheduleAutoDismiss()
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil

        let win = window
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            win?.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                win?.orderOut(nil)
            }
        })
    }

    // MARK: - Button handlers

    private func handleUpgrade() {
        if let url = URL(string: "https://sprichapp.com/pricing") {
            NSWorkspace.shared.open(url)
        }
        // One-and-done: a converting user shouldn't see the nag again.
        // We bump the fireCount to its hard cap (2) rather than writing
        // distantFuture into snoozedUntil — clearer intent on inspection.
        TrialState.shared.recordNagFired()
        dismiss()
    }

    private func handleRemindLater() {
        TrialState.shared.snoozeNag(by: 24 * 3600)
        dismiss()
    }

    // MARK: - Auto dismiss

    private func scheduleAutoDismiss() {
        autoDismissTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: autoFadeAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // Passive dismissal — no snooze write. Next launch may
                // re-fire (until fireCount hits 2). Intentional.
                self?.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDismissTimer = timer
    }

    // MARK: - Window plumbing

    private func createWindow(rootView: UpgradeNagPanelView) {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        panel.hidesOnDeactivate = false
        self.window = panel
    }

    /// Anchor the panel under the menubar icon. We read the status item's
    /// button window frame (top-of-screen in AppKit coords) and drop the
    /// panel 8 pt below it, right-edge-aligned with the icon. Fallback to
    /// the top-right of the main screen if the button window is missing.
    private func positionWindow(anchorTo statusItem: NSStatusItem) {
        guard let window = window else { return }

        let panelW = window.frame.width
        let panelH = window.frame.height
        let margin: CGFloat = 8

        if let buttonWindow = statusItem.button?.window {
            let buttonFrame = buttonWindow.frame
            // Right-align the panel's right edge with the menubar icon's
            // right edge so it visually drops from the click target.
            let x = buttonFrame.maxX - panelW
            let y = buttonFrame.minY - panelH - margin
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        // Fallback — top-right of main screen, menubar height baked in.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            let x = f.maxX - panelW - margin
            let y = f.maxY - panelH - margin
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

// MARK: - View

struct UpgradeNagPanelView: View {
    let daysRemaining: Int
    let onUpgrade: () -> Void
    let onRemindLater: () -> Void

    private var titleText: String {
        if daysRemaining <= 0 {
            return "Your trial ends today"
        } else if daysRemaining == 1 {
            return "Your trial ends in 1 day"
        } else {
            return "Your trial ends in \(daysRemaining) days"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Reuse the same forest rounded-square mark as RecordingOverlay
            // so the nag visually clusters with other Sprich surfaces.
            SprichAppIcon()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.sprichInk)
                Text("Lock in $59 lifetime — no subscription, ever.")
                    .font(.caption)
                    .foregroundColor(Color.sprichInk2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: onUpgrade) {
                        Text("Upgrade →")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(action: onRemindLater) {
                        Text("Remind me later")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.sprichCream)
                .shadow(color: Color.sprichInk.opacity(0.12), radius: 16, x: 0, y: 6)
                .shadow(color: Color.sprichInk.opacity(0.05), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.sprichBorder, lineWidth: 1)
        )
        .padding(4)  // breathing room so the shadow isn't clipped by the panel edge
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
