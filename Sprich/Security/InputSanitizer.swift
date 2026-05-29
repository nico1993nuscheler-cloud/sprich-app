import Foundation

/// Sanitizes text before sending to LLM APIs.
/// Prevents injection attacks via crafted transcriptions.
enum InputSanitizer {

    /// Chat-template control-token literals that MUST never reach an LLM as
    /// real tokens. On the local Gemma path the fully-rendered template
    /// (system + user) is tokenized in one pass with special-token parsing
    /// ON, so a dictation containing the literal string `<end_of_turn>` (etc.)
    /// injects a REAL control token — forging a turn boundary and escaping the
    /// "rewrite, never fulfill" contract. No system prompt can defend against
    /// this; it must be neutralized deterministically before tokenization.
    /// Covers Gemma 3 (`<start_of_turn>`/`<end_of_turn>`), Gemma 4
    /// (`<turn|>`/`<|turn>`), Llama/ChatML (`<|im_start|>`/`<|im_end|>`/
    /// `<|eot_id|>`/`<|end_of_text|>`) and BOS/EOS (`<bos>`/`<eos>`/`<s>`/`</s>`).
    /// Whitespace- and pipe-position-tolerant, case-insensitive. Applied to
    /// ALL providers (cloud role-separation helps, but several OpenAI-compatible
    /// tokenizers also honor these). Security audit C1, 2026-05-29.
    private static let controlTokenPattern: NSRegularExpression? = {
        let p = #"(?i)<\s*/?\s*\|?\s*(?:start_of_turn|end_of_turn|turn|bos|eos|s|im_start|im_end|eot_id|end_of_text|endoftext)\s*\|?\s*>"#
        return try? NSRegularExpression(pattern: p)
    }()

    /// Invisible / zero-width / format scalars that can smuggle instructions
    /// past human review (homoglyph & invisible-instruction attacks). Whisper
    /// never produces these from speech, but the glossary, Custom-prompt field,
    /// and clipboard-driven hotkey macros are non-voice text paths. Security
    /// audit M3, 2026-05-29. (Bidi overrides U+202A–202E / U+2066–2069 are
    /// handled separately for the paste path.)
    private static func isInvisibleFormatScalar(_ v: UInt32) -> Bool {
        (v >= 0x200B && v <= 0x200F) ||   // zero-width space..RLM
        (v >= 0x2060 && v <= 0x2064) ||   // word-joiner..invisible-plus
        v == 0xFEFF ||                     // zero-width no-break space / BOM
        (v >= 0xE0000 && v <= 0xE007F)     // Unicode Tag block (invisible instructions)
    }

    /// Remove control characters and potential injection patterns from transcript text.
    static func sanitize(_ text: String) -> String {
        var sanitized = text

        // Neutralize chat-template control-token literals BEFORE anything else
        // so a forged `<end_of_turn>`/`<|im_end|>`/etc. can never become a real
        // token downstream. Removed outright — legitimate dictation never
        // contains these exact bracketed tokens. (Audit C1.)
        if let regex = controlTokenPattern {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, range: range, withTemplate: " ")
        }

        // Remove control characters (except newline and tab) AND invisible
        // format/zero-width scalars (audit M3).
        sanitized = sanitized.unicodeScalars
            .filter { scalar in
                if scalar == "\n" || scalar == "\t" { return true }
                if CharacterSet.controlCharacters.contains(scalar) { return false }
                if isInvisibleFormatScalar(scalar.value) { return false }
                return true
            }
            .map { String($0) }
            .joined()

        // Remove null bytes
        sanitized = sanitized.replacingOccurrences(of: "\0", with: "")

        // Trim excessive whitespace
        let lines = sanitized.components(separatedBy: .newlines)
        sanitized = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        // Collapse multiple blank lines into one
        while sanitized.contains("\n\n\n") {
            sanitized = sanitized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitize text immediately before placing it on the pasteboard.
    /// Stricter than `sanitize()` for the LLM path, but **preserves whitespace
    /// structure** (newlines, tabs, multiple blank lines, leading/trailing
    /// whitespace) so user-formatted dictation arrives byte-faithful in the
    /// target field. Strips only characters that are unambiguously dangerous:
    /// - C0 control chars except `\n`, `\t`, `\r`
    /// - C1 control chars (U+0080..U+009F) — includes ANSI CSI start `\x9B`
    /// - NULL bytes (already covered by C0 above, but explicit)
    /// - Unicode bidirectional override / isolate format chars
    ///   (U+202A..U+202E, U+2066..U+2069) — Trojan Source (CVE-2021-42574)
    static func sanitizeForPaste(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)

        for scalar in text.unicodeScalars {
            let v = scalar.value
            // C0 controls (0x00..0x1F) except TAB, LF, CR
            if v < 0x20 {
                if v == 0x09 || v == 0x0A || v == 0x0D {
                    out.append(scalar)
                }
                continue
            }
            // DEL
            if v == 0x7F { continue }
            // C1 controls (0x80..0x9F)
            if v >= 0x80 && v <= 0x9F { continue }
            // Bidi overrides + isolates
            if (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069) {
                continue
            }
            // Invisible / zero-width / Tag-block format scalars (audit M3).
            if isInvisibleFormatScalar(v) { continue }
            out.append(scalar)
        }

        return String(out)
    }

    /// Redact sensitive data from log output.
    /// Always returns only the length — transcripts, prompts, and LLM output
    /// must never be written to any log, even in DEBUG.
    static func redactForLog(_ text: String) -> String {
        return "[REDACTED:\(text.count) chars]"
    }
}
