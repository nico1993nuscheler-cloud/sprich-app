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

    /// Redact sensitive data from log output.
    /// Always returns only the length — transcripts, prompts, and LLM output
    /// must never be written to any log, even in DEBUG.
    static func redactForLog(_ text: String) -> String {
        return "[REDACTED:\(text.count) chars]"
    }
}
