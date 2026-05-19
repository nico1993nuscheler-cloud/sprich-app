import SwiftUI
import AppKit
import UserNotifications

/// Surface for the "cloud provider selected but no API key in Keychain"
/// failure path. P1-UX-14 / P1-UX-15 in sprint-3-settings-ux.md.
///
/// Before this ticket, the missing-key path landed in `surfaceBlockingError`
/// — a modal NSAlert that interrupted the user without offering a path
/// to "paste the key" beyond "find Settings → API Keys yourself". UX
/// audit P0 #1.
///
/// Two surfaces:
///   1. **System notification** (UNUserNotification) — the dependable
///      cross-context surface. Sprich is a menubar app; when a dictation
///      hotkey misfires the user is almost always in Slack / Mail /
///      Notes / a browser. The notification's "Open Settings" action
///      activates Sprich and deep-links to AI Models.
///   2. **In-window banner** (`MissingKeyBannerView`) — non-modal SwiftUI
///      overlay that any Sprich-window root can mount by listening to
///      `.sprichMissingKeyInWindowBanner`. Currently unmounted; the
///      notification path covers the common case. Wired here so future
///      work (mounting in the Settings window when Settings is already
///      open) can land without re-touching the presenter.
enum MissingKeyBanner {

    /// Notification a Sprich-window root subscribes to in order to mount
    /// `MissingKeyBannerView`. UserInfo: `["providerName": String]`.
    static let inWindowBannerNotification = Notification.Name("SprichMissingKeyInWindowBanner")

    /// Action identifier on the UNNotification — used by the delegate
    /// (`MissingKeyBannerDelegate`) to recognise an "Open Settings" tap.
    static let openSettingsActionID = "SprichOpenSettings"

    /// Category identifier — links the notification content to the
    /// "Open Settings" action button via UNNotificationCategory.
    static let categoryID = "SprichMissingKey"

    /// One-shot guard so `requestAuthorization` doesn't pile up a prompt
    /// per missed dictation. The platform deduplicates, but explicit is
    /// kinder and lets us skip the round trip on repeat calls.
    private static var didRequestAuthorization = false

    /// Public entry called by `PipelineCoordinator.surfaceBlockingError`
    /// (P1-UX-15) when `SprichError.missingAPIKey` fires.
    ///
    /// - Parameter providerName: human label ("Groq", "Claude", …) used
    ///   in both the in-window banner and the system notification copy.
    @MainActor
    static func present(providerName: String) {
        NotificationCenter.default.post(
            name: inWindowBannerNotification,
            object: nil,
            userInfo: ["providerName": providerName]
        )
        scheduleSystemNotification(providerName: providerName)
    }

    /// Called by `MissingKeyBannerDelegate` when the user taps the
    /// "Open Settings" action on a delivered notification. Brings Sprich
    /// to the front and posts the deep-link notification the Settings
    /// window already listens for (wired in P1-UX-01).
    @MainActor
    static func handleOpenSettingsAction() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: .sprichOpenSettingsSection,
            object: nil,
            userInfo: ["section": SettingsSection.aiModels.rawValue]
        )
    }

    @MainActor
    private static func scheduleSystemNotification(providerName: String) {
        let center = UNUserNotificationCenter.current()
        registerCategoryIfNeeded(center: center)

        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = "Add your \(providerName) API key"
            content.body = "Sprich can't run the AI cleanup until you paste a \(providerName) key. Open Settings → AI Models to add it."
            content.sound = .default
            content.categoryIdentifier = categoryID
            content.userInfo = ["providerName": providerName]

            let request = UNNotificationRequest(
                identifier: "SprichMissingKey-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }

        if didRequestAuthorization {
            deliver()
        } else {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async(execute: deliver)
            }
        }
    }

    private static func registerCategoryIfNeeded(center: UNUserNotificationCenter) {
        let openAction = UNNotificationAction(
            identifier: openSettingsActionID,
            title: "Open Settings",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}

/// UNUserNotificationCenterDelegate that routes the "Open Settings" action
/// back to `MissingKeyBanner.handleOpenSettingsAction()`. Set as the
/// center's delegate from `AppDelegate.applicationDidFinishLaunching`.
final class MissingKeyBannerDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MissingKeyBannerDelegate()

    /// Show the banner as a full notification even when Sprich is the
    /// frontmost app (otherwise macOS drops it on the floor — and the
    /// in-window banner currently has no mount point).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Treat "default action" (tapping the notification body) the same
        // as the explicit "Open Settings" button — there's only one
        // sensible thing to do here.
        let id = response.actionIdentifier
        if id == MissingKeyBanner.openSettingsActionID
            || id == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                MissingKeyBanner.handleOpenSettingsAction()
            }
        }
        completionHandler()
    }
}

/// Non-modal in-window banner. Currently unmounted — wired here so any
/// Sprich-window root can opt in later by listening to
/// `MissingKeyBanner.inWindowBannerNotification` and rendering this view.
struct MissingKeyBannerView: View {
    let providerName: String
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 4) {
                Text("Sprich needs a \(providerName) API key for AI cleanup")
                    .font(.system(size: 13, weight: .semibold))
                Text("Paste it in Settings → AI Models to enable Formal and Custom modes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button("Open Settings → AI cleanup", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Dismiss", action: onDismiss)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
        )
    }
}
