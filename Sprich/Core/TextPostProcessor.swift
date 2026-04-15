import Foundation

/// Post-processes raw STT output:
/// 1. Applies user glossary replacements (case-insensitive, whole-word)
/// 2. For literal mode: capitalizes first letter and ensures a terminal punctuation mark
enum TextPostProcessor {

    /// Apply glossary find→replace pairs, case-insensitive, whole-word where possible.
    static func applyGlossary(_ text: String, replacements: [GlossaryReplacement]) -> String {
        var result = text
        for rep in replacements {
            let from = rep.from.trimmingCharacters(in: .whitespaces)
            let to = rep.to
            guard !from.isEmpty else { continue }

            // Escape regex metacharacters in `from`
            let escaped = NSRegularExpression.escapedPattern(for: from)
            // Whole-word match if the term is alphanumeric; otherwise literal match
            let pattern: String
            if from.range(of: "^[\\w\\s'’-]+$", options: .regularExpression) != nil {
                pattern = "(?i)\\b\(escaped)\\b"
            } else {
                pattern = "(?i)\(escaped)"
            }

            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: to)
            )
        }
        return result
    }

    /// Polish literal-mode output so it feels like written text:
    /// - Capitalize the first alphabetic character
    /// - Ensure it ends with `.`, `!`, `?`, `…`
    static func polishLiteral(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Capitalize first letter (find first letter char, uppercase it)
        var chars = Array(trimmed)
        for i in 0..<chars.count {
            if chars[i].isLetter {
                chars[i] = Character(chars[i].uppercased())
                break
            }
        }
        var result = String(chars)

        // Ensure terminal punctuation
        let terminators: Set<Character> = [".", "!", "?", "…", ":", ";"]
        if let last = result.last, !terminators.contains(last) {
            // Strip any trailing whitespace/quotes we might be inside of
            result += "."
        }
        return result
    }

    /// Build a single Whisper `prompt` string that biases toward:
    /// - proper punctuation/capitalization (literal mode)
    /// - user glossary vocabulary
    static func whisperBiasPrompt(
        glossaryTerms: String,
        includePunctuationHint: Bool
    ) -> String? {
        var parts: [String] = []
        if includePunctuationHint {
            parts.append("The following is a dictation. Transcribe with proper punctuation and capitalization.")
        }
        let terms = glossaryTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty {
            parts.append("Vocabulary: \(terms)")
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}
