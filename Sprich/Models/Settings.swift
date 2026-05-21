import Foundation

// MARK: - Provider Enums

enum STTProviderType: String, Codable, CaseIterable {
    case groq = "Groq Whisper"
    case openai = "OpenAI Whisper"
    case deepgram = "Deepgram Nova-3"
    case local = "Local (offline)"

    /// User-facing label. `displayName` is what every Settings / menu / error
    /// surface should read; the `rawValue` is locked to its current string
    /// because it's the persisted `Codable` representation — renaming it
    /// would orphan every existing user's settings.json.
    ///
    /// `.local` reads "On this Mac" per Decision 5 (sprint-3-settings-ux.md)
    /// — "Local (offline)" was technically correct but parsed as a feature
    /// flag instead of a place where the work happens.
    var displayName: String {
        switch self {
        case .local: return "On this Mac"
        default:     return rawValue
        }
    }

    /// True when this provider runs entirely on-device and needs no API key.
    var isLocal: Bool { self == .local }

    var baseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
        case .openai: return "https://api.openai.com/v1/audio/transcriptions"
        case .deepgram: return "https://api.deepgram.com/v1/listen"
        case .local: return ""
        }
    }

    var keychainKey: String {
        switch self {
        case .groq: return "sprich.api.groq"
        case .openai: return "sprich.api.openai"
        case .deepgram: return "sprich.api.deepgram"
        case .local: return ""
        }
    }

    /// Billing / upgrade dashboard users are pointed at when rate-limited.
    /// Empty for local (no rate limits).
    var dashboardURL: String {
        switch self {
        case .groq: return "https://console.groq.com/settings/billing"
        case .openai: return "https://platform.openai.com/account/billing"
        case .deepgram: return "https://console.deepgram.com/billing"
        case .local: return ""
        }
    }
}

enum LLMProviderType: String, Codable, CaseIterable {
    case groq = "Groq (fastest)"
    case claude = "Claude (Anthropic)"
    case google = "Gemini (Google)"
    case openai = "OpenAI"
    case local = "Local (offline)"

    /// User-facing label. See `STTProviderType.displayName` — same rules:
    /// rawValue is the persisted Codable string and must not change;
    /// `.local` reads "On this Mac" per Decision 5.
    var displayName: String {
        switch self {
        case .local: return "On this Mac"
        default:     return rawValue
        }
    }

    /// True when this provider runs entirely on-device and needs no API key.
    /// Mirrors `STTProviderType.local`'s shape — readiness of the model bytes
    /// on disk is tracked separately by `LLMModelManager`.
    var isLocal: Bool { self == .local }

    var keychainKey: String {
        switch self {
        case .groq: return "sprich.api.groq"  // Same key as STT
        case .claude: return "sprich.api.anthropic"
        case .google: return "sprich.api.google"
        case .openai: return "sprich.api.openai"
        case .local: return ""
        }
    }

    var dashboardURL: String {
        switch self {
        case .groq: return "https://console.groq.com/settings/billing"
        case .claude: return "https://console.anthropic.com/settings/billing"
        case .google: return "https://aistudio.google.com/apikey"
        case .openai: return "https://platform.openai.com/account/billing"
        case .local: return ""
        }
    }
}

// MARK: - Supported Languages

/// A language the user can pin STT to. `code == nil` means "auto-detect".
/// Codes are ISO 639-1 and passed verbatim to every STT provider
/// (Whisper via the `language` field, Deepgram via `?language=`).
struct SupportedLanguage: Hashable {
    let code: String?
    let displayName: String
}

enum AppLanguages {
    static let all: [SupportedLanguage] = [
        .init(code: nil,  displayName: "Auto-detect"),
        .init(code: "en", displayName: "English"),
        .init(code: "de", displayName: "Deutsch"),
        .init(code: "es", displayName: "Español"),
        .init(code: "fr", displayName: "Français"),
        .init(code: "pt", displayName: "Português"),
        .init(code: "it", displayName: "Italiano"),
        .init(code: "nl", displayName: "Nederlands"),
        .init(code: "pl", displayName: "Polski"),
        .init(code: "sv", displayName: "Svenska"),
        .init(code: "tr", displayName: "Türkçe"),
        .init(code: "ru", displayName: "Русский"),
        .init(code: "ar", displayName: "العربية"),
        .init(code: "hi", displayName: "हिन्दी"),
        .init(code: "zh", displayName: "中文"),
        .init(code: "ja", displayName: "日本語"),
    ]
}

