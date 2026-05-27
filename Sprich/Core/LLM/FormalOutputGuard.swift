import Foundation
import NaturalLanguage

/// Output gate for the two-pass Formal pipeline.
///
/// Formal mode runs `TextPostProcessor.polishLiteral` (Pass 1) before the
/// LLM (Pass 2). Pass 2 is asked to fix grammar and lift register only —
/// no added greetings, no answered questions, no list-of-five-taglines
/// when the dictation was the question itself. The system prompt states
/// that contract; this module enforces it post-call.
///
/// Contract:
///   1. The LLM's output, after model-artifact cleanup, must contain the
///      same number of sentences as the Pass-1 input, ±1 sentence (one
///      legitimate split or merge of a clear run-on).
///   2. The output character count must be at least `minimumLengthRatio`
///      of the Pass-1 character count (skipped for very short inputs
///      where the ratio is noisy). Catches content gutting where the
///      sentence count is preserved but most of the content is dropped
///      — e.g. Gemma 3 1B observed collapsing "Please suggest five
///      taglines for a Mac dictation app." (54 chars, 1 sentence) into
///      "Mac Dictation App." (18 chars, 1 sentence). Sentence-count
///      check alone passes that; length floor catches it.
///   3. The output character count must not exceed `maximumLengthRatio`
///      of the Pass-1 character count (skipped for very short inputs).
///      Catches the "model paraphrased and added content while keeping
///      a single sentence" case — e.g. Gemma 3 1B observed expanding
///      "Bitte gib mir 5 Slogans für meine App." (38 chars) into the
///      English "Please suggest five launch tagline ideas for a Mac
///      dictation app." (65 chars). 65/38 = 1.71 trips this guard.
///   4. The detected language of the output must match the detected
///      language of the Pass-1 input. Catches cross-language
///      hallucination on small multilingual models — same case as #3,
///      where Gemma 3 1B silently translated German into English
///      despite the system prompt explicitly demanding the source
///      language be preserved.
///   5. The output must not be empty / all-whitespace.
///
/// On breach, `enforce(...)` returns the Pass-1 text — the user always
/// gets at least the Literal-quality result. The fallback is silent by
/// product decision (no banner, no inline marker).
///
/// Shared between `LLMService` (cloud) and `LocalLLMService` (local) so
/// the guarantee is structural, not per-provider.
enum FormalOutputGuard {

    /// Result of running the LLM output through the guard pipeline.
    struct Result {
        /// The text to paste — either the cleaned LLM output or, on
        /// contract breach, the Pass-1 text unchanged.
        let text: String
        /// True when the contract failed and Pass-1 was substituted.
        let usedFallback: Bool
        /// Diagnostic reason for fallback. nil on success. DEBUG-log only.
        let fallbackReason: String?
    }

    /// Sentence-count delta tolerance. ±1 allows a legitimate split or
    /// merge of one run-on sentence; a model adding a greeting + sign-off
    /// adds at least two sentences and trips the guard.
    static let sentenceCountTolerance: Int = 1

    /// Output character count must be at least this fraction of the
    /// Pass-1 character count. Catches content-gutting failures the
    /// sentence-count check can't see (model collapses a polished
    /// sentence into a noun-phrase fragment of the same sentence count).
    /// 0.5 is conservative — legitimate compression of a rambly
    /// dictation typically lands in 0.6–0.8.
    static let minimumLengthRatio: Double = 0.5

    /// Output character count must not exceed this multiple of the
    /// Pass-1 character count. Catches "same sentence count but the
    /// model rewrote with substituted content and added words"
    /// failures (German→English hallucination case). 1.6 leaves
    /// comfortable headroom for legitimate cleanup:
    /// - "Thanks." → "Thank you." is 1.43×
    /// - "wanna" → "want to" expansions in a paragraph are ~1.1×
    /// - polished-prose round-trip is ~1.0×
    /// while still tripping on the 1.71× cross-language paraphrase
    /// observed on Gemma 3 1B.
    static let maximumLengthRatio: Double = 1.6

