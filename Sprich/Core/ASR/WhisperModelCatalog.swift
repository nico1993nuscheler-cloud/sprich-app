import Foundation

/// Curated list of WhisperKit model variants exposed to the user in
/// Settings. Names correspond to `WhisperKit.download(variant:)` inputs —
/// the `openai_whisper-` prefix is added internally by `WhisperKit`.
///
/// Criteria for inclusion:
/// - Multilingual where possible (DE is Phase 2 territory but Phase 1
///   creator users also record in several languages — we don't ship
///   `.en`-only variants here).
/// - Meaningful speed/accuracy tradeoff between tiers. Picker options
///   that differ by <10% speed don't earn a slot.
/// - All available in `argmaxinc/whisperkit-coreml` so no custom repo
///   plumbing is needed.
struct WhisperModelOption: Identifiable, Hashable {
    let id: String        // also used as the WhisperKit `variant` name
    let displayName: String
    let subtitle: String
    let approxSizeMB: Int

    var variantName: String { id }
}

enum WhisperModelCatalog {

    /// Small multilingual — fastest end of the ramp.
    /// Accuracy is noticeably lower on German and rare vocabulary; best
    /// for English casual dictation where latency matters more than WER.
    static let fast = WhisperModelOption(
        id: "small_216MB",
        displayName: "Fast",
        subtitle: "~216 MB · smaller model, fastest latency · weaker on German & rare words",
        approxSizeMB: 216
    )

    /// Same accuracy ceiling as `.accurate`, but with OpenAI's pruned
    /// turbo decoder (8 layers vs 32). Typically ~2× faster inference.
    /// Recommended default for new installs.
    static let balanced = WhisperModelOption(
        id: "large-v3-v20240930_turbo_632MB",
        displayName: "Balanced (recommended)",
        subtitle: "~632 MB · large-v3 turbo · ~2× faster than Accurate with same accuracy ceiling",
        approxSizeMB: 632
    )

    /// Full non-turbo large-v3. Highest accuracy, slowest decode.
    /// Existing users started here — it's the original default.
    static let accurate = WhisperModelOption(
        id: "large-v3-v20240930_626MB",
        displayName: "Accurate",
        subtitle: "~626 MB · large-v3 full decoder · highest accuracy, slower decode",
        approxSizeMB: 626
    )

    static let all: [WhisperModelOption] = [Self.fast, Self.balanced, Self.accurate]

    /// Look up a `WhisperModelOption` by its stored variant id.
    /// Returns `nil` if the saved name doesn't match a catalog entry —
    /// users can still run with an arbitrary saved name, we just can't
    /// render the friendly picker row for it.
    static func option(for variantName: String) -> WhisperModelOption? {
        all.first { $0.variantName == variantName }
    }
}
