import SwiftUI
import AppKit
import UserNotifications
import Sparkle

extension Notification.Name {
    static let sprichOnboardingComplete = Notification.Name("sprich.onboardingComplete")
}

/// Custom-drawn two-color toggle track. Unlike `NSSwitch` (grey when "off"),
/// it's FILLED in BOTH positions so neither side reads as "disabled" — the
/// whole point: running on-device must never look like Sprich is turned off.
/// Green = On this Mac, Blue = Cloud. (Swap the two `NSColor`s below to
/// re-theme.) When not interactive it dims but keeps the active color.
@MainActor
final class ColorToggleTrack: NSView {
    // Match the established local/cloud coding used by the Network-status
    // card + menubar glyph (🟢 on-device / 🟡 cloud): green / amber.
    static let localColor = NSColor.systemGreen
    static let cloudColor = NSColor.systemOrange

    var isCloud = false { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        var color = isCloud ? Self.cloudColor : Self.localColor
        if dimmed { color = color.withAlphaComponent(0.4) }
        color.setFill()
        track.fill()

        let d = bounds.height - 4
        let x = isCloud ? bounds.width - d - 2 : 2
        let knob = NSBezierPath(ovalIn: NSRect(x: x, y: 2, width: d, height: d))
        (dimmed ? NSColor.white.withAlphaComponent(0.8) : NSColor.white).setFill()
        knob.fill()
    }
}

/// The menubar Local⇄Cloud quick switch (v1.0.13). A two-color toggle flanked
/// by "On this Mac" / "Cloud" labels, hosted as a menu item's custom view so
/// it's always visible. Left/green = On this Mac, right/blue = Cloud.
/// `onChange(isCloud)` fires on user flips.
@MainActor
final class ProcessingToggleView: NSView {
    private let localLabel = NSTextField(labelWithString: "On this Mac")
    private let cloudLabel = NSTextField(labelWithString: "Cloud")
    private let track = ColorToggleTrack()
    private var isInteractive = false
    var onChange: ((Bool) -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 226, height: 26))
        let font = NSFont.menuFont(ofSize: 0)
        localLabel.font = font
        cloudLabel.font = font
        localLabel.frame = NSRect(x: 14, y: 4, width: 84, height: 18)
        track.frame = NSRect(x: 104, y: 3, width: 42, height: 22)
        cloudLabel.frame = NSRect(x: 154, y: 4, width: 60, height: 18)
        addSubview(localLabel)
        addSubview(track)
        addSubview(cloudLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // NSMenu's tracking run loop doesn't reliably forward clicks to embedded
    // controls, so route ALL clicks on the row to `mouseDown`. Clicking
    // anywhere on the row flips the toggle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let newCloud = !track.isCloud
        track.isCloud = newCloud
        onChange?(newCloud)
    }

    /// Reflect the current mode + whether switching is allowed.
    func configure(isCloud: Bool, enabled: Bool, tooltip: String?) {
        isInteractive = enabled
        track.isCloud = isCloud
        track.dimmed = !enabled
        localLabel.textColor = isCloud ? .secondaryLabelColor : .labelColor
        cloudLabel.textColor = isCloud ? .labelColor : .secondaryLabelColor
        toolTip = tooltip
        localLabel.toolTip = tooltip
        cloudLabel.toolTip = tooltip
    }
}