    /// Below this Pass-1 character count the length-ratio checks are
    /// skipped — short dictations ("Thanks." → "Thank you.") have
    /// noisy ratios where the rules would do more harm than good.
    static let minimumLengthCheckChars: Int = 20

    /// Minimum text length (characters) at which language detection is
    /// reliable enough to act on. `NLLanguageRecognizer` is noisy on
    /// very short strings — a single word like "App." can resolve to
    /// any of a dozen languages. 12 characters is the threshold below
    /// which we skip the language-drift check.
    static let minimumLanguageCheckChars: Int = 12

    /// Output must overlap this fraction of Pass-1's content words.
    /// Content words = words ≥4 characters, lowercased — an effective
    /// stopword filter that avoids shipping per-language stopword
    /// tables. Catches "same length, same sentence count, same
    /// language, but completely substituted content" failures the
    /// other guards can't see — e.g. Gemma 3 1B observed turning
    /// "The release is scheduled for Tuesday. Please review the
    /// changelog prior to the release." (7 content words) into
    /// "Please suggest five launch tagline ideas for a Mac dictation
    /// app." (1 word overlap = 14%) on 2026-05-27.
    ///
    /// 0.5 is the empirical threshold:
    /// - Cross-substituted content lands at 0–20% (trips)
    /// - Legitimate rambly→polish lands at ~50–55% (passes by margin)
    /// - Polished-prose round-trip is ~85–100% (passes easily)
    static let minimumContentRecall: Double = 0.5

    /// Below this Pass-1 character count the content-recall check is
    /// skipped. Aligns with the local-LLM `shortInputBypassChars` so
    /// the recall check only runs in the regime where Pass-1 has
    /// enough content to make recall meaningful.
    static let minimumContentRecallChars: Int = 25

    /// Below this many extracted content words in Pass-1, skip recall.
    /// With too few words the ratio is too coarse — a single missed
    /// word swings recall by 33%+ and produces noisy false positives.
    static let minimumContentRecallWordCount: Int = 3

    /// Minimum word length (characters) to count as a "content word"
    /// in the recall check. Acts as a poor-man's stopword filter:
    /// catches "the", "a", "is", "to", "for", "and", "of" (all EN)
    /// and "der", "die", "das", "ist", "und", "für" (all DE) without
    /// hard-coding any list.
    static let contentWordMinLength: Int = 4

    /// Enforce the contract on `rawLLMOutput`.
    ///
    /// `language` is the ISO 639-1 source language code (or nil for
    /// auto-detect) — used to hint `NLTokenizer`'s sentence boundaries.
    static func enforce(
        pass1Text: String,
        rawLLMOutput: String,
        language: String?
    ) -> Result {
        let cleaned = stripWrappingQuotes(stripPreamble(rawLLMOutput))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            return Result(text: pass1Text, usedFallback: true, fallbackReason: "empty output after cleanup")
        }

        // Length-ratio checks. Run BEFORE the sentence-count check so
        // the more specific "too short / too long" diagnostic surfaces
        // when both would fire. Skip when Pass-1 is short — short
        // dictations have noisy ratios and the sentence-count check
        // is sufficient there.
        let pass1Chars = pass1Text.count
        let outputChars = cleaned.count
        if pass1Chars >= Self.minimumLengthCheckChars {
            let ratio = Double(outputChars) / Double(pass1Chars)
            if ratio < Self.minimumLengthRatio {
                return Result(
                    text: pass1Text,
                    usedFallback: true,
                    fallbackReason: String(
                        format: "output too short (%d chars vs pass1=%d, ratio=%.2f)",
                        outputChars, pass1Chars, ratio
                    )
                )
            }
            if ratio > Self.maximumLengthRatio {
                return Result(
                    text: pass1Text,
                    usedFallback: true,
                    fallbackReason: String(
                        format: "output too long (%d chars vs pass1=%d, ratio=%.2f)",
                        outputChars, pass1Chars, ratio
                    )
                )
            }
        }

