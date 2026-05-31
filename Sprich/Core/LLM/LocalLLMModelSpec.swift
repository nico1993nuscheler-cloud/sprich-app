import Foundation

/// Static spec for an on-device LLM weight file.
///
/// Pins everything `LLMModelManager` needs to download, verify, and store a
/// model deterministically: the Hugging Face source repo, the pinned commit
/// SHA (so we don't track `main`), the GGUF filename within that repo, the
/// expected file size in bytes (drives download UX copy), and the expected
/// SHA-256 (post-download verification — llama.cpp loaders do not verify).
struct LocalLLMModelSpec: Equatable {

    /// Stable user-facing identifier — `<model>-<quant>` slug.
    /// Used as the on-disk folder name segment alongside the pinned SHA
    /// (per distribution plan § C5 — versioned by SHA so a future update
    /// can sit alongside the old version without overwriting mid-inference).
    let id: String

    /// Short human label for Settings UI ("Gemma 4 E2B (Q4_K_M)").
    let displayName: String

    /// Tier label shown in the model picker ("High Quality" / "Standard").
    /// Outcome-focused naming per product decision — doesn't leak vendor
    /// branding into the primary user-facing choice.
    let tierName: String

    /// One-line quality/speed note shown under the picker.
    let tierNote: String

    /// Hugging Face repo path, e.g. `bartowski/google_gemma-4-E2B-it-GGUF`.
    let hfRepo: String

    /// Pinned commit SHA on the HF repo. NEVER `main`.
    let revision: String

    /// Filename within the repo at the pinned revision.
    let gguf: String

    /// Expected on-disk size in bytes (pulled from the repo at the pinned
    /// revision). Drives "Downloading 3.5 GB…" copy.
    let expectedSize: Int64

    /// Expected SHA-256 digest of the GGUF file. Captured at wiring time
    /// after the pinned revision is locked. `LLMModelManager.ensureReady`
    /// verifies bytes-on-disk against this before handing off to the
    /// llama.cpp loader. Empty string is a placeholder that must refuse
    /// to verify.
    let sha256: String

    /// Extra strings treated as end-of-sequence tokens by llama.cpp for
    /// this model family's chat template. Gemma 3 emits `<end_of_turn>` /
    /// `<start_of_turn>`; Gemma 4 changed the turn tokens to `<turn|>` /
    /// `<|turn>`. Stored per-spec so `LocalLLMService` doesn't hardcode one
    /// family's tokens while serving the other.
    let eosTokens: [String]

    // MARK: - Phase 1 ship variants

    /// **High Quality** — Gemma 4 E2B-it, GGUF Q4_K_M. The install default.
    ///
    /// Apache 2.0 (clean AppSumo redistribution). ~4.5B effective params
    /// (8B with Per-Layer Embeddings). Fixes the Gemma-3-1B email-shape
    /// failures (recipient-name drop, sign-off blank-line gap, multi-topic
    /// paragraph split) validated 2026-05-29 via LocalLLMClient bench.
    ///
    /// Pinned 2026-05-29 from `bartowski/google_gemma-4-E2B-it-GGUF`:
    /// - Revision: commit `b5e99bd…` (HF main as of 2026-05-03)
    /// - File SHA-256 (Git-LFS `oid`): `b5310340…`
    /// - Size: 3,462,678,272 bytes (~3.5 GB on disk)
    ///
    /// Gemma 4 thinking mode does NOT trigger through LocalLLMClient
    /// (empty template context → `enable_thinking` undefined → no
    /// `<|think|>` token), verified empirically — so no reasoning-strip is
    /// needed and there is no per-call thinking latency.
    static let highQualitySpec = LocalLLMModelSpec(
        id: "gemma-4-E2B-it-q4_k_m",
        displayName: "Gemma 4 E2B (Q4_K_M)",
        tierName: "High Quality",
        tierNote: "Best formatting quality. ~3.5 GB. Recommended on 16 GB+ Macs.",
        hfRepo: "bartowski/google_gemma-4-E2B-it-GGUF",
        revision: "b5e99bd964eaacc27ba484bb2eb3e9f6160b9143",
        gguf: "google_gemma-4-E2B-it-Q4_K_M.gguf",
        expectedSize: 3_462_678_272,
        sha256: "b5310340b3a23d31655d7119d100d5df1b2d8ee17b3ca8b0a23ad7e9eb5fa705",
        eosTokens: ["<turn|>", "<|turn>"]
    )

    /// **Standard** — Gemma 3 1B-it, GGUF Q4_K_M. Smaller, faster, lower
    /// formatting fidelity. The opt-in choice for download-size- or
    /// RAM-constrained Macs.
    ///
    /// Pinned 2026-05-17 from `bartowski/google_gemma-3-1b-it-GGUF`:
    /// - Revision: commit `116f762…` (HF main as of 2025-03-12; stable since)
    /// - File SHA-256 (Git-LFS `oid`): `12bf0fff…`
    /// - Size: 806,058,496 bytes (~0.81 GB on disk)
    static let standardSpec = LocalLLMModelSpec(
        id: "gemma-3-1b-it-q4_k_m",
        displayName: "Gemma 3 1B (Q4_K_M)",
        tierName: "Standard",
        tierNote: "Smaller and faster. ~0.8 GB. Lighter formatting polish.",
        hfRepo: "bartowski/google_gemma-3-1b-it-GGUF",
        revision: "116f76234503685a98f572982177b11d44ec8ff1",
        gguf: "google_gemma-3-1b-it-Q4_K_M.gguf",
        expectedSize: 806_058_496,
        sha256: "12bf0fff8815d5f73a3c9b586bd8fee8e7b248c935de70dec367679873d0f29d",
        eosTokens: ["<end_of_turn>", "<start_of_turn>"]
    )

    /// Install default — High Quality (Gemma 4 E2B). Greenfield launch
    /// (no existing users), so no migration concern; new installs land on
    /// E2B and can switch to Standard in Settings.
    static let defaultSpec = highQualitySpec

    /// All selectable specs, in picker order (default first).
    static let all: [LocalLLMModelSpec] = [highQualitySpec, standardSpec]

    /// Resolve a spec by its persisted ID (`AppSettings.localLLMModel`).
    /// Falls back to `defaultSpec` for unknown/legacy IDs so a stale
    /// settings.json never strands the user on a nonexistent spec.
    static func spec(forID id: String) -> LocalLLMModelSpec {
        all.first { $0.id == id } ?? defaultSpec
    }

    /// Resolve the spec the user currently has selected.
    static func resolved(from settings: AppSettings) -> LocalLLMModelSpec {
        spec(forID: settings.localLLMModel)
    }
}
