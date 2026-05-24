import Foundation

/// Sanitizes text before sending to LLM APIs.
/// Prevents injection attacks via crafted transcriptions.
enum InputSanitizer {

    /// Remove control characters and potential injection patterns from transcript text.
    static func sanitize(_ text: String) -> String {
        var sanitized = text

        // Remove control characters (except newline and tab)
        sanitized = sanitized.unicodeScalars
            .filter { scalar in
                scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
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
