import Foundation

/// Static spec for an on-device LLM weight file.
///
/// Pins everything `LLMModelManager` needs to download, verify, and store a
/// model deterministically: the Hugging Face source repo, the pinned commit
/// SHA (so we don't track `main`), the GGUF filename within that repo, the
/// expected file size in bytes (drives download UX copy), and the expected
/// SHA-256 (post-download verification — llama.cpp loaders do not verify).
///
/// Source plan: `~/Claude/40_Projects/Sprich/local-llm-distribution-plan.md`
/// §§ C1, C2, C3.
struct LocalLLMModelSpec: Equatable {

    /// Stable user-facing identifier — `<model>-<quant>` slug.
    /// Used as the on-disk folder name segment alongside the pinned SHA
    /// (per distribution plan § C5 — versioned by SHA so a future update
    /// can sit alongside the old version without overwriting mid-inference).
    let id: String

    /// Short human label for Settings UI ("Gemma 3 1B (Q4_K_M)").
    let displayName: String

    /// Hugging Face repo path, e.g. `bartowski/google_gemma-3-1b-it-GGUF`.
    let hfRepo: String

    /// Pinned commit SHA on the HF repo. NEVER `main`.
    /// Filled in at wiring time (P2-LLM-05 ticket). Empty string here is
    /// a placeholder that `LLMModelManager.ensureReady` must refuse to
    /// download against — we'd rather fail loudly than fetch HEAD.
    let revision: String

    /// Filename within the repo at the pinned revision.
    let gguf: String

    /// Expected on-disk size in bytes (pulled from the bartowski README at
    /// the pinned revision). Drives "Downloading 0.81 GB…" copy.
    let expectedSize: Int64

    /// Expected SHA-256 digest of the GGUF file. Captured at wiring time
    /// after the pinned revision is locked. `LLMModelManager.ensureReady`
    /// verifies bytes-on-disk against this before handing off to the
    /// llama.cpp loader. Empty string is a placeholder that must refuse
    /// to verify.
    let sha256: String

    /// Phase 1 ship variant — Gemma 3 1B-it, GGUF Q4_K_M.
    ///
    /// Pinned 2026-05-17 from `bartowski/google_gemma-3-1b-it-GGUF`:
    /// - Revision: commit `116f762…` (HF main as of 2025-03-12; stable since)
    /// - File SHA-256 (Git-LFS `oid`): `12bf0fff…`
    /// - Size: 806,058,496 bytes (~0.81 GB on disk)
    ///
    /// The HF Git-LFS `oid` IS the SHA-256 of the file content by LFS design,
    /// so `LLMModelManager.verify` can stream-hash the downloaded file and
    /// match it byte-identically against this value.
    static let defaultSpec = LocalLLMModelSpec(
        id: "gemma-3-1b-it-q4_k_m",
        displayName: "Gemma 3 1B (Q4_K_M)",
        hfRepo: "bartowski/google_gemma-3-1b-it-GGUF",
        revision: "116f76234503685a98f572982177b11d44ec8ff1",
        gguf: "google_gemma-3-1b-it-Q4_K_M.gguf",
        expectedSize: 806_058_496,
        sha256: "12bf0fff8815d5f73a3c9b586bd8fee8e7b248c935de70dec367679873d0f29d"
    )
}