// MARK: - Glossary

struct GlossaryReplacement: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var from: String
    var to: String
}

// MARK: - Settings Model

struct AppSettings: Codable {
    var sttProvider: STTProviderType
    var llmProvider: LLMProviderType
    var groqLLMModel: String
    var claudeModel: String
    var googleModel: String
    var openAILLMModel: String
    var preferredLanguage: String?  // nil = auto-detect, "de", "en"

    var literalPrompt: String
    var formalPrompt: String

    // Custom mode (triggered via Fn+Cmd). Max 1 custom mode.
    var customModeEnabled: Bool
    var customModeName: String           // e.g. "Slack", "Emails"
    var customModeBadge: String          // single character, e.g. "C"
    var customModePrompt: String         // short system prompt for LLM

    // Glossary — biases STT via `prompt` param AND applies post-STT replacements.
    var glossaryTerms: String            // comma-separated vocabulary list (Whisper bias)
    var glossaryReplacements: [GlossaryReplacement]  // post-STT find→replace

    var inputMode: InputMode
    var maxRecordingDuration: Int  // seconds

    /// When true, Formal mode appends a destination-aware hint to its
    /// system prompt (Slack / Gmail / Google Chat / Messages / docs).
    /// Literal and Custom modes are never affected.
    var adaptToSurface: Bool

    /// WhisperKit model identifier for the local offline provider.
    /// Resolved at runtime by `WhisperModelManager`.
    var localWhisperModel: String

    /// Local LLM model spec ID for the on-device offline provider.
    /// Resolved at runtime by `LLMModelManager`. The spec ID encodes
    /// model + container + quant — e.g. `"gemma-3-1b-it-q4_k_m"`.
    var localLLMModel: String

    var hasRequiredAPIKeys: Bool {
        // Local STT runs on-device — it needs a downloaded model, not a key.
        // Local LLM is the same shape: no key required, readiness of the
        // model bytes on disk is tracked separately by LLMModelManager so
        // onboarding doesn't treat "no key" as a failure for local providers.
        let sttOK = sttProvider.isLocal
            ? true
            : (KeychainManager.retrieve(key: sttProvider.keychainKey) != nil)
        let llmOK = llmProvider.isLocal
            ? true
            : (KeychainManager.retrieve(key: llmProvider.keychainKey) != nil)
        return sttOK && llmOK
    }

    func promptForMode(_ mode: TranscriptionMode) -> String {
        switch mode {
        case .literal: return literalPrompt
        case .formal:  return formalPrompt
        case .custom:  return customModePrompt
        }
    }

    /// Display name for a mode, honoring customModeName for .custom.
    func displayName(for mode: TranscriptionMode) -> String {
        if mode == .custom, !customModeName.trimmingCharacters(in: .whitespaces).isEmpty {
            return customModeName
        }
        return mode.displayName
    }

    /// Single-letter HUD badge, honoring customModeBadge for .custom.
    func badgeLetter(for mode: TranscriptionMode) -> String {
        if mode == .custom {
            let b = customModeBadge.trimmingCharacters(in: .whitespaces)
            return b.isEmpty ? "C" : String(b.prefix(1)).uppercased()
        }
        return mode.defaultBadgeLetter
    }

