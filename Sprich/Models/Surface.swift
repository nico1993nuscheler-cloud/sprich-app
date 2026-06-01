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
    case aiChat
    case taskManager
    case generic

    /// Short prompt fragment appended to the Formal-mode system prompt.
    /// Empty string for `.generic` so behavior matches today when no
    /// surface could be determined.
    var promptHint: String {
        switch self {
        case .email:
            // Trimmed in v1.0.13 (the verbose version doubled E2B prefill).
            // This is the validated "balanced" email hint — same shape rules,
            // ~270 tok vs ~600. See SystemPromptCatalog formal core notes.
            return """
                Destination: email. Write a complete email: greeting line, body, sign-off. No emoji.
                - Preserve any recipient name in the greeting verbatim ("Hi Maria," stays "Hi Maria,"). Never replace a named greeting with a generic "Hi,".
                - Put a blank line after the greeting and a blank line before the sign-off.
                - Split the body into separate paragraphs (blank line between) when it covers distinct topics or separate asks.
                - If no recipient was dictated, a generic "Hi," is fine. Close with "Best," or "Thanks," and no name line unless the user dictated their own name.
                - The greeting and sign-off wrap the polished dictation. A dictated question becomes a question asked in the email; a dictated request becomes a request made in the email — NEVER answered or fulfilled.

                Voice example (named recipient kept, two body paragraphs):
                INPUT:  "hi maria just wanted to follow up on the proposal we sent last week also could you let me know if you need anything else from us to move things forward"
                OUTPUT:
                Hi Maria,

                I wanted to follow up on the proposal we sent last week.

                Could you also let me know if you need anything else from us to move things forward?

                Best,
                """
        case .slack:
            return """
                Destination: Slack. Voice: clean conversational, terse, single paragraph, no greeting or sign-off. Markdown okay. Emoji only if the user clearly dictated one.
                Voice example:
                  INPUT:  "hey team uh just wanted to flag that the deploy is going out at like 3pm today"
                  OUTPUT: "Heads up — deploy is going out at 3pm today."
                """
        case .googleChat:
            return """
                Destination: Google Chat. Voice: short professional, no greeting or sign-off, no emoji.
                Voice example:
                  INPUT:  "um could you maybe take a look at the doc when you have a sec thanks"
                  OUTPUT: "Could you take a look at the doc when you have a moment? Thanks."
                """
        case .teams:
            return """
                Destination: Microsoft Teams chat. Voice: short professional, single paragraph, no greeting or sign-off.
                Voice example:
                  INPUT:  "hey just checking can you join the standup tomorrow"
                  OUTPUT: "Quick check — can you join the standup tomorrow?"
                """
        case .discord:
            return """
                Destination: Discord. Voice: casual, concise, single paragraph, no greeting or sign-off.
                Voice example:
                  INPUT:  "uh yeah so I think the new patch broke the build like everything fails now"
                  OUTPUT: "I think the new patch broke the build — everything fails now."
                """
        case .messages:
            return """
                Destination: chat app. Voice: casual, very short, no greeting or sign-off.
                Voice example:
                  INPUT:  "hey um can you grab milk on the way home thanks"
                  OUTPUT: "Could you grab milk on the way home? Thanks."
                """
        case .docs:
            return """
                Destination: document. Voice: clean prose, no greeting or sign-off, preserve structure (paragraph breaks, lists if dictated).
                """
        case .aiChat:
            return """
                Destination: AI chat assistant (ChatGPT, Claude, Gemini, Perplexity, Copilot, etc.). Voice: tight, direct, imperative — NOT polite-formal. The user is writing a prompt FOR a machine to receive, not a message to a person. No "please", no "could you", no "would you mind" — those waste tokens and dilute the request. No greeting, no sign-off. Use imperative verbs ("Suggest", "Generate", "Summarize", "Explain", "Compare", "Write") or a sharp direct question. Preserve every specific detail the user dictated (numbers, names, file paths, code snippets, constraints) verbatim — those are usually load-bearing. If the user described multiple constraints, requirements, or examples, surface them as a bulleted list.

                CRITICAL — your output is the PROMPT the user will send to the assistant. It is NOT a response to that prompt. If the dictation is "suggest five taglines", your output is "Suggest five taglines for X." — NOT a list of taglines.

                Voice example (request becomes a clean prompt — NOT a response):
                  INPUT:   "uh please I want can you give me like five launch tagline ideas for a Mac Dictation app that runs locally"
                  CORRECT: "Suggest five launch tagline ideas for a Mac dictation app that runs locally."
                  WRONG (do NOT do this): "Here are five tagline ideas: 1. Unlock Clarity… 2. Precision Dictation… [etc]"
                """
        case .taskManager:
            return """
                Destination: project-management / task tool (Notion, Linear, ClickUp, Asana, Jira, Trello, Todoist, Monday, Basecamp, Height, etc.). Format the dictation as a STRUCTURED TICKET, not a message to a person. No greeting, no sign-off. Use Markdown.
                - First line: a short bold title in imperative form, e.g. **Fix login bug on Safari** — lead with a verb (Add, Fix, Investigate, Implement, Refactor, Update, Migrate, …). Wrap the title in ** **.
                - If the user dictated any context, details, acceptance criteria, sub-steps, or links, list them as Markdown bullets ("- ") under the title — one point per bullet, tight. If the user dictated NOTHING beyond the task itself, output ONLY the bold title line; never invent bullets.

                CRITICAL — your output is the TICKET the user is writing, not the work itself. Polish and structure their words; NEVER answer, implement, or expand beyond what they dictated. "Implement OAuth login" becomes the ticket title, not OAuth code.

                Example (title only — no detail dictated):
                  INPUT:   "uh yeah we should probably like fix the login bug where users get logged out after 5 minutes on Safari"
                  OUTPUT:  "**Fix login bug: users logged out after 5 minutes on Safari**"

                Example (title + dictated context → bullets):
                  INPUT:   "log a ticket to add CSV export to the reports page it should support comma and semicolon delimiters and remember the user's last choice"
                  OUTPUT:
                  **Add CSV export to the reports page**
                  - Support comma and semicolon delimiters
                  - Remember the user's last delimiter choice
                """
        case .generic:
            return ""
        }
    }

    /// Human-readable label used in debug logs.
    var debugLabel: String {
        switch self {
        case .email:       return "email"
        case .slack:       return "slack"
        case .googleChat:  return "google-chat"
        case .teams:       return "teams"
        case .discord:     return "discord"
        case .messages:    return "messages"
        case .docs:        return "docs"
        case .aiChat:      return "ai-chat"
        case .taskManager: return "task-manager"
        case .generic:     return "generic"
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

        // AI chat assistants (native desktop apps)
        case "com.openai.chat":                           return .aiChat
        case "com.anthropic.claudefordesktop":            return .aiChat
        case "ai.perplexity.mac",
             "ai.perplexity.comet":                       return .aiChat

        // Project-management / task tools (native desktop apps)
        case "notion.id":                                 return .taskManager
        case "com.linear":                                return .taskManager
        case "com.todoist.mac.Todoist",
             "com.todoist.Todoist":                       return .taskManager
        case "com.culturedcode.ThingsMac":                return .taskManager
        case "com.omnigroup.OmniFocus3",
             "com.omnigroup.OmniFocus4":                  return .taskManager
        case "com.electron.clickup",
             "com.clickup.desktop":                       return .taskManager

        // Docs
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
        if host == "mail.google.com" {
            // Chat-in-Gmail path wins before the email fallback below.
            if path.hasPrefix("/chat") { return .googleChat }
            return .email
        }

        // Google Chat: chat.google.com, and the Gmail-integrated chat path
        if host == "chat.google.com" { return .googleChat }

        // Outlook web
        if host.hasSuffix("outlook.live.com") ||
           host.hasSuffix("outlook.office.com") ||
           host.hasSuffix("outlook.office365.com") { return .email }

        // Other web email (see SurfaceHosts.reference.md)
        if host == "mail.yahoo.com" { return .email }
        if host == "mail.proton.me" || host == "mail.protonmail.com" { return .email }
        if host == "app.fastmail.com" { return .email }
        if host == "app.hey.com" { return .email }
        if host == "mail.zoho.com" || host == "mail.zoho.eu" || host == "mail.zoho.in" { return .email }

        // Slack web
        if host.hasSuffix("slack.com") || host == "app.slack.com" { return .slack }

        // Teams web
        if host.hasSuffix("teams.microsoft.com") ||
           host.hasSuffix("teams.live.com") { return .teams }

        // Discord web
        if host.hasSuffix("discord.com") { return .discord }

        // WhatsApp / Telegram / Messenger web (Signal has no web client)
        if host.hasSuffix("web.whatsapp.com") ||
           host == "web.telegram.org" ||
           host.hasSuffix("messenger.com") { return .messages }

        // AI chat assistants (web)
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") ||
           host == "chat.openai.com" { return .aiChat }
        if host == "claude.ai" || host.hasSuffix(".claude.ai") ||
           host == "claude.com" || host.hasSuffix(".claude.com") { return .aiChat }
        if host == "gemini.google.com" || host == "aistudio.google.com" ||
           host == "bard.google.com" { return .aiChat }
        if host == "perplexity.ai" || host.hasSuffix(".perplexity.ai") { return .aiChat }
        if host == "copilot.microsoft.com" { return .aiChat }
        if host == "chat.deepseek.com" || host == "deepseek.com" ||
           host.hasSuffix(".deepseek.com") { return .aiChat }
        if host == "chat.mistral.ai" || host == "mistral.ai" { return .aiChat }
        if host == "grok.com" || host.hasSuffix(".grok.com") ||
           host == "x.ai"     || host.hasSuffix(".x.ai") { return .aiChat }
        if host == "poe.com" || host.hasSuffix(".poe.com") { return .aiChat }
        if host == "you.com" || host == "chat.you.com" { return .aiChat }
        if host == "phind.com" { return .aiChat }

        // Project-management / task tools (web).
        // Notion is dual-use (wiki + DB); routed to task-manager per the
        // most common dictation case. Atlassian's /wiki/ path is Confluence
        // (docs), so split it explicitly before the Jira fallback.
        // Notion: `notion.so`/`notion.site` are the legacy hosts; `notion.com`
        // / `app.notion.com` is the current app host Notion migrated to and
        // was seen mis-detecting as `.generic` on a real device. Match all.
        // See SurfaceHosts.reference.md.
        if host.hasSuffix("notion.so") || host.hasSuffix("notion.site") ||
           host.hasSuffix("notion.com") { return .taskManager }
        if host.hasSuffix("linear.app") { return .taskManager }
        if host == "clickup.com" || host.hasSuffix(".clickup.com") { return .taskManager }
        if host.hasSuffix("asana.com") { return .taskManager }
        if host.hasSuffix("atlassian.net") {
            if path.hasPrefix("/wiki") { return .docs }   // Confluence
            return .taskManager                            // Jira
        }
        if host == "trello.com" || host.hasSuffix(".trello.com") { return .taskManager }
        if host == "todoist.com" || host.hasSuffix(".todoist.com") { return .taskManager }
        if host == "monday.com" || host.hasSuffix(".monday.com") { return .taskManager }
        if host == "basecamp.com" || host.hasSuffix(".basecamp.com") ||
           host.hasSuffix(".basecamphq.com") { return .taskManager }
        if host == "height.app" || host.hasSuffix(".height.app") { return .taskManager }
        if host.hasSuffix(".shortcut.com") || host == "app.shortcut.com" { return .taskManager }
        if host.hasSuffix("smartsheet.com") || host.hasSuffix("smartsheet.eu") { return .taskManager }
        if host == "airtable.com" || host.hasSuffix(".airtable.com") { return .taskManager }

        // Docs / notes (web).
        if host == "docs.google.com" { return .docs }
        if host == "coda.io" || host.hasSuffix(".coda.io") { return .docs }
        if host == "paper.dropbox.com" { return .docs }

        return nil
    }
}

