import Foundation

enum TranscriptionMode: String, Codable, Equatable, CaseIterable {
    case literal
    case formal
    case custom

    var displayName: String {
        switch self {
        case .literal: return "Literal"
        case .formal:  return "Formal"
        case .custom:  return "Custom"
        }
    }

    /// Short single-character badge shown in the overlay HUD.
    var defaultBadgeLetter: String {
        switch self {
        case .literal: return "L"
        case .formal:  return "F"
        case .custom:  return "C"
        }
    }

    var defaultSystemPrompt: String {
        switch self {
        case .literal:
            return "Clean up dictated text. Remove fillers, false starts, fix grammar. Keep original wording and tone. Maintain input language (DE/EN). Output only cleaned text."

        case .formal:
            return "Rewrite dictated text as professional written text for emails/business. Remove spoken artifacts, improve structure and formality. Maintain input language (DE/EN). Output only final text."

        case .custom:
            return "Transform the dictated text according to the user's instructions. Maintain input language. Output only the transformed text."
        }
    }
}