    // Lenient decoder: any field missing from persisted JSON falls back
    // to its value in `defaults`. Keeps user settings intact across
    // upgrades that add new fields (e.g. `adaptToSurface`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        self.sttProvider          = (try? c.decode(STTProviderType.self, forKey: .sttProvider))          ?? d.sttProvider
        self.llmProvider          = (try? c.decode(LLMProviderType.self, forKey: .llmProvider))          ?? d.llmProvider
        self.groqLLMModel         = (try? c.decode(String.self,          forKey: .groqLLMModel))         ?? d.groqLLMModel
        self.claudeModel          = (try? c.decode(String.self,          forKey: .claudeModel))          ?? d.claudeModel
        self.googleModel          = (try? c.decode(String.self,          forKey: .googleModel))          ?? d.googleModel
        self.openAILLMModel       = (try? c.decode(String.self,          forKey: .openAILLMModel))       ?? d.openAILLMModel
        self.preferredLanguage    = try? c.decodeIfPresent(String.self,  forKey: .preferredLanguage)
        // Sprint 3 polish #6 — soft-migrate stale Literal/Formal prompts.
        // The pre-Sprint-2F defaults hardcoded "Maintain input language
        // (DE/EN)" and got persisted into every existing user's settings.json.
        // Sprint 2F replaced the defaults (see proposed-prompt-change.md);
        // settings on disk did not auto-upgrade. If the saved value matches
        // a known prior default verbatim, swap it to the current default —
        // a user with a custom prompt is never touched.
        let savedLiteral = (try? c.decode(String.self, forKey: .literalPrompt)) ?? d.literalPrompt
        let savedFormal  = (try? c.decode(String.self, forKey: .formalPrompt))  ?? d.formalPrompt
        self.literalPrompt = AppSettings.knownLegacyLiteralDefaults.contains(savedLiteral)
            ? d.literalPrompt
            : savedLiteral
        self.formalPrompt = AppSettings.knownLegacyFormalDefaults.contains(savedFormal)
            ? d.formalPrompt
            : savedFormal
        self.customModeEnabled    = (try? c.decode(Bool.self,            forKey: .customModeEnabled))    ?? d.customModeEnabled
        self.customModeName       = (try? c.decode(String.self,          forKey: .customModeName))       ?? d.customModeName
        self.customModeBadge      = (try? c.decode(String.self,          forKey: .customModeBadge))      ?? d.customModeBadge
        self.customModePrompt     = (try? c.decode(String.self,          forKey: .customModePrompt))     ?? d.customModePrompt
        self.glossaryTerms        = (try? c.decode(String.self,          forKey: .glossaryTerms))        ?? d.glossaryTerms
        self.glossaryReplacements = (try? c.decode([GlossaryReplacement].self, forKey: .glossaryReplacements)) ?? d.glossaryReplacements
        self.inputMode            = (try? c.decode(InputMode.self,       forKey: .inputMode))            ?? d.inputMode
        self.maxRecordingDuration = (try? c.decode(Int.self,             forKey: .maxRecordingDuration)) ?? d.maxRecordingDuration
        self.adaptToSurface       = (try? c.decode(Bool.self,            forKey: .adaptToSurface))       ?? d.adaptToSurface
        self.localWhisperModel    = (try? c.decode(String.self,          forKey: .localWhisperModel))    ?? d.localWhisperModel
        self.localLLMModel        = (try? c.decode(String.self,          forKey: .localLLMModel))        ?? d.localLLMModel
    }

    // Memberwise init is suppressed once we declare `init(from:)`, so
    // provide it explicitly for `AppSettings.defaults` and tests.
    init(
        sttProvider: STTProviderType,
        llmProvider: LLMProviderType,
        groqLLMModel: String,
        claudeModel: String,
        googleModel: String,
        openAILLMModel: String,
        preferredLanguage: String?,
        literalPrompt: String,
        formalPrompt: String,
        customModeEnabled: Bool,
        customModeName: String,
        customModeBadge: String,
        customModePrompt: String,
        glossaryTerms: String,
        glossaryReplacements: [GlossaryReplacement],
        inputMode: InputMode,
        maxRecordingDuration: Int,
        adaptToSurface: Bool,
        localWhisperModel: String,
        localLLMModel: String
    ) {
        self.sttProvider = sttProvider
        self.llmProvider = llmProvider
        self.groqLLMModel = groqLLMModel
        self.claudeModel = claudeModel
        self.googleModel = googleModel
        self.openAILLMModel = openAILLMModel
        self.preferredLanguage = preferredLanguage
        self.literalPrompt = literalPrompt
        self.formalPrompt = formalPrompt
        self.customModeEnabled = customModeEnabled
        self.customModeName = customModeName
        self.customModeBadge = customModeBadge
        self.customModePrompt = customModePrompt
        self.glossaryTerms = glossaryTerms
        self.glossaryReplacements = glossaryReplacements
        self.inputMode = inputMode
        self.maxRecordingDuration = maxRecordingDuration
        self.adaptToSurface = adaptToSurface
        self.localWhisperModel = localWhisperModel
        self.localLLMModel = localLLMModel
    }

    /// Pre-Sprint-2F Literal defaults that should be auto-upgraded to the
    /// current `TranscriptionMode.literal.defaultSystemPrompt`. A user who
    /// authored their own Literal prompt is never matched against this list.
    /// Migration runs in `init(from:)` — see polish #6 in sprint-3 follow-ups.
    static let knownLegacyLiteralDefaults: Set<String> = [
        // Original pre-2F default — hardcoded "Maintain input language (DE/EN)"
        // that biased Whisper toward only those two languages.
        "Clean up dictated text. Remove fillers, false starts, fix grammar. Keep original wording and tone. Maintain input language (DE/EN). Output only cleaned text."
    ]

    static let knownLegacyFormalDefaults: Set<String> = [
        "Rewrite dictated text as professional written text for emails/business. Remove spoken artifacts, improve structure and formality. Maintain input language (DE/EN). Output only final text."
    ]

    static var defaults: AppSettings {
        AppSettings(
            // Local-first is the Phase 1 wedge: a fresh install hands you a
            // fully on-device pipeline (STT + LLM cleanup) by default.
            // Onboarding's "Your Mac: Recommended" panel presents the
            // ~2.3 GB combined Whisper + Gemma download as the happy path,
            // so the factory default matches what onboarding nudges
            // toward. Users with a HardwareProbe failure or who skip the
            // Gemma download can swap to a cloud LLM in Settings →
            // Providers; existing users' saved choice is preserved.
            sttProvider: .local,
            llmProvider: .local,
            groqLLMModel: "llama-3.3-70b-versatile",
            claudeModel: "claude-haiku-4-20250414",
            googleModel: "gemini-2.5-flash",
            openAILLMModel: "gpt-4o-mini",
            preferredLanguage: nil,
            literalPrompt: TranscriptionMode.literal.defaultSystemPrompt,
            formalPrompt: TranscriptionMode.formal.defaultSystemPrompt,
            customModeEnabled: false,
            customModeName: "Custom",
            customModeBadge: "C",
            customModePrompt: TranscriptionMode.custom.defaultSystemPrompt,
            glossaryTerms: "",
            glossaryReplacements: [],
            inputMode: .holdToTalk,
            maxRecordingDuration: 300,
            adaptToSurface: true,
            // Default is the `_turbo_632MB` variant — same weights as
            // the plain 626MB model (DoD "WER parity with Groq" still
            // holds, Groq's whisper-large-v3 shares the same encoder),
            // but with OpenAI's pruned turbo decoder (8 layers vs 32)
            // for ~2× faster inference. User can swap to Fast or
            // Accurate in Settings → Providers → Local.
            localWhisperModel: WhisperModelCatalog.balanced.variantName,
            // Default local LLM spec — Gemma 3 1B-it, GGUF Q4_K_M.
            // The factory default LLM provider stays `.groq` until
            // onboarding (Sprint 2F Decision 8 / option C) flips a
            // user to `.local` after a successful HardwareProbe pass
            // + completed model download. Picking `.local` here would
            // hard-fail every first-launch on Intel / pre-download.
            localLLMModel: LocalLLMModelSpec.defaultSpec.id
        )
    }
}

enum InputMode: String, Codable, CaseIterable {
    case holdToTalk = "Hold to Talk"
    case toggle = "Toggle (Press/Press)"

    var displayName: String { rawValue }
}