// MARK: - Web brand display (history label)

/// Maps a browser-tab URL host to the brand/service display name shown
/// in the History row (e.g. "Gmail", "Notion", "LinkedIn"). Separate from
/// `Surface` because `Surface` is a coarse tone-routing category for the
/// LLM (`.email` / `.taskManager` / …), while History wants the specific
/// brand a user actually recognizes.
///
/// Curated list below covers the most-common surfaces. Anything unmapped
/// falls back to a title-cased second-level domain — `figma.com` → "Figma",
/// `randomtool.io` → "Randomtool". That keeps the label meaningful for the
/// long tail without per-host curation.
enum WebSurfaceLabel {

    /// Resolve a URL host (case-insensitive) to a brand display name.
    /// Returns `nil` only for empty/invalid input — every real host
    /// gets at least the title-cased fallback.
    static func displayName(forHost host: String) -> String? {
        let h = host.lowercased()
        guard !h.isEmpty else { return nil }

        // Google suite
        if h == "mail.google.com"                      { return "Gmail" }
        if h == "chat.google.com"                      { return "Google Chat" }
        if h == "docs.google.com"                      { return "Google Docs" }
        if h == "drive.google.com"                     { return "Google Drive" }
        if h == "calendar.google.com"                  { return "Google Calendar" }
        if h == "meet.google.com"                      { return "Google Meet" }
        if h == "sheets.google.com"                    { return "Google Sheets" }
        if h == "slides.google.com"                    { return "Google Slides" }
        if h == "gemini.google.com" || h == "bard.google.com" { return "Gemini" }
        if h == "aistudio.google.com"                  { return "Google AI Studio" }

        // Microsoft suite
        if h.hasSuffix("outlook.live.com") ||
           h.hasSuffix("outlook.office.com") ||
           h.hasSuffix("outlook.office365.com")        { return "Outlook" }
        if h.hasSuffix("teams.microsoft.com") ||
           h.hasSuffix("teams.live.com")               { return "Teams" }
        if h == "copilot.microsoft.com"                { return "Copilot" }

        // Chat / messaging
        if h.hasSuffix("slack.com")                    { return "Slack" }
        if h.hasSuffix("discord.com")                  { return "Discord" }
        if h == "web.whatsapp.com" || h.hasSuffix(".web.whatsapp.com") { return "WhatsApp" }
        if h == "web.telegram.org"                     { return "Telegram" }
        if h.hasSuffix("messenger.com")                { return "Messenger" }
        if h.hasSuffix("signal.org")                   { return "Signal" }

        // AI chat assistants
        if h == "chatgpt.com" || h.hasSuffix(".chatgpt.com") ||
           h == "chat.openai.com"                      { return "ChatGPT" }
        if h == "claude.ai"   || h.hasSuffix(".claude.ai") ||
           h == "claude.com"  || h.hasSuffix(".claude.com") { return "Claude" }
        if h == "perplexity.ai" || h.hasSuffix(".perplexity.ai") { return "Perplexity" }
        if h == "chat.deepseek.com" || h == "deepseek.com" ||
           h.hasSuffix(".deepseek.com")                { return "DeepSeek" }
        if h == "chat.mistral.ai" || h == "mistral.ai" { return "Mistral" }
        if h == "grok.com"  || h.hasSuffix(".grok.com") ||
           h == "x.ai"      || h.hasSuffix(".x.ai")    { return "Grok" }
        if h == "poe.com"   || h.hasSuffix(".poe.com") { return "Poe" }
        if h == "phind.com"                            { return "Phind" }
        if h == "you.com"   || h == "chat.you.com"     { return "You.com" }

        // Project-management / task tools
        if h.hasSuffix("notion.so") || h.hasSuffix("notion.site") ||
           h.hasSuffix("notion.com")                   { return "Notion" }
        if h.hasSuffix("smartsheet.com") || h.hasSuffix("smartsheet.eu") { return "Smartsheet" }
        if h == "airtable.com" || h.hasSuffix(".airtable.com") { return "Airtable" }
        if h.hasSuffix("linear.app")                   { return "Linear" }
        if h == "clickup.com" || h.hasSuffix(".clickup.com") { return "ClickUp" }
        if h.hasSuffix("asana.com")                    { return "Asana" }
        if h.hasSuffix("atlassian.net")                { return "Atlassian" }
        if h == "trello.com" || h.hasSuffix(".trello.com") { return "Trello" }
        if h == "todoist.com" || h.hasSuffix(".todoist.com") { return "Todoist" }
        if h == "monday.com" || h.hasSuffix(".monday.com") { return "Monday" }
        if h == "basecamp.com" || h.hasSuffix(".basecamp.com") ||
           h.hasSuffix(".basecamphq.com")              { return "Basecamp" }
        if h == "height.app" || h.hasSuffix(".height.app") { return "Height" }
        if h.hasSuffix("shortcut.com")                 { return "Shortcut" }

        // Dev
        if h.hasSuffix("github.com")                   { return "GitHub" }
        if h.hasSuffix("gitlab.com")                   { return "GitLab" }
        if h.hasSuffix("bitbucket.org")                { return "Bitbucket" }

        // Social / professional
        if h.hasSuffix("linkedin.com")                 { return "LinkedIn" }
        if h == "twitter.com" || h.hasSuffix(".twitter.com") ||
           h == "x.com"       || h.hasSuffix(".x.com") { return "X" }
        if h.hasSuffix("reddit.com")                   { return "Reddit" }
        if h.hasSuffix("facebook.com")                 { return "Facebook" }
        if h.hasSuffix("instagram.com")                { return "Instagram" }
        if h == "threads.net" || h.hasSuffix(".threads.net") { return "Threads" }
        if h.hasSuffix("bsky.app")                     { return "Bluesky" }
        if h.hasSuffix("mastodon.social")              { return "Mastodon" }

        // Design / docs / media
        if h.hasSuffix("figma.com")                    { return "Figma" }
        if h.hasSuffix("stackoverflow.com")            { return "Stack Overflow" }
        if h.hasSuffix("medium.com")                   { return "Medium" }
        if h.hasSuffix("substack.com")                 { return "Substack" }
        if h.hasSuffix("youtube.com") || h == "youtu.be" { return "YouTube" }
        if h.hasSuffix("buffer.com")                   { return "Buffer" }

        // Long-tail fallback: title-case the second-level domain.
        return fallbackBrandFromHost(h)
    }

