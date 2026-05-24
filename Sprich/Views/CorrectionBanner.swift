import SwiftUI
import AppKit

/// Tiny non-modal toast shown after `CorrectionLearner` auto-learns a
/// new replacement. Pure notification — no buttons. The replacement has
/// already been added to `glossaryReplacements` by the time we present
/// here; the toast exists purely so the user knows it happened. If they
/// don't want the learned pair, they remove it later in Settings →
/// Dictionary.
///
/// Lives in a borderless non-activating `NSPanel` so it never steals
/// focus from whatever app the user is typing in. Auto-dismisses after
/// 3 seconds. See P1-PRD-24.
@MainActor
final class CorrectionBannerController {

    static let shared = CorrectionBannerController()

    private var panel: NSPanel?
    private var autoDismissTimer: Timer?

    private init() {}

    /// Present the toast. A second call within the dismiss window
    /// supersedes the previous one (e.g. two corrections in quick
    /// succession show the most recent).
    func present(from: String, to: String) {
        dismiss()

        let view = CorrectionToastView(from: from, to: to)
        let hosting = NSHostingController(rootView: view)

        // Sized to content — wide enough for typical word pairs, short
        // enough to read as a peripheral notification.
        let size = NSSize(width: 260, height: 36)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        // Sprich is a non-activating menubar app. Without
        // `.canJoinAllSpaces` a panel created while another app is
        // frontmost stays behind that app's windows — created, but never
        // visible. `.stationary` keeps it pinned during Spaces transitions
        // and prevents it from being treated as a window for Mission
        // Control purposes. `.fullScreenAuxiliary` lets it appear over
        // apps in fullscreen.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // `.statusBar` level (not `.floating`) ensures the toast clears
        // foreground apps' floating panels too — same shelf as the
        // menubar itself, which is what we want for a non-interactive
        // notification.
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true   // strictly notification — no interaction
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView?.wantsLayer = true

        positionBottomRight(panel: panel, size: size)
        panel.orderFrontRegardless()
        self.panel = panel

        #if DEBUG
        // Read origin from panel.frame (already positioned) but log the
        // configured size — panel.frame.size can briefly report 0x0
        // before SwiftUI's hosting controller completes layout, which
        // is misleading despite the toast rendering correctly.
        let origin = panel.frame.origin
        print("[Sprich] CorrectionBanner: presented '\(from) → \(to)' at \(Int(origin.x)),\(Int(origin.y)) size \(Int(size.width))x\(Int(size.height)) visible=\(panel.isVisible)")
        #endif

        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
    }

    // MARK: - Positioning

    /// Bottom-right of the screen the frontmost app's window is on.
    /// Falls back to `NSScreen.main` if we can't find a foreground frame.
    private func positionBottomRight(panel: NSPanel, size: NSSize) {
        let screen = screenForFrontmostApp() ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: frame.maxX - size.width - margin,
            y: frame.minY + margin
        )
        panel.setFrameOrigin(origin)
    }

    private func screenForFrontmostApp() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return NSScreen.main
        }
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in info {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            // CGWindow coords are top-left origin; NSScreen is bottom-left.
            let center = NSPoint(x: x + w / 2, y: y + h / 2)
            for screen in NSScreen.screens {
                let f = screen.frame
                let flippedY = NSScreen.screens.first.map { $0.frame.maxY - center.y } ?? center.y
                if f.contains(NSPoint(x: center.x, y: flippedY)) { return screen }
            }
        }
        return NSScreen.main
    }
}

private struct CorrectionToastView: View {
    let from: String
    let to: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.blue)
                .font(.system(size: 12))
            Text("Learned")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(from)
                    .foregroundColor(.secondary)
                    .strikethrough()
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(to)
                    .fontWeight(.medium)
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 0.5)
        )
    }
}
