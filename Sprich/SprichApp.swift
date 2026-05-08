import SwiftUI
import AppKit

extension Notification.Name {
    static let sprichOnboardingComplete = Notification.Name("sprich.onboardingComplete")
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
    /// Exposed so OnboardingView's "Try it now" step can install a
    /// transient `interceptOutput` closure that routes the test
    /// transcription back into the onboarding window.
    var pipeline: PipelineCoordinator!
    private var hotkeyManager: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Initialize pipeline
        pipeline = PipelineCoordinator(appState: appState)

        // Set up menu bar
        setupMenuBar()

        // Set up global hotkeys
        setupHotkeys()

        // First-launch onboarding: show before permission/settings prompts.
        let hasOnboarded = UserDefaults.standard.bool(forKey: "sprich.hasCompletedOnboarding")
        if !hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showOnboardingWindow()
            }
        } else {
            checkPermissions()
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

        // Auth + trial bootstrap. If a session is already in Keychain we
        // hit validate-trial in the background; if not, we show the
        // sign-in window (after onboarding for first-run, immediately
        // for repeat launches without a stored session).
        TrialState.shared.bootstrapAfterLaunch()
        observeAuthState()
        let onboarded = UserDefaults.standard.bool(forKey: "sprich.hasCompletedOnboarding")
        if !AuthService.shared.isSignedIn && onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.showSignInWindow()
            }
        }

        // App-foreground refresh of trial state.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard AuthService.shared.isSignedIn else { return }
                await TrialState.shared.validateNow()
            }
        }
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
            // Close sign-in window on successful sign-in.
            if AuthService.shared.isSignedIn {
                self.signInWindow?.close()
                self.signInWindow = nil
            } else {
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

        checkPermissions()
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
        window.title = "Sprich — Trial expired"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 280))
        window.center()
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.trialLockWindow = window
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
        window.collectionBehavior = [.fullScreenAuxiliary]

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

        // Status header
        let statusItem = NSMenuItem(title: "Sprich — Ready", action: nil, keyEquivalent: "")
        statusItem.tag = 100
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())

        // Account section — placed near the top for visibility. Title +
        // styling are rebuilt live in `menuWillOpen` to reflect current
        // sign-in state + trial countdown. When signed out, the row is
        // styled bold with a sparkles icon to draw the user toward the
        // sign-in flow.
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

        menu.addItem(NSMenuItem.separator())

        // Mode indicators
        let literalItem = NSMenuItem(title: "Literal (Fn+Shift)", action: nil, keyEquivalent: "")
        literalItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Literal mode")
        menu.addItem(literalItem)

        let formalItem = NSMenuItem(title: "Formal (Fn+Control)", action: nil, keyEquivalent: "")
        formalItem.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Formal mode")
        menu.addItem(formalItem)

        menu.addItem(NSMenuItem.separator())

        // Language submenu — mirrors `AppLanguages.all` so the menubar
        // surfaces every language the Settings picker does. Previous
        // version hard-coded Auto / Deutsch / English and drifted out
        // of sync when the 15-language dropdown shipped in 4e1dc68.
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let current = appState.settings.preferredLanguage
        for lang in AppLanguages.all {
            let title = lang.displayName
            let item = NSMenuItem(
                title: title,
                action: #selector(setLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            // Use `representedObject` to carry the ISO code (or nil for
            // auto-detect) through AppKit's single-selector action API.
            item.representedObject = lang.code
            item.state = (lang.code == current) ? .on : .off
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(NSMenuItem.separator())

        // Accessibility diagnostic — updated live on menu open via NSMenuDelegate
        let axItem = NSMenuItem(
            title: "Accessibility: …",
            action: #selector(handleAccessibilityMenuClick),
            keyEquivalent: ""
        )
        axItem.tag = 200
        axItem.target = self
        menu.addItem(axItem)

        // Restart hotkey listener — useful after granting permission
        let restartItem = NSMenuItem(
            title: "Restart Hotkey Listener",
            action: #selector(restartHotkeys),
            keyEquivalent: ""
        )
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(NSMenuItem.separator())

        // How to use Sprich — shortcut cheat-sheet
        let helpItem = NSMenuItem(title: "How to use Sprich", action: #selector(openShortcutHelp), keyEquivalent: "")
        helpItem.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "How to use Sprich")
        helpItem.target = self
        menu.addItem(helpItem)

        // Run onboarding again — useful for users who skipped it or
        // missed a permission prompt, and for dev testing of the
        // fresh-install flow without wiping UserDefaults.
        let onboardItem = NSMenuItem(
            title: "Run First-Time Setup…",
            action: #selector(replayOnboarding),
            keyEquivalent: ""
        )
        onboardItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Run first-time setup")
        onboardItem.target = self
        menu.addItem(onboardItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Sprich", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
        menu.delegate = self

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
                        menuItem.title = "Sprich — Loading Whisper…"
                    } else {
                        menuItem.title = "Sprich — Ready"
                    }
                case .recording(let mode):
                    menuItem.title = "Sprich — Recording (\(mode.displayName))..."
                case .processing:
                    menuItem.title = "Sprich — Processing..."
                case .error(let msg):
                    menuItem.title = "Sprich — Error: \(msg)"
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

    private func checkPermissions() {
        // Check accessibility
        if !Permissions.isAccessibilityGranted() {
            // Show a brief notification — onboarding will guide them
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Permissions.promptAccessibility()
            }
        }

        // Microphone permission is requested when first recording starts

        // Check if API keys are configured
        if !appState.settings.hasRequiredAPIKeys {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.openSettings()
            }
        }
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
        hotkeyManager?.stop()
        NSApp.terminate(nil)
    }

    @objc private func handleAccountClick() {
        if AuthService.shared.isSignedIn {
            // Already signed in — surface trial state. If expired, show
            // the buy modal; otherwise show the sign-in window so the
            // user can see the current account address (and sign out).
            switch TrialState.shared.entitlement {
            case .trialExpired:
                showTrialLockWindow()
            default:
                showSignInWindow()
            }
        } else {
            showSignInWindow()
        }
    }

    @objc private func handleSignOutClick() {
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
        }
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
    private func refreshMenuHeaderForCurrentStatus() {
        guard let menuItem = statusItem?.menu?.item(withTag: 100) else { return }
        switch appState.status {
        case .ready:
            let provider = appState.settings.sttProvider
            if provider.isLocal && !WhisperModelManager.shared.isPipeReady {
                menuItem.title = "Sprich — Loading Whisper…"
            } else {
                menuItem.title = "Sprich — Ready"
            }
        case .recording(let mode):
            menuItem.title = "Sprich — Recording (\(mode.displayName))..."
        case .processing:
            menuItem.title = "Sprich — Processing..."
        case .error(let msg):
            menuItem.title = "Sprich — Error: \(msg)"
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

    // MARK: - Accessibility diagnostic + restart

    @objc private func handleAccessibilityMenuClick() {
        if Permissions.isAccessibilityGranted() {
            // If it's granted but hotkeys aren't working, offer a restart.
            restartHotkeys()
        } else {
            // Not granted — guide user to settings.
            let alert = NSAlert()
            alert.messageText = "Accessibility permission required"
            alert.informativeText = """
            Sprich needs Accessibility access to listen for your global shortcut.

            Go to System Settings → Privacy & Security → Accessibility, enable Sprich, then click "Restart Hotkey Listener" from this menu.

            If Sprich is already in the list but the toggle is on, remove it with the minus button and re-add it from /Applications. This is needed after app updates because macOS invalidates the grant when the code signature changes.
            """
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                Permissions.openAccessibilitySettings()
            }
        }
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

// MARK: - NSMenuDelegate — keep the accessibility item live

extension AppDelegate: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // Called just before the status menu appears. Refresh any items
        // whose state depends on live app state: accessibility grant,
        // and the Language submenu checkmarks.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let axItem = menu.item(withTag: 200) {
                let granted = Permissions.isAccessibilityGranted()
                axItem.title = granted
                    ? "Accessibility: ✅ Granted"
                    : "Accessibility: ❌ Not granted — click to fix"
            }

            // Account / Sign-out labels reflect live auth + trial state.
            // When signed-out, the row is styled bold + accent-colored
            // with a sparkles icon so it stands out as the primary call
            // to action in the menubar.
            if let acct = menu.item(withTag: 300), let signOut = menu.item(withTag: 301) {
                let auth = AuthService.shared
                let trial = TrialState.shared
                if let email = auth.currentUserEmail, !email.isEmpty {
                    let suffix: String
                    switch trial.entitlement {
                    case .licensed: suffix = "lifetime"
                    case .trialActive: suffix = "trial · \(trial.daysRemaining)d left"
                    case .trialExpired: suffix = "trial expired — buy"
                    case .unknown: suffix = "trial · syncing…"
                    case .signedOut: suffix = "—"
                    }
                    acct.attributedTitle = nil
                    acct.title = "\(email)  ·  \(suffix)"
                    acct.image = NSImage(systemSymbolName: "person.crop.circle.fill",
                                         accessibilityDescription: "Account")
                    signOut.isHidden = false
                } else {
                    let title = "Sign in to start your 7-day trial"
                    let baseFont = NSFont.menuFont(ofSize: 0)
                    let boldFont = NSFontManager.shared
                        .convert(baseFont, toHaveTrait: .boldFontMask)
                    let attr = NSMutableAttributedString(
                        string: title,
                        attributes: [
                            .font: boldFont,
                            .foregroundColor: NSColor.controlAccentColor,
                        ]
                    )
                    acct.attributedTitle = attr
                    acct.title = title
                    acct.image = NSImage(systemSymbolName: "sparkles",
                                         accessibilityDescription: "Sign in")?
                        .withSymbolConfiguration(
                            NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])
                        )
                    signOut.isHidden = true
                }
            }

            // Sync Language submenu checkmarks to the current preference.
            // Needed because the user can change language from anywhere —
            // Settings picker, another menubar open — and we don't want
            // stale ticks.
            for item in menu.items {
                guard let submenu = item.submenu else { continue }
                let current = self.appState.settings.preferredLanguage
                for langItem in submenu.items {
                    let code = langItem.representedObject as? String
                    langItem.state = (code == current) ? .on : .off
                }
            }
        }
    }
}