    /// Format the History row's `targetApp` string. When `webHost` resolves
    /// to a brand, append " — Brand". Otherwise return just `appName`.
    ///   "Google Chrome"            — no host
    ///   "Google Chrome — Gmail"    — host = mail.google.com
    ///   "Slack" (not "Slack — Slack") — when brand == app, dedupe
    static func formatTargetApp(appName: String?, webHost: String?) -> String? {
        let trimmedApp = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = (trimmedApp?.isEmpty == false) ? trimmedApp! : nil
        guard let app else {
            if let host = webHost, let brand = displayName(forHost: host) { return brand }
            return nil
        }
        guard let host = webHost,
              let brand = displayName(forHost: host),
              brand.caseInsensitiveCompare(app) != .orderedSame else {
            return app
        }
        return "\(app) — \(brand)"
    }

    /// Title-case the second-level domain as a long-tail fallback.
    /// `figma.com` → "Figma"; `app.something.co.uk` → "Something".
    private static func fallbackBrandFromHost(_ host: String) -> String? {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }

        // Handle common two-part TLDs (.co.uk / .com.au / …) without
        // pulling in a full PSL. Misses rarities; acceptable.
        let twoPartTLDSuffixes: Set<String> = [
            "co.uk", "co.jp", "co.kr", "co.in", "co.nz", "co.za",
            "com.au", "com.br", "com.mx", "com.sg", "com.hk", "com.tw",
            "ac.uk", "org.uk", "gov.uk", "ne.jp", "or.jp",
        ]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        let stripCount = twoPartTLDSuffixes.contains(lastTwo) ? 2 : 1
        guard parts.count > stripCount else { return nil }

        let sld = parts[parts.count - 1 - stripCount]
        guard !sld.isEmpty else { return nil }
        return sld.prefix(1).uppercased() + sld.dropFirst()
    }
}