        // Language-drift check. Catches the case where a small model
        // (Gemma 3 1B on a German dictation) silently translates the
        // input to English. Source-of-truth for the expected language:
        // (1) the caller-supplied `language` if non-nil, else (2) the
        // detected language of `pass1Text`. We skip the check when
        // either text is too short for reliable language detection.
        if pass1Chars >= Self.minimumLanguageCheckChars,
           outputChars >= Self.minimumLanguageCheckChars,
           let expectedLang = resolveExpectedLanguage(pass1Text: pass1Text, hint: language),
           let outputLang = detectLanguage(cleaned),
           expectedLang != outputLang {
            return Result(
                text: pass1Text,
                usedFallback: true,
                fallbackReason: "language drift (expected=\(expectedLang.rawValue), out=\(outputLang.rawValue))"
            )
        }

        // Content-recall check. Catches "same length, same sentence
        // count, same language, but completely substituted content"
        // hallucination — e.g. Gemma 3 1B turning an 87-char prose
        // paragraph into the 65-char tagline example phrase. None of
        // the structural guards above can see this; the only signal
        // is that the output shares almost no content words with the
        // input. See `minimumContentRecall` doc above for the
        // threshold rationale.
        if pass1Chars >= Self.minimumContentRecallChars {
            let pass1Words = contentWords(in: pass1Text)
            if pass1Words.count >= Self.minimumContentRecallWordCount {
                let outputWords = contentWords(in: cleaned)
                let matched = pass1Words.intersection(outputWords)
                let recall = Double(matched.count) / Double(pass1Words.count)
                if recall < Self.minimumContentRecall {
                    return Result(
                        text: pass1Text,
                        usedFallback: true,
                        fallbackReason: String(
                            format: "content drift (recall=%.2f, matched=%d/%d)",
                            recall, matched.count, pass1Words.count
                        )
                    )
                }
            }
        }

        let pass1Count = countSentences(pass1Text, language: language)
        let outputCount = countSentences(cleaned, language: language)
        let delta = abs(outputCount - pass1Count)
        if delta > sentenceCountTolerance {
            return Result(
                text: pass1Text,
                usedFallback: true,
                fallbackReason: "sentence-count delta \(delta) (pass1=\(pass1Count), out=\(outputCount))"
            )
        }

