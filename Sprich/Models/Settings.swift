import Foundation

// MARK: - Provider Enums

enum STTProviderType: String, Codable, CaseIterable {
    case groq = "Groq Whisper"
    case openai = "OpenAI Whisper"
    case deepgram = "Deepgram Nova-3"

    var displayName: String { rawValue }

    var baseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
        case .openai: return "https://api.openai.com/v1/audio/transcriptions"
        case .deepgram: return "https://api.deepgram.com/v1/listen"
        }
    }

    var keychainKey: String {
        switch self {
        case .groq: return "sprich.api.groq"
        case .openai: return "sprich.api.openai"
        case .deepgram: return "sprich.api.deepgram"
        }
    }

    /// Billing / upgrade dashboard users are pointed at when rate-limited.
    var dashboardURL: String {
        switch self {
        case .groq: return "https://console.groq.com/settings/billing"
        case .openai: return "https://platform.openai.com/account/billing"
        case .deepgram: return "https://console.deepgram.com/billing"
        }
    }
}

enum LLMProviderType: String, Codable, CaseIterable {
    case groq = "Groq (fastest)"
    case claude = "Claude (Anthropic)"
    case google = "Gemini (Google)"
    case openai = "OpenAI"

    var displayName: String { rawValue }

    var keychainKey: String {
        switch self {
        case .groq: return "sprich.api.groq"  // Same key as STT
        case .claude: return "sprich.api.anthropic"
        case .google: return "sprich.api.google"
        case .openai: return "sprich.api.openai"
        }
    }

    var dashboardURL: String {
        switch self {
        case .groq: return "https://console.groq.com/settings/billing"
        case .claude: return "https://console.anthropic.com/settings/billing"
        case .google: return "https://aistudio.google.com/apikey"
        case .openai: return "https://platform.openai.com/account/billing"
        }
    }
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

    var hasRequiredAPIKeys: Bool {
        let sttKey = KeychainManager.retrieve(key: sttProvider.keychainKey)
        let llmKey = KeychainManager.retrieve(key: llmProvider.keychainKey)
        return sttKey != nil && llmKey != nil
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

    static var defaults: AppSettings {
        AppSettings(
            sttProvider: .groq,
            llmProvider: .groq,
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
            maxRecordingDuration: 300
        )
    }
}

enum InputMode: String, Codable, CaseIterable {
    case holdToTalk = "Hold to Talk"
    case toggle = "Toggle (Press/Press)"

    var displayName: String { rawValue }
}
