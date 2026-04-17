import Foundation

/// Destination surface the user is dictating into.
/// Resolved from the frontmost app's bundle ID and, for browsers,
/// the active tab URL. Injected into the Formal-mode system prompt so
/// the LLM can tailor tone to email vs chat vs document.
enum Surface: String, Codable, Equatable, CaseIterable {
    case email
    case slack
    case googleChat
    case teams
    case discord
    case messages
    case docs
    case generic

    /// Short prompt fragment appended to the Formal-mode system prompt.
    /// Empty string for `.generic` so behavior matches today when no
    /// surface could be determined.
    var promptHint: String {
        switch self {
        case .email:
            return "Destination: email. Write a complete email: greeting, body, sign-off. Keep paragraphs. No emoji."
        case .slack:
            return "Destination: Slack. Terse, conversational, single paragraph, no greeting or sign-off. Markdown okay. Emoji only if the input clearly warrants it."
        case .googleChat:
            return "Destination: Google Chat. Short, professional, no greeting or sign-off, no emoji."
        case .teams:
            return "Destination: Microsoft Teams chat. Short, professional, single paragraph, no greeting or sign-off."
        case .discord:
            return "Destination: Discord. Casual, concise, single paragraph, no greeting or sign-off."
        case .messages:
            return "Destination: chat app. Casual, very short, no greeting or sign-off."
        case .docs:
            return "Destination: document. Clean prose, no greeting or sign-off, preserve structure."
        case .generic:
            return ""
        }
    }

    /// Human-readable label used in debug logs.
    var debugLabel: String {
        switch self {
        case .email:      return "email"
        case .slack:      return "slack"
        case .googleChat: return "google-chat"
        case .teams:      return "teams"
        case .discord:    return "discord"
        case .messages:   return "messages"
        case .docs:       return "docs"
        case .generic:    return "generic"
        }
    }
}

// MARK: - Mapping tables

/// Pure, deterministic mappings from bundle ID / URL host to `Surface`.
/// Kept `internal` so unit tests can exercise them directly without
/// needing `NSWorkspace` or AppleScript.
enum SurfaceMapping {

    /// Native macOS app bundle identifiers.
    static func fromNativeBundleID(_ bundleID: String) -> Surface? {
        switch bundleID {
        // Mail clients
        case "com.apple.mail":                            return .email
        case "com.microsoft.Outlook":                     return .email
        case "com.readdle.smartemail-Mac":                return .email       // Spark
        case "com.superhuman.electron.Superhuman":        return .email
        case "com.airmailapp.airmail":                    return .email

        // Chat / messaging
        case "com.tinyspeck.slackmacgap":                 return .slack
        case "com.microsoft.teams", "com.microsoft.teams2":
            return .teams
        case "com.hnc.Discord":                           return .discord
        case "com.apple.MobileSMS":                       return .messages
        case "desktop.WhatsApp",
             "net.whatsapp.WhatsApp":                     return .messages
        case "org.whispersystems.signal-desktop":         return .messages
        case "ru.keepcoder.Telegram",
             "org.telegram.desktop":                      return .messages

        // Docs
        case "notion.id":                                 return .docs
        case "com.apple.Pages":                           return .docs
        case "com.microsoft.Word":                        return .docs

        default:                                          return nil
        }
    }

    /// Known browser bundle IDs that support AppleScript tab-URL reads.
    static let appleScriptBrowsers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",          // Arc
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
    ]

    static func isAppleScriptBrowser(_ bundleID: String) -> Bool {
        appleScriptBrowsers.contains(bundleID)
    }

    /// Map a full URL string (active browser tab) to a `Surface`.
    /// Host-prefix matching — more specific hosts win when relevant.
    static func fromURL(_ urlString: String) -> Surface? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return nil
        }
        let path = url.path.lowercased()

        // Gmail: mail.google.com (also m.google.com redirects)
        if host == "mail.google.com" { return .email }

        // Google Chat: chat.google.com, and the Gmail-integrated chat path
        if host == "chat.google.com" { return .googleChat }
        if host == "mail.google.com", path.hasPrefix("/chat") { return .googleChat }

        // Outlook web
        if host.hasSuffix("outlook.live.com") ||
           host.hasSuffix("outlook.office.com") ||
           host.hasSuffix("outlook.office365.com") { return .email }

        // Slack web
        if host.hasSuffix("slack.com") || host == "app.slack.com" { return .slack }

        // Teams web
        if host.hasSuffix("teams.microsoft.com") ||
           host.hasSuffix("teams.live.com") { return .teams }

        // Discord web
        if host.hasSuffix("discord.com") { return .discord }

        // WhatsApp / Signal / Messenger web
        if host.hasSuffix("web.whatsapp.com") ||
           host.hasSuffix("signal.org") ||
           host.hasSuffix("messenger.com") { return .messages }

        // Docs
        if host == "docs.google.com" { return .docs }
        if host.hasSuffix("notion.so") || host.hasSuffix("notion.site") { return .docs }

        return nil
    }
}