        return Result(text: cleaned, usedFallback: false, fallbackReason: nil)
    }

    // MARK: - Language detection

    /// Resolve the expected language for an output. Prefer the explicit
    /// `hint` (ISO 639-1 code from settings / STT auto-detect), and only
    /// fall back to detecting from `pass1Text` when no hint is provided.
    private static func resolveExpectedLanguage(
        pass1Text: String,
        hint: String?
    ) -> NLLanguage? {
        if let hint, let nl = nlLanguage(for: hint) {
            return nl
        }
        return detectLanguage(pass1Text)
    }

    /// Dominant language of `text` via `NLLanguageRecognizer`. nil when
    /// the recognizer can't decide.
    private static func detectLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    // MARK: - Content-word recall

    /// Lowercased set of words ≥`contentWordMinLength` chars from
    /// `text`. The length filter doubles as a stopword filter — it
    /// drops "the", "a", "is", "to" (EN) and "der", "die", "ist",
    /// "und" (DE) without shipping per-language tables. Tokenization
    /// is via `NLTokenizer(.word)` which is Unicode-aware and handles
    /// hyphens, apostrophes, and CJK correctly.
    static func contentWords(in text: String) -> Set<String> {
        var words: Set<String> = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if word.count >= Self.contentWordMinLength {
                words.insert(word)
            }
            return true
        }
        return words
    }

    // MARK: - Sentence counting

    /// Count sentences via Apple's `NaturalLanguage` framework. Honors the
    /// caller-supplied language hint when present; otherwise lets the
    /// tokenizer auto-detect.
    static func countSentences(_ text: String, language: String?) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .sentence)
        if let code = language, let nlLanguage = nlLanguage(for: code) {
            tokenizer.setLanguage(nlLanguage)
        }
        tokenizer.string = trimmed
        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    private static func nlLanguage(for code: String) -> NLLanguage? {
        switch code.lowercased() {
        case "en": return .english
        case "de": return .german
        case "fr": return .french
        case "es": return .spanish
        case "it": return .italian
        case "pt": return .portuguese
        case "nl": return .dutch
        case "pl": return .polish
        case "sv": return .swedish
        case "tr": return .turkish
        case "ru": return .russian
        case "ar": return .arabic
        case "hi": return .hindi
        case "zh": return .simplifiedChinese
        case "ja": return .japanese
        default:   return nil
        }
    }

    // MARK: - Model-artifact cleanup
    //
    // Both `stripPreamble` and `stripWrappingQuotes` were originally
    // local to `LocalLLMService` (where the small Gemma 1B model needed
    // them most). They are equally useful for cloud responses on small
    // cloud models, so the cleanup pipeline is shared here.

    /// LLM-conversational-opener strippers. Two failure modes:
    ///
    /// **Mode A — single-line preamble flush against content:**
    ///   `"Here is the rewritten text: Sehr geehrter Herr Müller,…"`
    ///
    /// **Mode B — meta-paragraph + blank line + content:**
    ///   `"Please provide the text you would like me to rewrite.\n\nHello,…"`
    ///
    /// Strict guardrails on Mode B:
    /// - Bounded to dropping AT MOST the first paragraph
    /// - First paragraph must be SHORT (< 120 chars)
    /// - Must contain a narrow meta-marker
    /// - There must be a second paragraph (single-paragraph outputs are
    ///   never stripped, even if they happen to mention "please")
    static func stripPreamble(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for preamble in preambleExactPrefixes {
            if trimmed.hasPrefix(preamble) {
                let dropped = trimmed.dropFirst(preamble.count)
                return String(dropped).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let parts = trimmed.components(separatedBy: "\n\n")
        if parts.count >= 2 {
            let first = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLower = first.lowercased()
            if first.count < 120,
               metaParagraphMarkers.contains(where: { firstLower.contains($0) }) {
                return parts.dropFirst()
                    .joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }

    /// Strip whole-output wrapping quotation marks. Gemma 3 1B sometimes
    /// treats its output as "the rewritten quote" and wraps it in curly
    /// quotes — observed on cloud models too, less frequently.
    ///
    /// Conservative rule: strip only if both first and last characters
    /// are quote-like, only one outer pair, only with ≥3 chars between.
    static func stripWrappingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3,
              let first = trimmed.first,
              let last = trimmed.last else {
            return trimmed
        }
        guard wrappingOpeners.contains(first), wrappingClosers.contains(last) else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Static data

    private static let preambleExactPrefixes: [String] = [
        "Here is the rewritten text:",
        "Here's the rewritten text:",
        "Here is the cleaned text:",
        "Here's the cleaned text:",
        "Here is the polished text:",
        "Here's the polished text:",
        "Hier ist der überarbeitete Text:",
        "Hier ist der bereinigte Text:",
        "Hier der überarbeitete Text:"
    ]

    private static let metaParagraphMarkers: [String] = [
        "please provide",
        "would like me to",
        "what would you like",
        "i'd be happy to",
        "of course",
        "sure!",
        "sure,",
        "okay,",
        "okay!",
        "got it",
        "here is the rewritten",
        "here's the rewritten",
        "here is the cleaned",
        "here's the cleaned",
        "here is the polished",
        "here's the polished",
        "hier ist der",
        "i can help you",
        "let me know"
    ]

    private static let wrappingOpeners: Set<Character> = [
        "\"",        // ASCII straight double
        "\u{201C}",  // English left double curly
        "'",         // ASCII straight single
        "\u{2018}",  // English left single curly
        "«",         // French left guillemet
        "\u{201E}"   // German continental „
    ]

    private static let wrappingClosers: Set<Character> = [
        "\"",        // ASCII straight double
        "\u{201D}",  // English right double curly
        "'",         // ASCII straight single
        "\u{2019}",  // English right single curly
        "»",         // French right guillemet
        "\u{201C}"   // German continental closing "
    ]
}
