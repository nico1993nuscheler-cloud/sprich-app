# Sprich

**Native macOS dictation. Hold keys, speak, release.** 15 languages, three modes
(Literal / Formal / Custom), works fully offline.

*Sprich* is German for "speak" (imperative). Press the shortcut. Sprich.

> **Source-available**, not open source. Sprich is licensed under
> [BUSL 1.1](./LICENSE) with a personal-use grant for building from source, and
> auto-conversion to MPL 2.0 on **2030-05-04**. Commercial use — including any
> use within an organization or distribution of compiled binaries — requires a
> commercial license at [sprichapp.com](https://sprichapp.com). See [NOTICE.md](./NOTICE.md).

---

## Try it

The fastest way to use Sprich is the signed, notarized build at
**[sprichapp.com](https://sprichapp.com)** — a **7-day free trial, no credit
card**, then a **one-time $59** (one Mac seat, no subscription, all updates on
the current major version).

> The $59 one-time price is a **limited launch deal**. After the launch window
> Sprich moves to a subscription; buyers during the launch keep their one-time
> license.

Trial activates after email verification. The full app is unlocked for 7 days
with no feature gating; after day 7 it prompts you to upgrade.

If you'd rather build from source for your own personal, non-commercial use,
that's permitted under BUSL — see [Build from source](#build-from-source) below.

## How it works

```
Hold keys → Record → Whisper STT → LLM cleanup → Auto-paste
```

1. **Hold `fn + shift`** — Literal mode (cleans up your words, keeps your voice)
2. **Hold `fn + control`** — Formal mode (restructures into professional written text)
3. **Hold `fn + cmd`** — Custom mode (your own prompt)
4. **Release** — text is transcribed, cleaned, and pasted into whatever app you're using

Works everywhere: email, Slack, browser, notes, terminal — any text field on macOS.

## Three modes

| Mode | Shortcut | What it does |
|---|---|---|
| **Literal** | `fn + shift` | Removes filler words, false starts, mid-sentence corrections. Keeps your voice. |
| **Formal** | `fn + control` | Restructures into professional written text, adapting to the app you're in. Great for emails and business. |
| **Custom** | `fn + cmd` | Your own prompt. Configure a Slack tone, bullet points, or any niche style in Settings. |

All three prompts are fully editable in **Settings → Modes**. Sprich also
**learns from your corrections** over time, so the output gradually reads more
like the way you actually write.

## Languages

15 languages, transcribed via local Whisper (offline) or a cloud STT provider:

> English, German, Spanish, French, Portuguese, Italian, Dutch, Polish,
> Swedish, Turkish, Russian, Arabic, Hindi, Chinese, Japanese.

Auto-detect is on by default. Force a language in the menu bar **→ Language**.

## Offline mode

Sprich ships with a local Whisper engine (via WhisperKit). Pick a model in
**Settings → Providers → Local**:

| Model | Disk | Speed | Quality |
|---|---|---|---|
| **Fast** (small) | ~216 MB | fastest | weaker on German & rare words |
| **Balanced** (large-v3 turbo) | ~632 MB | fast (~2× Accurate) | strong all-round — **default for new installs** |
| **Accurate** (large-v3) | ~626 MB | slower | highest accuracy, slowest decode |

On-device cleanup runs a small local LLM (Gemma) so the full pipeline —
transcription *and* polish — works with no network and no API key.

If your default provider is a cloud STT (Groq / OpenAI / Deepgram) and the
network is unreachable, Sprich auto-falls-back to Local for the current
dictation only. Your saved provider preference isn't mutated.

## Build from source

For **personal, non-commercial use only** under the BUSL Additional Use Grant —
see [LICENSE](./LICENSE) for the exact terms.

```bash
git clone https://github.com/nico1993nuscheler-cloud/sprich-app.git
cd sprich-app
xcodebuild -project Sprich.xcodeproj -scheme Sprich -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/Sprich-*/Build/Products/Release/Sprich.app
```

Requires:
- macOS 14 (Sonoma) or later
- [Xcode](https://apps.apple.com/app/xcode/id497799835) (free)
- A Groq API key for cloud STT (optional — Local mode works with no key) at
  [console.groq.com/keys](https://console.groq.com/keys)

### Self-build vs. licensed build — what's different

| | Self-build | Licensed build (sprichapp.com) |
|---|---|---|
| Code signing | ad-hoc (Gatekeeper warns on first launch) | Apple Developer ID (no warnings) |
| Notarization | none | full notarization + stapling |
| Auto-updates | none — `git pull` + rebuild | Sparkle in-app updates |
| Support | community (GitHub Issues, best-effort) | priority support@sprichapp.com |
| Use scope | personal, non-commercial only | full BUSL Additional Use Grant for the buyer |

The two builds are otherwise functionally identical — same Swift source, same
modes, same languages, same offline engine.

## Setup

On first launch, Sprich walks you through:

1. **Accessibility permission** — needed for global keyboard shortcuts and auto-paste
2. **Microphone permission** — needed to record your voice
3. **Provider choice** — Local (offline, no key) or Cloud (Groq recommended for speed)
4. **API key** (cloud only) — stored in macOS Keychain via `kSecClassGenericPassword`

## Privacy

Sprich is built so its privacy claims are verifiable in the source code:

- **API keys** live in macOS Keychain, never in `UserDefaults`, never on disk
  in plaintext, never in crash logs.
- **Audio** is captured into an in-memory buffer, WAV-encoded in RAM, sent
  directly to your chosen STT provider (or processed locally), then released.
  No temp files, no cache, no local recording.
- **No telemetry by default**. There is no first-party analytics tied to
  dictation content. Account, license, and trial-validation calls go to
  Sprich's EU backend (Supabase, Frankfurt) and contain no audio or transcripts.
- **Clipboard safety**: when Sprich pastes, it saves your existing clipboard
  first and restores it afterwards.
- **Not a keylogger**: the global hotkey uses a `CGEvent` tap that listens
  *only* for `flagsChanged` events (modifier-key combos). Regular keystrokes
  pass through untouched.

Sprich runs **outside** the macOS App Sandbox — required for the global hotkey
and simulated-paste mechanism. Same trade-off every menu-bar dictation tool
makes. The "no disk access / no camera / no contacts" guarantees are
enforced by the **code**, which you can read.

## Architecture

```
Sprich/
├── Core/
│   ├── ASR/                        # Local Whisper engine (WhisperKit)
│   │   ├── LocalWhisperService.swift
│   │   ├── WhisperModelManager.swift
│   │   ├── WhisperModelCatalog.swift
│   │   └── PCMConverter.swift
│   ├── LLM/                        # On-device LLM cleanup (local Gemma) + guards
│   │   ├── LocalLLMService.swift
│   │   ├── LLMModelManager.swift
│   │   ├── SystemPromptCatalog.swift
│   │   └── FormalOutputGuard.swift
│   ├── Auth/                       # Account + license validation (Supabase, Frankfurt)
│   ├── Trial/                      # 7-day trial state
│   ├── AudioRecorder.swift         # AVAudioEngine mic capture (in-memory)
│   ├── HotkeyManager.swift         # Global hotkeys via CGEvent tap (flagsChanged only)
│   ├── TranscriptionService.swift  # Cloud STT (Groq / OpenAI / Deepgram) + Local
│   ├── LLMService.swift            # Cloud LLM cleanup (Gemini / Claude / OpenAI / Groq)
│   ├── CorrectionLearner.swift     # Self-learning from your edits
│   ├── SurfaceDetector.swift       # Destination-aware Formal mode
│   ├── HistoryStore.swift          # Local dictation history
│   ├── TextInserter.swift          # Clipboard-safe paste (original clipboard restored)
│   ├── TextPostProcessor.swift     # Glossary + find/replace post-processing
│   ├── NetworkReachability.swift   # Offline auto-fallback signal
│   └── PipelineCoordinator.swift   # Orchestrates the full pipeline
├── Security/
│   ├── KeychainManager.swift       # Secure API key storage
│   ├── InputSanitizer.swift        # Control-char stripping before LLM calls
│   └── Permissions.swift           # Accessibility + Microphone handling
├── Views/                          # SwiftUI — Settings, Onboarding, RecordingOverlay
│                                   #   (cream-pill HUD), account / sign-in, trial lock,
│                                   #   model downloaders
└── Models/
    ├── TranscriptionMode.swift     # Literal / Formal / Custom definitions
    ├── Settings.swift              # Codable config + supported languages
    ├── Surface.swift               # Surface-aware Formal-mode targets
    └── ModeTokens.swift            # Brand color tokens
```

Built with Swift, SwiftUI, AppKit, AVFoundation,
[WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT) for local STT, and a
local Gemma model for on-device cleanup.

## License

Source-available under [BUSL 1.1](./LICENSE):

- **Licensor**: Nico Nuscheler
- **Licensed Work**: Sprich (the macOS dictation app)
- **Additional Use Grant**: personal, non-commercial use, including
  building from source for your own personal use. Any other use requires a
  commercial license at [sprichapp.com](https://sprichapp.com).
- **Change Date**: 2030-05-04
- **Change License**: MPL 2.0

The pre-relicense MIT history is preserved in
[`LICENSE-MIT-historic`](./LICENSE-MIT-historic). The full background on the
dual-state license history is in [`NOTICE.md`](./NOTICE.md).

## Links

- Buy / try: [sprichapp.com](https://sprichapp.com)
- Support: [support@sprichapp.com](mailto:support@sprichapp.com)
- Bug reports: [GitHub Issues](https://github.com/nico1993nuscheler-cloud/sprich-app/issues)
- Licensing questions: [licensing@sprichapp.com](mailto:licensing@sprichapp.com)