@main
struct SprichApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    /// The Local⇄Cloud switch hosted in the menubar dropdown (tag-101 row).
    private var processingToggleView: ProcessingToggleView?
    /// Exposed so OnboardingView's "Try it now" step can install a
    /// transient `interceptOutput` closure that routes the test
    /// transcription back into the onboarding window.
    var pipeline: PipelineCoordinator!
    private var hotkeyManager: HotkeyManager!

    /// Sparkle auto-updater (v1.0.10). `startingUpdater: true` makes the
    /// first scheduled check fire ~SUScheduledCheckInterval after launch
    /// (86400 s in Info.plist) and re-arms daily. The menubar "Check for
    /// Updates…" row routes through `updaterController.checkForUpdates(_:)`
    /// for on-demand checks. Feed + EdDSA public key are wired via
    /// Info.plist (SUFeedURL, SUPublicEDKey); the private key lives only
    /// in macOS keychain.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// True when launchd started us as a Login Item (P1-PRD-16). Captured
    /// once at didFinishLaunching so any later check sees the same answer
    /// even after Apple Events arrive (e.g. a deep-link `sprich://` URL).
    private var launchedAsLoginItem: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Snapshot the login-item state before any further AppleEvent
        // processing can change `currentAppleEvent`. See P1-PRD-16.
        launchedAsLoginItem = LaunchAtLoginManager.wasLaunchedAsLoginItem

        // Hide from dock (belt + suspenders with LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        // Security: purge any legacy URLCache that may contain transcripts
        // or API keys from pre-ephemeral-session builds. `URLCache.shared`
        // is only touched by code that uses `URLSession.shared`; all our
        // URLSessions are ephemeral + no-cache, so this is belt-and-
        // suspenders — but cheap and right to do.
        URLCache.shared.removeAllCachedResponses()

        // IMPORTANT: we used to ALSO `removeItem(at: <Caches>/<bundleID>)`
        // to force-delete any legacy on-disk URL cache. That was disastrous:
        // Core ML stores its compiled-model cache under that same bundle
        // cache directory, so nuking the whole folder every launch caused
        // WhisperKit to recompile the 500 MB-class audio encoder from
        // scratch every single launch (the ~500 s "pre-warm" cost Nico
        // was hitting). SQLite even spammed `BUG IN CLIENT OF libsqlite3`
        // errors in Console because Core ML's `.db` was yanked out mid-use.
        //
        // The programmatic URLCache purge above is sufficient for the
        // legacy-cache concern; if some old build ever left a Cache.db on
        // disk it's inert now because our sessions don't use URLCache at
        // all. Do NOT reintroduce a blanket bundle-cache wipe without a
        // surgical alternative (only touch `Cache.db*`, leave Core ML
        // and WhisperKit's dirs alone).

        // P1-PRD-12 — drop entries older than 30 days. Cheap (single
        // DELETE in SwiftData), runs once per launch, keeps the History
        // store bounded without a background daemon.
        HistoryStore.shared.pruneOldEntries()

        // Initialize pipeline
        pipeline = PipelineCoordinator(appState: appState)

        // Route UN notification taps for the missing-API-key banner
        // (P1-UX-14) back to the deep-link handler. Set before any
        // notification posts so the very first one routes correctly.
        UNUserNotificationCenter.current().delegate = MissingKeyBannerDelegate.shared

        // Set up menu bar
        setupMenuBar()

        // Set up global hotkeys
        setupHotkeys()

        // First-launch onboarding. On repeat launches we deliberately do
        // NOT auto-prompt for Accessibility or auto-open Settings — both
        // are jarring on launch and the menubar status item ("Accessibility:
        // ❌ Not granted — click to fix") already surfaces a revoked grant.
        let hasOnboarded = UserDefaults.standard.bool(forKey: "sprich.hasCompletedOnboarding")
        if !hasOnboarded && !launchedAsLoginItem {
            // Headless login-item launches stay menubar-only — the
            // onboarding window will surface next time the user opens
            // the app from Finder, or via "Show welcome again" in
            // Diagnostics. (P1-PRD-16 Start-minimized.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showOnboardingWindow()
            }
        }

        // After onboarding finishes, we need to (re)start hotkeys — at initial
        // launch accessibility was not yet granted, so HotkeyManager.start()
        // bailed out. Restart now that permissions are (hopefully) in place.
        NotificationCenter.default.addObserver(
            forName: .sprichOnboardingComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleOnboardingComplete()
        }

        // Background-preload the on-device Whisper model when the user has
        // Local selected AND the model is already downloaded. We never
        // auto-download on launch — the ~626 MB is opt-in in Settings.
        prewarmLocalWhisperIfReady()

        // Sprint 2F follow-up — same idea for the local LLM. Without this,
        // the first Formal-mode dictation after install pays a 14–15 s
        // Metal-shader JIT compile (logged as `[Sprich][LocalLLM] prewarm ✅
        // in 14854 ms` in QA 2026-05-17). Cached afterwards by macOS, but
        // the first user impression matters. Only fires when `.local` is
        // already the active LLM provider AND the model is on disk — never
        // auto-downloads.
        LocalLLMService.prewarmIfReady(settings: appState.settings)

        // Auth + trial bootstrap. If a session is already in Keychain we
        // hit validate-trial in the background; if not, we show the
        // sign-in window (after onboarding for first-run, immediately
        // for repeat launches without a stored session).
        TrialState.shared.bootstrapAfterLaunch()
        observeAuthState()
        let onboarded = UserDefaults.standard.bool(forKey: "sprich.hasCompletedOnboarding")
        if !AuthService.shared.isSignedIn && onboarded && !launchedAsLoginItem {
            // Same reasoning as onboarding: a Mac restart shouldn't pop a
            // sign-in window in the user's face. The menubar account row
            // still surfaces the signed-out state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showSignInWindow()
            }
        }

        // App-foreground refresh of trial state.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard AuthService.shared.isSignedIn else { return }
                await TrialState.shared.validateNow()
                // After validate refreshes daysRemaining + entitlement,
                // re-check whether the day-5/6 upgrade nag should fire
                // (L3.3). Foreground is a natural trigger point — the
                // user just came back to the app and the trial state is
                // now authoritative.
                self?.maybeShowUpgradeNag()
            }
        }

        // Initial nag check after launch. Delayed so `bootstrapAfterLaunch`
        // → `validateNow` has had a chance to populate `daysRemaining` from
        // the server; otherwise we'd be reading the cached snapshot only,
        // which is fine but the foreground hook is a more reliable trigger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.maybeShowUpgradeNag()
        }
    }

    /// Shows the day-5/6 upgrade nag panel if `TrialState` says we should.
    /// Idempotent — `shouldShowUpgradeNag` enforces the snooze + hard cap.
    /// Anchors under the menubar icon via the `statusItem`.
    private func maybeShowUpgradeNag() {
        guard TrialState.shared.shouldShowUpgradeNag else { return }
        guard let statusItem = self.statusItem else { return }
        let days = TrialState.shared.daysRemaining
        UpgradeNagController.shared.show(daysRemaining: days, anchorTo: statusItem)
        TrialState.shared.recordNagFired()
    }

    /// Apple Events / kAEGetURL → custom URL scheme route.
    /// `sprich://auth/callback#access_token=…&refresh_token=…` is the
    /// magic-link handoff.
    func application(_ application: NSApplication, open urls: [URL]) {
        #if DEBUG
        print("[Sprich][DeepLink] application(_:open:) fired with \(urls.count) url(s)")
        for u in urls { print("[Sprich][DeepLink]   \(u.absoluteString)") }
        #endif
        for url in urls {
            let handled = AuthService.shared.handleDeepLink(url: url)
            #if DEBUG
            print("[Sprich][DeepLink] handler returned \(handled) for \(url.absoluteString)")
            #endif
            if handled {
                NSApp.activate(ignoringOtherApps: true)
                // `NSApp.activate` brings the process forward but doesn't
                // pick a specific window. After a magic-link round-trip
                // the user expects to land back in whichever sign-in
                // surface they came from. Raise the onboarding window
                // first (it owns step 0 → 1 advance), falling back to
                // the standalone sign-in window for repeat-sign-in flows.
                if let win = onboardingWindow {
                    win.makeKeyAndOrderFront(nil)
                } else if let win = signInWindow {
                    win.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    private func observeAuthState() {
        NotificationCenter.default.addObserver(
            forName: .sprichAuthStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            #if DEBUG
            print("[Sprich][AppDelegate] .sprichAuthStateChanged → isSignedIn=\(AuthService.shared.isSignedIn) onboardingOpen=\(self.onboardingWindow != nil) signInOpen=\(self.signInWindow != nil)")
            #endif

            // Live-refresh the menubar account row first. menuWillOpen
            // alone would leave a stale row visible if the menu happens
            // to be open during the transition. `TrialState.$entitlement`
            // covers trial-active / trial-expired / licensed transitions
            // via the Combine sink in `setupMenuBar`; this branch covers
            // sign-in / sign-out.
            self.refreshDynamicMenuItems()

            if AuthService.shared.isSignedIn {
                // Close any standalone sign-in window. The onboarding
                // window's own observer handles the step 0 → 1 advance.
                self.signInWindow?.close()
                self.signInWindow = nil

                // Post-sign-in landing: if this is a standalone
                // re-sign-in (no onboarding flow in progress), open
                // AccountView so the user lands on a meaningful surface
                // showing their fresh trial / license / device-blocked
                // state — rather than the menubar-only vacuum Nico hit
                // during real v1.0.4 testing on 2026-05-15.
                //
                // Onboarding has its own `.onChange(of: auth.isSignedIn)`
                // step advance (PR #22), so we skip the AccountView
                // open when onboardingWindow is non-nil — otherwise we'd
                // stack a second window on top of card 1+.
                //
                // 600 ms matches the onboarding auto-advance delay and
                // gives `TrialState.bootstrapAfterLaunch` /
                // `validateNow` a window to populate entitlement from
                // the server before AccountView reads it.
                if self.onboardingWindow == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self else { return }
                        guard AuthService.shared.isSignedIn else { return }
                        guard self.onboardingWindow == nil else { return }
                        self.showAccountWindow()
                    }
                }
            } else {
                // Signed-out: re-prompt with the standalone sign-in
                // window — but ONLY if the onboarding window isn't
                // already covering that surface (its step 0 already
                // shows SignInPanel). Otherwise we'd stack a second
                // sign-in window on top of onboarding card 0.
                guard self.onboardingWindow == nil else { return }
                self.showSignInWindow()
            }
        }
    }

    /// Kick off Core ML load of the local Whisper pipe in the background,
    /// so the first hotkey press doesn't pay the 10-30 s load cost.
    /// Only fires when Local is already the active provider — switching
    /// to Local mid-session triggers its own prewarm from SettingsView.
    private func prewarmLocalWhisperIfReady() {
        guard appState.settings.sttProvider.isLocal else { return }
        TranscriptionService.prewarmLocalWhisperIfReady(
            model: appState.settings.localWhisperModel
        )
    }

    private func handleOnboardingComplete() {
        onboardingWindow?.close()
        onboardingWindow = nil

        // Sprint 2C: sign-in is now the first card of onboarding, so
        // by the time we reach this handler the user is either signed
        // in or explicitly chose to skip. No standalone sign-in window
        // is shown post-onboarding — the menubar account row is the
        // re-entry point if they want to come back later.

        // Re-start hotkey manager now that Accessibility permission should exist.
        hotkeyManager?.stop()
        setupHotkeys()

        // If AXIsProcessTrusted is still false at this point, it means the user
        // either skipped granting, or macOS invalidated the grant (happens on
        // rebuild+reinstall because TCC keys off code identity). Tell them.
        if !Permissions.isAccessibilityGranted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let alert = NSAlert()
                alert.messageText = "Accessibility access not active"
                alert.informativeText = """
                Sprich still doesn't have Accessibility permission, so global shortcuts won't work.

                If you're updating from a previous build, remove the old Sprich entry under \
                System Settings → Privacy & Security → Accessibility, then add Sprich again \
                from /Applications. A relaunch of Sprich is usually required afterwards.
                """
                alert.addButton(withTitle: "Open Accessibility Settings")
                alert.addButton(withTitle: "Later")
                alert.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    Permissions.openAccessibilitySettings()
                }
            }
        }
    }

    private func showOnboardingWindow() {
        let hosting = NSHostingController(
            rootView: OnboardingView(pipeline: pipeline)
                .environmentObject(appState)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Sprich"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Keep a strong ref for the window's lifetime
        self.onboardingWindow = window
    }

    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var signInWindow: NSWindow?
    private var trialLockWindow: NSWindow?
    private var accountWindow: NSWindow?

    private func showSignInWindow() {
        if let win = signInWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SignInView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign in to Sprich"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.signInWindow = window
    }

    @MainActor
    func showTrialLockWindow() {
        if let win = trialLockWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: TrialLockView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Trial expired"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 280))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.trialLockWindow = window
    }

    /// Sprint 2E L1.4 — minimal AccountView for signed-in users.
    /// Routed to from `handleAccountClick` for `.trialActive` / `.licensed`
    /// / `.unknown` / `.deviceBlocked`. `.trialExpired` continues to land
    /// on `TrialLockView` (PR #17 wiring). `.signedOut` lands on
    /// `SignInView` (unchanged).
    @MainActor
    func showAccountWindow() {
        if let win = accountWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: AccountView(onSignOut: { [weak self] in
                self?.confirmAndSignOut()
            })
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sprich account"
        window.styleMask = [.titled, .closable]
        // `.deviceBlocked` body is taller (two recovery cards + support
        // footnote) so we size the window to its content; the standard
        // body uses its own `.frame(420×360)` inside the view and is
        // centered within the larger window when shown there.
        let isDeviceBlocked = TrialState.shared.entitlement == .deviceBlocked
        let size = isDeviceBlocked
            ? NSSize(width: 460, height: 460)
            : NSSize(width: 420, height: 360)
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.accountWindow = window
    }

    private func showShortcutHelpWindow() {
        if let win = helpWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: ShortcutHelpView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "How to use Sprich"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.helpWindow = window
    }

    @objc private func openShortcutHelp() {
        DispatchQueue.main.async { [weak self] in
            self?.showShortcutHelpWindow()
        }
    }

    private func showSettingsWindow() {
        // Reuse window if it's already around.
        if let win = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView()
                .environmentObject(appState)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sprich Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        // v1.0.11 testing — Settings sometimes "disappeared into the back"
        // when focus shifted to Chrome / Mail / Slack. For an .accessory
        // app, that's standard window-order behavior, but we want the
        // panel to stay alive so the menubar "Settings…" item can re-front
        // it without losing UI state. Explicit `hidesOnDeactivate = false`
        // pins that contract — NSWindow's own default for .titled windows
        // is already false, but we've been bitten before by a styleMask
        // change silently flipping it (panels default to true). Keep this
        // line if styleMask is ever edited.
        //
        // We deliberately do NOT set `.floating` here — clearly visible
        // wins, but it's intrusive when the user has moved Settings aside
        // to compare against another app. Revisit option #1 (.floating)
        // or option #3 (pin/unpin toggle) if reports of the panel still
        // vanishing land after v1.0.12.
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        updateMenuBarIcon(button: button)

        // Observe status changes to update icon
        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let button = self?.statusItem.button else { return }
                self?.updateMenuBarIcon(button: button)
            }
            .store(in: &appState.cancellables)

        let menu = NSMenu()

        // Status header (tag 100). Sprint 2E L1.5 — drop the "Sprich — "
        // prefix; the menubar context already identifies the app.
        let header = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        header.tag = 100
        menu.addItem(header)

        // Quick toggle (tag 101) — v1.0.13. A real on/off switch that flips
        // BOTH stt + llm between on-device ("On this Mac") and Cloud in one
        // move. The switch is greyed (but still visible) unless BOTH sides are
        // fully configured — local models downloaded AND a cloud API key
        // present. State is kept current by `updateProcessingToggleRow`
        // (route sink below + `refreshDynamicMenuItems`), so a freshly-
        // downloaded model or freshly-entered key enables it without relaunch.
        let toggleView = ProcessingToggleView()
        toggleView.onChange = { [weak self] isCloud in
            self?.setProcessing(toCloud: isCloud)
        }
        processingToggleView = toggleView
        let toggleRow = NSMenuItem()
        toggleRow.tag = 101
        toggleRow.view = toggleView
        menu.addItem(toggleRow)
        menu.addItem(NSMenuItem.separator())
        updateProcessingToggleRow()

        // Live-refresh the toggle when the selected providers change.
        NetworkStatusIndicator.shared.$route
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateProcessingToggleRow()
            }
            .store(in: &appState.cancellables)

        // Account row (tag 300) + sign-out (tag 301). Title + styling are
        // rebuilt live in `refreshDynamicMenuItems` to reflect auth +
        // trial state across all 5 entitlement cases.
        let accountItem = NSMenuItem(
            title: "Sign in to start trial…",
            action: #selector(handleAccountClick),
            keyEquivalent: ""
        )
        accountItem.tag = 300
        accountItem.target = self
        menu.addItem(accountItem)

        let signOutItem = NSMenuItem(
            title: "Sign out",
            action: #selector(handleSignOutClick),
            keyEquivalent: ""
        )
        signOutItem.tag = 301
        signOutItem.target = self
        menu.addItem(signOutItem)

        // Sprint 2E L1.3 — active-trial Upgrade row. Hidden in every
        // entitlement state except `.trialActive`. Visibility is
        // refreshed live by `refreshDynamicMenuItems` via the
        // `$entitlement`/`$trial` Combine sink set up below, so this
        // row appears/disappears without waiting for the next
        // `menuWillOpen`.
        let upgradeItem = NSMenuItem(
            title: "Upgrade to lifetime",
            action: #selector(handleUpgradeClick),
            keyEquivalent: ""
        )
        upgradeItem.tag = 302
        upgradeItem.target = self
        upgradeItem.image = NSImage(systemSymbolName: "cart.fill",
                                    accessibilityDescription: "Upgrade to lifetime")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
            )
        let upgradeBaseFont = NSFont.menuFont(ofSize: 0)
        let upgradeBoldFont = NSFontManager.shared
            .convert(upgradeBaseFont, toHaveTrait: .boldFontMask)
        upgradeItem.attributedTitle = NSAttributedString(
            string: "Upgrade to lifetime →",
            attributes: [
                .font: upgradeBoldFont,
                .foregroundColor: NSColor.controlAccentColor,
            ]
        )
        upgradeItem.isHidden = true
        menu.addItem(upgradeItem)

        menu.addItem(NSMenuItem.separator())

        // Accessibility action row — only visible when AX is not granted.
        // Click replays onboarding (card 2 walks the user through the
        // System Settings grant flow). Tag 200 row + tag 201 separator
        // are toggled together in `refreshDynamicMenuItems`.
        let axItem = NSMenuItem(
            title: "Finish setup — grant Accessibility",
            action: #selector(replayOnboarding),
            keyEquivalent: ""
        )
        axItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                               accessibilityDescription: "Accessibility permission required")
        axItem.tag = 200
        axItem.target = self
        menu.addItem(axItem)

        let axSep = NSMenuItem.separator()
        axSep.tag = 201
        menu.addItem(axSep)

        // Language submenu — mirrors `AppLanguages.all` so the menubar
        // surfaces every language the Settings picker does.
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let current = appState.settings.preferredLanguage
        for lang in AppLanguages.all {
            let item = NSMenuItem(
                title: lang.displayName,
                action: #selector(setLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.code
            item.state = (lang.code == current) ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(NSMenuItem.separator())

        // Shortcut cheat sheet — concrete name; the old "How to use
        // Sprich" framing read like a manual-table-of-contents.
        // (P1-UX-16, UX audit P0/P1 cleanup.)
        let helpItem = NSMenuItem(title: "Shortcut cheat sheet", action: #selector(openShortcutHelp), keyEquivalent: "")
        helpItem.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Shortcut cheat sheet")
        helpItem.target = self
        menu.addItem(helpItem)

        // Sparkle auto-update — manual "Check for Updates…" entry.
        // Routes through SPUStandardUpdaterController, which also runs
        // a scheduled check daily (SUScheduledCheckInterval = 86400).
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle",
                                   accessibilityDescription: "Check for updates")
        updateItem.target = self
        menu.addItem(updateItem)

        // Diagnostics submenu — recovery actions that are useful when
        // something's off but shouldn't clutter the main menu. P1-UX-16
        // renamed both items away from dev-tool wording flagged by the
        // UX audit (P0 #2 / P1 #5).
        let diagItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Diagnostics")
        let diagMenu = NSMenu()

        let restartItem = NSMenuItem(title: "Reconnect shortcut", action: #selector(restartHotkeys), keyEquivalent: "")
        restartItem.target = self
        diagMenu.addItem(restartItem)

        let replayItem = NSMenuItem(title: "Show welcome again", action: #selector(replayOnboarding), keyEquivalent: "")
        replayItem.target = self
        diagMenu.addItem(replayItem)

        let openAXItem = NSMenuItem(title: "Open Accessibility settings", action: #selector(openAXSettings), keyEquivalent: "")
        openAXItem.target = self
        diagMenu.addItem(openAXItem)

        diagItem.submenu = diagMenu
        menu.addItem(diagItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Sprich", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        menu.delegate = self

        // Auth-flip refresh of the account row is handled by the single
        // consolidated `.sprichAuthStateChanged` observer in
        // `observeAuthState()` — it calls `refreshDynamicMenuItems()`
        // alongside the window-routing logic so both responsibilities
        // stay in one place.
        //
        // Combine `$entitlement` with `$trial` so daysRemaining flips
        // (driven by the cached snapshot's expiresAt) also re-render
        // the row, not just entitlement transitions. Per PR #20: this
        // is what keeps the menu visibly flipping from "trial active"
        // → "lifetime" mid-menu after a LemonSqueezy purchase.
        TrialState.shared.$entitlement
            .combineLatest(TrialState.shared.$trial)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshDynamicMenuItems()
            }
            .store(in: &appState.cancellables)

        // Also watch pipe-ready changes so the header flips from
        // "Loading Whisper…" → "Ready" the moment WhisperKit finishes
        // warming, without waiting for the next status event.
        WhisperModelManager.shared.$isPipeReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuHeaderForCurrentStatus()
            }
            .store(in: &appState.cancellables)

        // Observe status to update menu header
        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let menuItem = self?.statusItem?.menu?.item(withTag: 100) else { return }
                switch status {
                case .ready:
                    // Differentiate between truly ready and "model
                    // bytes on disk but pipe still warming" — see
                    // WhisperModelManager.isPipeReady for the gap.
                    let provider = self?.appState.settings.sttProvider ?? .groq
                    if provider.isLocal && !WhisperModelManager.shared.isPipeReady {
                        menuItem.title = "Finishing setup…"
                    } else {
                        menuItem.title = "Ready"
                    }
                case .recording(let mode):
                    menuItem.title = "Recording — \(mode.displayName) mode"
                case .processing:
                    menuItem.title = "Cleaning up your text…"
                case .error(let msg):
                    menuItem.title = "Error — \(msg)"
                }
            }
            .store(in: &appState.cancellables)
    }

    private func updateMenuBarIcon(button: NSStatusBarButton) {
        // Use our custom template icon (tinted automatically by macOS).
        // For recording/processing/error states we fall back to SF Symbols
        // so the state is instantly recognizable.
        switch appState.status {
        case .ready:
            if let custom = NSImage(named: "MenuBarIcon") {
                custom.isTemplate = true
                button.image = custom
                button.image?.accessibilityDescription = "Sprich ready"
            } else {
                let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                button.image = NSImage(systemSymbolName: "waveform",
                                       accessibilityDescription: "Sprich ready")?
                    .withSymbolConfiguration(cfg)
            }
        case .recording:
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            let img = NSImage(systemSymbolName: "waveform.circle.fill",
                              accessibilityDescription: "Sprich recording")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
        case .processing:
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let img = NSImage(systemSymbolName: "ellipsis.circle",
                              accessibilityDescription: "Sprich processing")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
        case .error:
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let img = NSImage(systemSymbolName: "exclamationmark.triangle",
                              accessibilityDescription: "Sprich error")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
        }
    }

    private func setupHotkeys() {
        hotkeyManager = HotkeyManager { [weak self] mode in
            guard let self = self else { return }
            #if DEBUG
            print("[Sprich][Hotkey] ACTIVATE \(mode.displayName)")
            #endif
            Task { @MainActor in
                await self.pipeline.toggle(mode: mode)
            }
        } onRelease: { [weak self] in
            guard let self = self else { return }
            #if DEBUG
            print("[Sprich][Hotkey] RELEASE → calling stopAndProcess")
            #endif
            Task { @MainActor in
                await self.pipeline.stopAndProcess()
            }
        }
        hotkeyManager.isCustomModeAvailable = { [weak self] in
            self?.appState.settings.customModeEnabled ?? false
        }
        hotkeyManager.start()
    }

    /// Manual "Check for Updates…" entry point. Sparkle handles the rest
    /// (fetches appcast, verifies EdDSA signature, shows update dialog).
    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func openSettings() {
        // We manage our own settings window — SwiftUI's Settings scene is
        // unreliable for .accessory apps (sendAction bounces during NSStatusItem
        // menu teardown). Our own NSWindow works 100% of the time.
        DispatchQueue.main.async { [weak self] in
            self?.showSettingsWindow()
        }
    }

    @objc private func quitApp() {
        // Soft-shutdown sequence — see `gracefulShutdown(reason:)` for why.
        gracefulShutdown(reason: "menubar Quit")
    }

    /// Triggered when macOS asks us to terminate by any path other than our
    /// own menubar Quit — Cmd+Q from any window, Force Quit dialog, Apple
    /// menu "Quit Sprich", logout, system shutdown. We hook this so the
    /// graceful-shutdown sequence runs regardless of how the user quits.
    func applicationWillTerminate(_ notification: Notification) {
        // If `quitApp` already ran (menubar path), we've already unloaded.
        // Mark idempotent via a guard inside the helper.
        gracefulShutdownIfNeeded()
    }

    private var didStartGracefulShutdown = false

    /// Drop the local llama.cpp context BEFORE NSApp.terminate completes.
    /// QA 2026-05-18 hit a hard deadlock (rainbow wheel → Force Quit) when
    /// llama.cpp's Metal context tore down concurrently with AppKit's
    /// terminate flow. Letting the actor release the client first gives
    /// Metal a clean shutdown.
    ///
    /// Watchdog: if the soft-shutdown hasn't completed in 1.5 s, hard-exit
    /// via `exit(0)`. 1.5 s is well above the expected unload latency
    /// (~50 ms) but below a user's "is it stuck?" threshold. Worst case
    /// for the user: a slow Quit that completes cleanly. Best case: no
    /// hang at all.
    private func gracefulShutdown(reason: String) {
        guard !didStartGracefulShutdown else { return }
        didStartGracefulShutdown = true

        #if DEBUG
        print("[Sprich] gracefulShutdown via \(reason) — unloading local LLM")
        #endif

        hotkeyManager?.stop()

        let watchdog = DispatchWorkItem {
            #if DEBUG
            print("[Sprich] gracefulShutdown watchdog fired — hard exit")
            #endif
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: watchdog)

        Task { @MainActor in
            await LocalLLMService.shared.unload()
            watchdog.cancel()
            NSApp.terminate(nil)
        }
    }

    /// Called from `applicationWillTerminate` to cover the non-menubar
    /// quit paths. Idempotent against `quitApp`.
    private func gracefulShutdownIfNeeded() {
        guard !didStartGracefulShutdown else { return }
        // We're already inside the terminate flow — can't call
        // NSApp.terminate again. Just unload synchronously-ish and let
        // AppKit continue. Watchdog still applies in case llama.cpp's
        // deinit deadlocks.
        didStartGracefulShutdown = true
        let watchdog = DispatchWorkItem { exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: watchdog)
        Task { @MainActor in
            await LocalLLMService.shared.unload()
            watchdog.cancel()
        }
    }

    @objc private func handleAccountClick() {
        // Sprint 2E L1.4 — route signed-in users to the new minimal
        // AccountView instead of the old SignInView fallthrough that
        // confusingly read "Sign in to start your 7-day trial" for users
        // who were already signed in.
        if AuthService.shared.isSignedIn {
            switch TrialState.shared.entitlement {
            case .trialExpired:
                showTrialLockWindow()
            case .signedOut:
                // Defensive: AuthService says signed in but TrialState
                // hasn't caught up. Surface the sign-in window so the
                // user can recover from a bad-state local cache.
                showSignInWindow()
            case .trialActive, .licensed, .unknown, .deviceBlocked:
                showAccountWindow()
            }
        } else {
            showSignInWindow()
        }
    }

    @objc private func handleSignOutClick() {
        confirmAndSignOut()
    }

    /// Shared sign-out confirmation alert. Used by the menubar `Sign out`
    /// row and by `AccountView`'s sign-out button.
    @MainActor
    fileprivate func confirmAndSignOut() {
        guard AuthService.shared.isSignedIn else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of Sprich?"
        alert.informativeText = "Your trial state stays linked to your email — signing back in restores access."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign out")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AuthService.shared.signOut()
            accountWindow?.close()
            accountWindow = nil
        }
    }

    /// Sprint 2E L1.3 — opens the pricing page from the active-trial
    /// Upgrade menu row. Hidden in every other entitlement state.
    @objc private func handleUpgradeClick() {
        NSWorkspace.shared.open(URL(string: "https://sprichapp.com/pricing")!)
    }

    /// Unified language-switch handler for the menubar submenu.
    /// `representedObject` is the ISO 639-1 code (e.g. "de"), or `nil` for
    /// Auto-detect. Checkmarks are refreshed live by `menuWillOpen`.
    @objc private func setLanguageFromMenu(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String
        appState.settings.preferredLanguage = code
        appState.saveSettings()
    }

    /// Re-derive the menubar header title from the current app+pipe
    /// state. Called when pipe-ready flips without a status change.
    /// Sprint 2E L1.5 — copy normalized (no "Sprich — " prefix; proper
    /// ellipsis; em-dash separator).
    private func refreshMenuHeaderForCurrentStatus() {
        guard let menuItem = statusItem?.menu?.item(withTag: 100) else { return }
        switch appState.status {
        case .ready:
            let provider = appState.settings.sttProvider
            if provider.isLocal && !WhisperModelManager.shared.isPipeReady {
                menuItem.title = "Finishing setup…"
            } else {
                menuItem.title = "Ready"
            }
        case .recording(let mode):
            menuItem.title = "Recording — \(mode.displayName) mode"
        case .processing:
            menuItem.title = "Cleaning up your text…"
        case .error(let msg):
            menuItem.title = "Error — \(msg)"
        }
    }

    /// Clear the "onboarded" flag and show the onboarding window again.
    /// Useful for users who skipped a permission prompt, and for dev
    /// testing the fresh-install flow without a full `defaults delete`.
    @objc private func replayOnboarding() {
        UserDefaults.standard.removeObject(forKey: "sprich.hasCompletedOnboarding")
        DispatchQueue.main.async { [weak self] in
            self?.showOnboardingWindow()
        }
    }

    // MARK: - Accessibility recovery + diagnostics

    @objc private func openAXSettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func restartHotkeys() {
        hotkeyManager?.stop()
        setupHotkeys()

        // Post-check + feedback
        let granted = Permissions.isAccessibilityGranted()
        let alert = NSAlert()
        if granted {
            alert.messageText = "Hotkey listener restarted"
            alert.informativeText = "Accessibility is granted. Try pressing Fn + Shift and speaking."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Accessibility still not granted"
            alert.informativeText = "Grant Sprich Accessibility permission in System Settings first. After updates, you may need to remove and re-add Sprich in the list."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openAccessibilitySettings()
            }
            return
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate — keep dynamic rows live

extension AppDelegate: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshDynamicMenuItems()
        }
        // Kick off a fresh validate-trial. This is the primary
        // "did the user just upgrade?" refresh path for menubar-only
        // apps: `NSApplication.didBecomeActiveNotification` does NOT
        // fire when a `.accessory` app's status item is clicked, so
        // the foreground observer in `applicationDidFinishLaunching`
        // can't catch this transition on its own. The `$entitlement`
        // + `$trial` subscription in `setupMenuBar` re-renders the
        // account row when the response lands, so the menu flips live
        // if it's still open ~200–500 ms later, and is fresh next
        // time either way.
        Task { @MainActor in
            guard AuthService.shared.isSignedIn else { return }
            await TrialState.shared.validateNow()
        }
    }

    /// Refresh menu rows whose state depends on live app state —
    /// account row, AX recovery row visibility, and the Language
    /// submenu checkmarks. Called both from `menuWillOpen` and from
    /// `.sprichAuthStateChanged` / `TrialState.$entitlement` sinks so
    /// the menu stays correct even when it's already open.
    @MainActor
    fileprivate func refreshDynamicMenuItems() {
        guard let menu = statusItem?.menu else { return }

        // Accessibility recovery row + its trailing separator are
        // hidden entirely when AX is granted — the menu should only
        // surface problems, not "everything's fine" status lines.
        let axGranted = Permissions.isAccessibilityGranted()
        if let axItem = menu.item(withTag: 200) {
            axItem.isHidden = axGranted
        }
        if let axSep = menu.item(withTag: 201) {
            axSep.isHidden = axGranted
        }

        // Quick toggle (tag 101) — readiness can change while the menu is
        // closed (a model finishes downloading, an API key is entered), so
        // re-evaluate enabled-state + title on every open.
        updateProcessingToggleRow()

        // Account row — drives one of 5 entitlement states.
        if let acct = menu.item(withTag: 300), let signOut = menu.item(withTag: 301) {
            applyAccountRowState(account: acct, signOut: signOut)
        }

        // Sprint 2E L1.3 — Upgrade row visibility.
        // Visible whenever the user has an in-app path to buy that the
        // server will honor: active trial, expired trial, and the
        // device-fingerprint anti-abuse block (`.deviceBlocked`) — in
        // all three cases `redeem-license` attaches by email and frees
        // the user up. Hidden for `.licensed` (already owns it),
        // `.signedOut` (sign in first), and `.unknown` (let validateNow
        // settle before nudging — avoids a flashy CTA flicker on launch).
        if let upgrade = menu.item(withTag: 302) {
            let entitlement: TrialState.Entitlement =
                AuthService.shared.isSignedIn
                    ? TrialState.shared.entitlement
                    : .signedOut
            switch entitlement {
            case .trialActive, .trialExpired, .deviceBlocked:
                upgrade.isHidden = false
            case .licensed, .signedOut, .unknown:
                upgrade.isHidden = true
            }
        }

        // Language submenu checkmarks
        let current = appState.settings.preferredLanguage
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            for langItem in submenu.items {
                guard langItem.action == #selector(setLanguageFromMenu(_:)) else { continue }
                let code = langItem.representedObject as? String
                langItem.state = (code == current) ? .on : .off
            }
        }
    }

    // MARK: - Quick toggle (Local ⇄ Cloud)

    /// True when on-device dictation is fully usable: both the selected local
    /// Whisper model and the resolved local LLM model are downloaded.
    @MainActor
    private var isLocalFullyReady: Bool {
        let sttReady = WhisperModelManager.shared.existingFolder(for: appState.settings.localWhisperModel) != nil
        let llmReady = LLMModelManager.shared.existingFile(for: LocalLLMModelSpec.resolved(from: appState.settings)) != nil
        return sttReady && llmReady
    }

    /// First cloud STT provider that has an API key, in priority order.
    private func firstCloudSTTWithKey() -> STTProviderType? {
        [.groq, .openai, .deepgram].first { KeychainManager.retrieve(key: $0.keychainKey) != nil }
    }

    /// First cloud LLM provider that has an API key, in priority order
    /// (one Groq key satisfies both STT and LLM — same keychain entry).
    private func firstCloudLLMWithKey() -> LLMProviderType? {
        [.groq, .claude, .google, .openai].first { KeychainManager.retrieve(key: $0.keychainKey) != nil }
    }

    /// True when cloud dictation is fully usable: a cloud STT key AND a cloud
    /// LLM key are present.
    private var isCloudFullyReady: Bool {
        firstCloudSTTWithKey() != nil && firstCloudLLMWithKey() != nil
    }

    /// Reconfigure the toggle switch from the current providers + readiness.
    /// The switch shows ON = Cloud (both legs cloud), OFF = On this Mac, and
    /// is greyed unless BOTH local and cloud are fully configured.
    @MainActor
    fileprivate func updateProcessingToggleRow() {
        guard let view = processingToggleView else { return }
        let bothCloud = !appState.settings.sttProvider.isLocal && !appState.settings.llmProvider.isLocal
        let canToggle = isLocalFullyReady && isCloudFullyReady
        let tip: String
        if canToggle {
            tip = "Flip between running on your Mac and in the cloud — switches both transcription and cleanup."
        } else if !isCloudFullyReady {
            tip = "Add a cloud API key (Settings → AI Models) to switch to the cloud from here."
        } else {
            tip = "Download the on-device models (Settings → AI Models) to switch to your Mac from here."
        }
        view.configure(isCloud: bothCloud, enabled: canToggle, tooltip: tip)
    }

    /// Flip BOTH stt + llm between on-device and cloud. Reached only when the
    /// switch is enabled. `saveSettings()` refreshes `NetworkStatusIndicator`,
    /// whose route sink then reconfigures the switch.
    @MainActor
    private func setProcessing(toCloud: Bool) {
        guard isLocalFullyReady, isCloudFullyReady else {
            updateProcessingToggleRow()  // revert the switch if somehow flipped
            return
        }
        if toCloud {
            if let stt = firstCloudSTTWithKey() { appState.settings.sttProvider = stt }
            if let llm = firstCloudLLMWithKey() { appState.settings.llmProvider = llm }
        } else {
            appState.settings.sttProvider = .local
            appState.settings.llmProvider = .local
        }
        appState.saveSettings()

        // Switching to on-device must warm BOTH models, or the next dictation
        // hits "Sprich is still warming up". The Settings provider picker does
        // this in `selectLocalSTT`; the menubar toggle must too. Idempotent —
        // the `…IfReady` calls no-op when already warm or not downloaded.
        if !toCloud {
            WhisperModelManager.shared.refreshState(for: appState.settings.localWhisperModel)
            TranscriptionService.prewarmLocalWhisperIfReady(model: appState.settings.localWhisperModel)
            LocalLLMService.prewarmIfReady(settings: appState.settings)
        }
    }

    @MainActor
    private func applyAccountRowState(account: NSMenuItem, signOut: NSMenuItem) {
        let auth = AuthService.shared
        let trial = TrialState.shared
        let email = (auth.currentUserEmail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let entitlement: TrialState.Entitlement = auth.isSignedIn ? trial.entitlement : .signedOut

        switch entitlement {
        case .signedOut:
            let title = "Sign in to start your 7-day trial"
            let baseFont = NSFont.menuFont(ofSize: 0)
            let boldFont = NSFontManager.shared
                .convert(baseFont, toHaveTrait: .boldFontMask)
            account.attributedTitle = NSMutableAttributedString(
                string: title,
                attributes: [
                    .font: boldFont,
                    .foregroundColor: NSColor.controlAccentColor,
                ]
            )
            account.title = title
            account.image = NSImage(systemSymbolName: "sparkles",
                                    accessibilityDescription: "Sign in")?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
                )
            signOut.isHidden = true

        case .unknown:
            account.attributedTitle = nil
            account.title = email.isEmpty
                ? "Trial · syncing…"
                : "\(email)  ·  trial · syncing…"
            account.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                    accessibilityDescription: "Trial syncing")
            signOut.isHidden = email.isEmpty

        case .trialActive:
            account.attributedTitle = nil
            let days = trial.daysRemaining
            let dayLabel = days == 1 ? "1 day left" : "\(days) days left"
            account.title = "\(email)  ·  trial · \(dayLabel)"
            account.image = NSImage(systemSymbolName: "person.crop.circle.fill",
                                    accessibilityDescription: "Account")
            signOut.isHidden = false

        case .trialExpired:
            // Style the row to read like a CTA — bold accent — so it's
            // visually distinct from the inert "Sign out" beneath it.
            let title = "\(email)  ·  trial expired — buy"
            let baseFont = NSFont.menuFont(ofSize: 0)
            let boldFont = NSFontManager.shared
                .convert(baseFont, toHaveTrait: .boldFontMask)
            account.attributedTitle = NSMutableAttributedString(
                string: title,
                attributes: [
                    .font: boldFont,
                    .foregroundColor: NSColor.controlAccentColor,
                ]
            )
            account.title = title
            account.image = NSImage(systemSymbolName: "cart.fill",
                                    accessibilityDescription: "Buy license")?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
                )
            signOut.isHidden = false

        case .licensed:
            account.attributedTitle = nil
            account.title = "\(email)  ·  Sprich Lifetime"
            account.image = NSImage(systemSymbolName: "checkmark.seal.fill",
                                    accessibilityDescription: "Licensed")
            signOut.isHidden = false

        case .deviceBlocked:
            // This device's fingerprint is already attached to another
            // account. Tell the user clearly so they sign out and switch
            // to the right one — `handleAccountClick` routes this case
            // to SignInView (default branch) which surfaces sign-out.
            account.attributedTitle = nil
            account.title = email.isEmpty
                ? "Device linked to another account"
                : "\(email)  ·  device linked to another account"
            account.image = NSImage(systemSymbolName: "person.crop.circle.badge.exclamationmark",
                                    accessibilityDescription: "Device blocked")
            signOut.isHidden = false
        }
    }
}
