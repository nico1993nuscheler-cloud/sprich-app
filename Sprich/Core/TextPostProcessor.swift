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

    /// Per-surface deterministic shape normalisation. Runs AFTER the LLM
    /// (and after `FormalOutputGuard`) so it normalises the final output
    /// regardless of which provider produced it. No-op for surfaces that
    /// don't have a known structural shape, and no-op when no
    /// greeting/sign-off pattern is detected.
    ///
    /// Rationale: small models (Gemma 3 1B observed 2026-05-29) sometimes
    /// apply only HALF the email shape — e.g. add `\n\n` after greeting
    /// but glue the sign-off straight to the last body sentence. Capable
    /// cloud models usually frame correctly but occasionally don't.
    /// Doing it deterministically post-LLM makes the shape guarantee
    /// structural, not aspirational.
    ///
    /// Current rules:
    /// - `.email`: ensure `\n\n` after greeting line and before sign-off
    ///   line when both patterns match
    /// - all other surfaces: pass-through
    static func normalizeShape(_ text: String, surface: Surface) -> String {
        switch surface {
        case .email: return normalizeEmailParagraphBreaks(text)
        default:     return text
        }
    }

    /// Greeting patterns (line-leading, ≤80 chars, ending in `,` or `:`).
    /// Covers EN + DE since those are the empirically validated
    /// languages; FR/ES/IT/PT/NL added since the patterns are cheap and
    /// the cost of a false negative is just "no normalisation".
    private static let emailGreetingPattern: String =
        #"^\s*(Hi|Hello|Hey|Dear|Good (?:morning|afternoon|evening)|Hallo|Servus|Moin|Guten (?:Morgen|Tag|Abend)|Sehr geehrte[rn]?|Bonjour|Salut|Hola|Buenos d[ií]as|Ciao|Buongiorno|Ol[áa]|Bom dia|Beste|Goedemorgen|Goedendag)\b[^\n]{0,80}?[,:]"#

    /// Sign-off patterns. Matches a short final line (≤60 chars) that
    /// starts with a recognised closing word. The trailing `.` Gemma
    /// sometimes emits ("Best.") is tolerated alongside the more common
    /// `,`.
    private static let emailSignOffPattern: String =
        #"^\s*(Thanks(?: (?:so much|a lot|again))?|Many thanks|Best|Best regards|Kind regards|Warm regards|Regards|Cheers|Sincerely|Yours(?: sincerely| truly)?|Talk soon|Speak soon|Looking forward|Mit freundlichen Gr[üu][ßs]en|MfG|Viele Gr[üu][ßs]e|Beste Gr[üu][ßs]e|Liebe Gr[üu][ßs]e|Herzliche Gr[üu][ßs]e|Cordialement|Bien (?:à vous|cordialement)|Saludos|Saludos cordiales|Atentamente|Un saludo|Cordiali saluti|Distinti saluti|Saluti|Cumprimentos|Atenciosamente|Met vriendelijke groet|Groeten)\b[^\n]{0,60}?[,.]?\s*$"#

    /// Ensure the email body has blank lines framing the greeting and
    /// sign-off. Idempotent — calling twice produces the same result.
    private static func normalizeEmailParagraphBreaks(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var result = trimmed

        // Greeting normalisation: find first line, if it matches the
        // greeting pattern, ensure `\n\n` separates it from the body.
        if let firstLineRange = result.range(of: "\n") {
            let firstLine = String(result[..<firstLineRange.lowerBound])
            let rest = String(result[firstLineRange.upperBound...])
            if firstLine.range(of: Self.emailGreetingPattern, options: .regularExpression) != nil {
                // Strip any leading whitespace/newlines from `rest`, then
                // re-attach with exactly one blank line between.
                let restTrimmed = rest.drop(while: { $0 == "\n" || $0 == " " || $0 == "\t" })
                result = "\(firstLine)\n\n\(restTrimmed)"
            }
        } else {
            // Whole text is a single line. Check if it starts with a
            // greeting AND has body content after the greeting's comma —
            // e.g. "Hi Maria, I wanted to follow up... Best." If yes,
            // split into greeting + body inline.
            // Conservative: only act when the greeting is short and
            // there's substantial content after.
            if let match = result.range(of: Self.emailGreetingPattern, options: .regularExpression),
               match.lowerBound == result.startIndex,
               match.upperBound < result.endIndex {
                let greeting = String(result[..<match.upperBound])
                let body = String(result[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if body.count >= 20 {
                    result = "\(greeting)\n\n\(body)"
                }
            }
        }

        // Sign-off normalisation: find last line, if it matches the
        // sign-off pattern AND there's preceding body, ensure `\n\n`
        // separates it.
        if let lastNewlineRange = result.range(of: "\n", options: .backwards) {
            let lastLine = String(result[lastNewlineRange.upperBound...])
            let before = String(result[..<lastNewlineRange.lowerBound])
            if lastLine.range(of: Self.emailSignOffPattern, options: .regularExpression) != nil,
               !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let beforeTrimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
                result = "\(beforeTrimmed)\n\n\(lastLine)"
            }
        } else {
            // Whole text is a single line. Look for a sign-off in the
            // tail. Pattern: ". Best." or ". Thanks," at the end.
            // Find the LAST sentence-terminator followed by a sign-off
            // pattern up to end of string.
            let tailPattern = #"([.!?])\s+((?:Thanks|Best|Regards|Cheers|Sincerely|Kind regards|Best regards|Mit freundlichen Gr[üu][ßs]en|MfG|Viele Gr[üu][ßs]e|Beste Gr[üu][ßs]e)\b[^\n]{0,60}?[,.]?)\s*$"#
            if let regex = try? NSRegularExpression(pattern: tailPattern) {
                let range = NSRange(result.startIndex..., in: result)
                if let m = regex.firstMatch(in: result, options: [], range: range),
                   m.numberOfRanges >= 3,
                   let term = Range(m.range(at: 1), in: result),
                   let signoff = Range(m.range(at: 2), in: result) {
                    let head = String(result[..<term.upperBound])
                    let tail = String(result[signoff.lowerBound...])
                    result = "\(head)\n\n\(tail)"
                }
            }
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
