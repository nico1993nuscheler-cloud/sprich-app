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

    /// Per-surface guard policy. Different destinations legitimately
    /// restructure Pass-1 in different ways — an email adds greeting +
    /// sign-off scaffolding, a task description compresses prose into
    /// an imperative title plus optional bulleted sub-points, an AI
    /// chat prompt drops politeness and surfaces constraints as
    /// bullets — so a single fixed contract trips on shape changes the
    /// destination explicitly asked for.
    ///
    /// The hallucination filters (`minimumLengthRatio`,
    /// `minimumContentRecall`, language drift) stay constant across
    /// surfaces; only the structural-shape upper bounds vary.
    struct Policy {
        /// Allowed delta between Pass-1 and output sentence counts.
        let sentenceCountTolerance: Int
        /// Output character count must not exceed
        /// `pass1Chars * maximumLengthRatio + scaffoldAllowanceChars`.
        let maximumLengthRatio: Double
        /// Fixed extra characters allowed on top of the ratio — covers
        /// FIXED scaffolding the destination adds regardless of input length
        /// (an email greeting + sign-off + paragraph breaks ≈ 30-60 chars).
        /// On a short dictation this fixed cost blows past a pure ratio: a
        /// real 71-char "Hi Maria…" email polished to 181 chars is 2.55× —
        /// it would trip a 2.5× cap even though it's correct. The allowance
        /// fixes that without loosening the ratio for long inputs (where the
        /// "answered the question → 5× list" hallucination still trips).
        var scaffoldAllowanceChars: Int = 0
    }

    /// Default policy — applies to surfaces that do not restructure
    /// Pass-1 (chat surfaces, docs, generic). ±1 sentence split + ≤1.6×
    /// length covers legitimate polishing while still tripping the
    /// 1.71× cross-language paraphrase observed on Gemma 3 1B.
    // v1.0.14 — formalizing rambly speech legitimately splits one run-on into
    // several clean sentences, so ±1 was rejecting good rewrites of exactly the
    // dictation Formal mode is FOR. ±6 admits restructuring; the over-expansion
    // backstop is the length ratio (1.8×) + content recall, not sentence count.
    static let defaultPolicy = Policy(
        sentenceCountTolerance: 6,
        maximumLengthRatio: 1.8
    )

    /// Email policy. Greeting + sign-off add at minimum +2 sentences
    /// over Pass-1 (often +3 with a body split), and lift short inputs
    /// well past the default 1.6× length ceiling (a 30-char Pass-1
    /// becomes ~50 chars at ~1.67×; a 64-char Pass-1 becomes ~120 at
    /// ~1.87×). 2.5× still catches the "answered the question"
    /// hallucination — a question becomes a 5×-length numbered list.
    static let emailPolicy = Policy(
        sentenceCountTolerance: 4,
        maximumLengthRatio: 2.5,
        scaffoldAllowanceChars: 90   // greeting + sign-off + paragraph breaks
    )

    /// Task-manager policy (ClickUp / Linear / Notion / Jira / Asana
    /// / Trello / Todoist / Things / Monday / Height / Basecamp / …).
    /// Output is an imperative task description, often expanded into a
    /// title line + bulleted sub-points when the dictation carried
    /// context. Each bullet typically reads as its own sentence to
    /// `NLTokenizer`, so a 1-sentence input with 3 bullets lands at
    /// delta=3; ±5 covers up to 5 bullets without leaking the
    /// "wrote the work instead of describing it" failure (which
    /// produces paragraphs of prose, not a tight bullet list).
    /// Length cap stays moderate (1.8×) — task descriptions are
    /// usually shorter or close to Pass-1; large expansion is a red
    /// flag.
    // Structured ticket: a bold title line + bulleted acceptance criteria.
    // Title + up to several bullets each read as a sentence (±6); markdown
    // markers (** **, "- ") and the new title line add fixed chars on top of
    // a moderate 2.0× expansion. A "wrote the work instead of the ticket"
    // failure still produces prose far past this and trips.
    static let taskManagerPolicy = Policy(
        sentenceCountTolerance: 6,
        maximumLengthRatio: 2.0,
        scaffoldAllowanceChars: 90   // title line + bullet/bold markdown markers
    )

    /// AI-chat policy (ChatGPT / Claude / Gemini / Copilot / Perplexity
    /// / DeepSeek / Mistral / Grok / Poe / Phind / You.com / …). Output
    /// is a direct imperative prompt; politeness words ("please",
    /// "could you") drop out, and dictated constraints may surface as a
    /// bulleted list. Similar shape budget to task-manager: ±5
    /// sentences for bullets, ≤1.8× length. Imperative prompts
    /// typically compress input, so the upper bound is rarely the
    /// active check — the hallucination filters (content recall,
    /// language drift) carry the protection.
    static let aiChatPolicy = Policy(
        sentenceCountTolerance: 5,
        maximumLengthRatio: 1.8,
        scaffoldAllowanceChars: 40   // bulleted constraints
    )

    /// Docs policy. Output preserves prose structure with paragraph
    /// breaks and lists when dictated. Slightly looser than default —
    /// ±2 sentences for a paragraph split, ≤1.8× length for inline
    /// expansion. Still tighter than email/task because docs do not
    /// add scaffolding the user didn't dictate.
    static let docsPolicy = Policy(
        sentenceCountTolerance: 2,
        maximumLengthRatio: 1.8
    )

    /// Resolve the policy for a destination surface. Chat surfaces
    /// (Slack / Messages / Google Chat / Teams / Discord) and
    /// `.generic` use the default; every restructuring surface gets
    /// its own band.
    static func policy(for surface: Surface) -> Policy {
        switch surface {
        case .email:                                   return emailPolicy
        case .taskManager:                             return taskManagerPolicy
        case .aiChat:                                  return aiChatPolicy
        case .docs:                                    return docsPolicy
        case .slack, .messages, .googleChat, .teams,
             .discord, .generic:                       return defaultPolicy
        }
    }

    /// Output character count must be at least this fraction of the
    /// Pass-1 character count. Catches content-gutting failures the
    /// sentence-count check can't see (model collapses a polished
    /// sentence into a noun-phrase fragment of the same sentence count).
    /// 0.5 is conservative — legitimate compression of a rambly
    /// dictation typically lands in 0.6–0.8.
    ///
    /// Shared across surfaces. Surfaces that compress harder than 0.5×
    /// (task-manager, ai-chat on very rambly inputs) typically come in
    /// at 0.55–0.7 in practice; if we ever see legitimate sub-0.5×
    /// compression on those, lift this per-surface too.
    static let minimumLengthRatio: Double = 0.5

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
    /// v1.0.14 — lowered 0.5 → 0.20. 0.5 was rejecting GOOD formalizations:
    /// elevating word choice ("rerun" → "review and update", "stuff" →
    /// "statements", "legally compliant" → "legal compliance") is exactly
    /// Formal mode's job, and it drops word-overlap with the input. Measured
    /// on real E2B output: genuine professional rewrites land at 0.31–0.52
    /// (the privacy-pages clip was 0.31 and got discarded). True substitution
    /// (the Gemma-1B example below) is at 0.14, and an answered question is
    /// caught by the length-ratio (5×). 0.20 admits legitimate elevation while
    /// still tripping near-total substitution; length-ratio + language-drift
    /// carry the rest. Validated via the `FormalQuality` bench harness.
    /// - Cross-substituted content lands at ~0.14 (trips)
    /// - Legitimate rambly→professional rewrite lands at 0.31–0.55 (passes)
    static let minimumContentRecall: Double = 0.20

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

    /// Custom-mode runaway-generation ceiling (security item H1). Far looser
    /// than the Formal bands because Custom transforms legitimately expand
    /// (e.g. "turn these notes into bullet points"); 4× only trips on the
    /// essay-from-one-sentence signature of a *fulfilled* injected
    /// instruction. The primary anti-injection defense is the immutable
    /// Custom core; this is a backstop. See `enforceCustom`.
    static let customMaximumLengthRatio: Double = 4.0

    /// Enforce the contract on `rawLLMOutput`.
    ///
    /// `language` is the ISO 639-1 source language code (or nil for
    /// auto-detect) — used to hint `NLTokenizer`'s sentence boundaries.
    ///
    /// `surface` selects the sentence-count and length-ratio policy
    /// (see `policy(for:)`). Restructuring surfaces (email, task
    /// manager, AI chat, docs) get looser shape bounds because their
    /// destination prompts explicitly request shape changes; the
    /// hallucination filters (content recall, language drift, min
    /// length) stay constant across all surfaces.
    static func enforce(
        pass1Text: String,
        rawLLMOutput: String,
        language: String?,
        surface: Surface = .generic
    ) -> Result {
        let policy = Self.policy(for: surface)
        let cleaned = stripWrappingQuotes(stripPreamble(rawLLMOutput))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty {
            return Result(text: pass1Text, usedFallback: true, fallbackReason: "empty output after cleanup")
        }

        let pass1Chars = pass1Text.count
        let outputChars = cleaned.count
        let maxRatio = policy.maximumLengthRatio
        let ratio = Double(outputChars) / Double(max(pass1Chars, 1))

        // Max-length ceiling — runs for EVERY input, including very short
        // ones (H3). With no real content a model regurgitates its own
        // system-prompt instructions: an 11-char dictation was observed
        // producing a 392-char restatement of the task-ticket guidelines.
        // The cap (ratio*pass1 + fixed scaffold allowance) makes that
        // impossible — an 11-char task input caps at ~112 chars.
        let maxChars = Double(pass1Chars) * maxRatio + Double(policy.scaffoldAllowanceChars)
        if Double(outputChars) > maxChars {
            let detail = String(
                format: "output too long (%d chars vs pass1=%d, ratio=%.2f, cap=%.2f+%d",
                outputChars, pass1Chars, ratio, maxRatio, policy.scaffoldAllowanceChars
            )
            return Result(
                text: pass1Text,
                usedFallback: true,
                fallbackReason: "\(detail), surface=\(surface.debugLabel))"
            )
        }

        // Min-length floor — gated to longer inputs only; the ratio is noisy
        // on short dictations ("Thanks." → "Thank you." is a legit 1.4×).
        if pass1Chars >= Self.minimumLengthCheckChars, ratio < Self.minimumLengthRatio {
            return Result(
                text: pass1Text,
                usedFallback: true,
                fallbackReason: String(
                    format: "output too short (%d chars vs pass1=%d, ratio=%.2f)",
                    outputChars, pass1Chars, ratio
                )
            )
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

        // Scaffold surfaces (email) legitimately ADD a greeting line and a
        // sign-off line that NLTokenizer counts as sentences — that alone
        // inflated a real "Hi Maria" email to delta 5 (pass1=2, out=7) and
        // got the full email rejected. Strip those scaffold lines before
        // counting so the contract measures the body, not the envelope. The
        // length-ratio (≤2.5×) and content-recall guards above remain the
        // over-expansion backstop, so dropping scaffold from the count does
        // not weaken the "answered the question" catch.
        let pass1Count = scaffoldAdjustedSentenceCount(pass1Text, surface: surface, language: language)
        let outputCount = scaffoldAdjustedSentenceCount(cleaned, surface: surface, language: language)
        let delta = abs(outputCount - pass1Count)
        let tolerance = policy.sentenceCountTolerance
        if delta > tolerance {
            return Result(
                text: pass1Text,
                usedFallback: true,
                fallbackReason: "sentence-count delta \(delta) (pass1=\(pass1Count), out=\(outputCount), tol=\(tolerance), surface=\(surface.debugLabel))"
            )
        }

        return Result(text: cleaned, usedFallback: false, fallbackReason: nil)
    }

    /// Minimal output guard for Custom mode (security item H1). Custom
    /// legitimately reshapes text per the user's OWN configured instruction,
    /// so it is NOT held to the Formal sentence-count contract or the strict
    /// length band. The primary anti-injection defense is the immutable
    /// Custom core (`SystemPromptCatalog`). This is a backstop: it runs the
    /// same model-artifact cleanup as before and additionally catches the
    /// runaway-generation signature of a *fulfilled* injected instruction —
    /// a short dictation ballooning into a long generated answer. On breach
    /// it returns the sanitized input, so the user gets their own words and
    /// never a silently-fulfilled injection. Language is intentionally NOT
    /// checked: a custom instruction may legitimately translate.
    static func enforceCustom(inputText: String, rawLLMOutput: String) -> Result {
        let cleaned = stripWrappingQuotes(stripPreamble(rawLLMOutput))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return Result(text: inputText, usedFallback: true, fallbackReason: "empty output after cleanup")
        }
        // Runaway ceiling runs for EVERY input (incl. very short) — a tiny
        // dictation must never balloon into a long generation (H3). Fixed
        // floor (+60) keeps legit short transforms ("OK" → "Okay.") passing.
        let inputChars = inputText.count
        let ratio = Double(cleaned.count) / Double(max(inputChars, 1))
        let maxChars = Double(inputChars) * Self.customMaximumLengthRatio + 60
        if Double(cleaned.count) > maxChars {
            return Result(
                text: inputText,
                usedFallback: true,
                fallbackReason: String(
                    format: "custom output too long (%d chars vs input=%d, ratio=%.2f, cap=%.2f+60)",
                    cleaned.count, inputChars, ratio, Self.customMaximumLengthRatio
                )
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

    /// Sentence count with email-scaffold lines excluded. For `.email` the
    /// model is asked to add a greeting line and a sign-off line; those count
    /// as sentences to `NLTokenizer` and inflate the delta even when the body
    /// matches Pass-1 one-for-one. Drop a leading greeting and a trailing
    /// sign-off before counting so the sentence-count contract measures the
    /// body. No-op for non-scaffold surfaces.
    static func scaffoldAdjustedSentenceCount(
        _ text: String, surface: Surface, language: String?
    ) -> Int {
        guard surface == .email else {
            return countSentences(text, language: language)
        }
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = lines.first, isEmailScaffoldLine(first) { lines.removeFirst() }
        if let last = lines.last, isEmailScaffoldLine(last) { lines.removeLast() }
        return countSentences(lines.joined(separator: " "), language: language)
    }

    /// Heuristic for an email greeting/sign-off line: a short line ending in
    /// a comma ("Hi Maria," / "Best," / "Thanks,"). Language-agnostic — it
    /// keys on the scaffold convention the email hint prescribes, not a
    /// per-language word list. Conservative length cap so a real one-line
    /// body sentence that happens to end in a comma is not mistaken for it.
    private static func isEmailScaffoldLine(_ line: String) -> Bool {
        line.count <= 40 && line.hasSuffix(",")
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
