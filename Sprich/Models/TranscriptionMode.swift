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

    /// English baseline system prompts. Per-language localisation lives in
    /// `SystemPromptCatalog` — `LLMService.cleanup` looks up the right
    /// prompt by detected language and falls back to this EN baseline.
    ///
    /// **Literal is currently unused at runtime** — `PipelineCoordinator`
    /// skips the LLM entirely for `.literal` mode (see
    /// `PipelineCoordinator.swift:170,322,435-440`). The prompt is kept
    /// here for the contract — if a future code path ever routes Literal
    /// through the LLM (e.g. a hypothetical "Literal + LLM polish"
    /// feature), this is what would ship.
    ///
    /// **Formal's formatting rule is a deliberate if/else** that the 1B
    /// local model can follow without ambiguity. The Destination line is
    /// appended by `LLMService.composeSystemPrompt` when `adaptToSurface`
    /// is on and the resolved surface has a non-empty `promptHint`. All
    /// existing surface hints in `Surface.swift` already begin with
    /// `"Destination: …"` so no migration is required. Rationale at
    /// `proposed-prompt-change.md` § "Formal mode + surface adaptation".
    var defaultSystemPrompt: String {
        switch self {
        case .literal:
            return """
                Clean up the dictated text. Remove only filler words ('um', 'uh', 'ähm', 'so', 'like'), false starts, and stutters. Fix grammar mistakes that are clearly errors (subject-verb agreement, missing articles, basic punctuation). DO NOT paraphrase. DO NOT rephrase for style. DO NOT change word choice unless the word is grammatically wrong. DO NOT restructure sentences. DO NOT shorten or summarize. The output must read as the exact words the speaker said, only with the disfluencies removed. Maintain the input language. Output only the cleaned text, with no preamble or commentary.
                """

        case .formal:
            return """
                Rewrite the dictated text in a clear, professional register. Remove spoken artifacts (filler words, false starts, repetition) and fix grammar. Do not change the structure or meaning. Maintain the input language. Output only the rewritten text, with no preamble or commentary.

                Formatting rule — follow exactly one of these two cases:
                (a) If a 'Destination:' line appears below this prompt, FOLLOW the destination's formatting guidance verbatim. The destination's rules about greetings, sign-offs, paragraph structure, and tone OVERRIDE the general guidance above.
                (b) If no 'Destination:' line appears below, produce plain prose with no greeting, no sign-off, no subject line, and no other framing — unless the user explicitly dictated such framing themselves.
                """

        case .custom:
            return """
                Transform the dictated text according to the user's instructions. Do not add anything the user did not ask for. Maintain the input language unless the user explicitly requested a change. Output only the transformed text, with no preamble or commentary.
                """
        }
    }
}
