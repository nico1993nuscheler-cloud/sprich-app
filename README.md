# Sprich

**Open-source macOS speech-to-text.** Hold two keys, speak, release — cleaned text appears wherever your cursor is.

*Sprich* is German for "speak" (imperative). Press the shortcut. Sprich.

## Why

Tools like Wispr Flow charge ~$20/month for voice-to-text. Sprich does the same thing for ~$2/month in API costs — and the code is yours to audit, fork, and modify.

## How it works

```
Hold keys → Record → Whisper STT → LLM Cleanup → Auto-paste
```

1. **Hold `fn + shift`** — Literal mode (cleans up your words, keeps your voice)
2. **Hold `fn + control`** — Formal mode (restructures into professional written text)
3. **Hold `fn + cmd`** — Custom mode (your own prompt — e.g. Slack tone, bullet points)
4. **Release** — text is transcribed, cleaned, and pasted into whatever app you're using

Works everywhere: email, Slack, browser, notes, terminal — any text field on macOS.

## Three modes

| Mode | Shortcut | What it does |
|------|----------|-------------|
| **Literal** | `fn + shift` | Removes filler words, false starts, and mid-sentence corrections. Keeps your original wording and tone. |
| **Formal** | `fn + control` | Restructures into professional written text. Great for emails, Slack, and business communication. |
| **Custom** | `fn + cmd` | Your own prompt. Configure a Slack tone, bullet points, or any niche style in Settings. |

All three prompts are fully editable in Settings → Modes.

## STT providers (your choice)

| Provider | Cost/min | Speed | Setup |
|----------|----------|-------|-------|
| **Groq** (default) | $0.0007 | ~0.5s | [console.groq.com](https://console.groq.com/keys) |
| OpenAI | $0.006 | ~2s | [platform.openai.com](https://platform.openai.com/api-keys) |
| Deepgram | $0.008 | ~0.3s | [console.deepgram.com](https://console.deepgram.com) |

## LLM providers (your choice)

| Provider | Model | Setup |
|----------|-------|-------|
| **Gemini** (default) | gemini-2.5-flash | [aistudio.google.com](https://aistudio.google.com/app/apikey) |
| Claude | claude-haiku-4 | [console.anthropic.com](https://console.anthropic.com) |
| OpenAI | gpt-4o-mini | [platform.openai.com](https://platform.openai.com/api-keys) |

## Languages

Sprich auto-detects German and English out of the box. Force a specific language in the menu bar → Language.

## Install

### Requirements
- macOS 14 (Sonoma) or later
- [Xcode](https://apps.apple.com/app/xcode/id497799835) (free, for building from source)
- A Groq API key (free tier covers typical daily use)

### Option A — Build from source (recommended)
```bash
git clone https://github.com/nico1993nuscheler-cloud/sprich-app.git
cd sprich-app
./install.sh
```

This builds the app, copies it to `/Applications/`, and launches it. The onboarding flow guides you through permissions and API key setup.

### Option B — Pre-built DMG

Download the latest `.dmg` from the [Releases page](https://github.com/nico1993nuscheler-cloud/sprich-app/releases), drag `Sprich.app` to `/Applications/`, then open it.

> **First-launch note:** Because Sprich is ad-hoc signed (no paid Apple Developer account — this is a free open-source project), macOS Gatekeeper will warn you on first launch.
>
> **To open it the first time:** right-click `Sprich.app` in `/Applications/` → click **Open** → confirm **Open** in the dialog. You only need to do this once. After that, double-clicking works normally.

### Option C — Manual build
```bash
xcodebuild -project Sprich.xcodeproj -scheme Sprich -configuration Release build
```

## Setup

On first launch, Sprich walks you through:

1. **Accessibility permission** — needed for global keyboard shortcuts and auto-paste
2. **Microphone permission** — needed to record your voice
3. **Groq API key** — stored securely in macOS Keychain

Additional providers (OpenAI, Deepgram, Claude, Gemini) can be added later in Settings → API Keys.

## Cost

At 50 dictations/day (30 seconds each) with **Groq + Gemini**:
- **~$0/month** vs. $20/month for Wispr Flow
- Groq's free tier covers most daily use — often $0/month in practice

## Security & Privacy

Sprich is designed to be **auditable by you**. Every claim below is verifiable in the source code.

### No subscription, no account, no telemetry
Sprich never phones home. It doesn't check for updates. It doesn't send usage data. There is no backend — you bring your own API keys, and requests go directly from your Mac to the provider you chose.

### API keys live in macOS Keychain
- Stored via `kSecClassGenericPassword` (see [`KeychainManager.swift`](Sprich/Security/KeychainManager.swift))
- Never written to `UserDefaults`
- Never written to disk in plaintext
- Never included in crash logs or debug output

### Audio never touches disk
Your voice is captured into an in-memory buffer, WAV-encoded in RAM, sent directly to your chosen STT provider over TLS, then the buffer is released. There is no temp file, no cache, no local recording — verifiable in [`AudioRecorder.swift`](Sprich/Core/AudioRecorder.swift).

### Transport security
- TLS 1.2+ enforced on every API call (`URLSession` default + explicit `NSAppTransportSecurity` policy in Info.plist blocks all cleartext HTTP)
- Ephemeral `URLSession` config — no on-disk URL cache, no cookie storage, no credential storage
- No HTTP fallback anywhere
- No third-party networking libraries — just Foundation

### Clipboard safety
When Sprich pastes, it saves your existing clipboard first and restores it afterwards — even if the pipeline errors out. Your clipboard history is never altered.

### Not a keylogger
The global hotkey uses a `CGEvent` tap, but it **only listens for `flagsChanged` events** (modifier-key combos). Regular keystrokes pass through untouched. Sprich can't read what you type, and the tap's callback only checks whether your configured modifier combo is held — nothing else.

### Minimal entitlements
Sprich requests only:
- `com.apple.security.device.audio-input` — to record your voice
- Accessibility permission — for global shortcuts and simulated paste

No network-client entitlement, no full-disk access, no camera, no contacts, no location.

### About the App Sandbox
Sprich runs **outside** the macOS App Sandbox. This is not optional: the App Sandbox is incompatible with the CGEvent tap needed for global hotkeys and with the simulated-paste mechanism that inserts text into the focused app. Every menu-bar dictation tool (including the paid ones) makes the same trade-off.

What this means in practice: the "no disk access / no camera / no contacts" guarantees above are enforced by the **code**, not by the OS. The code is MIT-licensed and short enough to audit in an afternoon. If you want OS-level enforcement, don't run third-party menu-bar tools — but if you're going to run one, running one you can read beats running one you can't.

### Ad-hoc code signing
Sprich is signed ad-hoc (not with a paid Apple Developer ID) precisely because there's no centralized publisher. The trust model is "read the source, build it yourself." This means a Gatekeeper warning on first launch — that's the cost of having no backdoor channel.

### MIT-licensed
Every line of source is open. Fork it, audit it, build your own version.

## Architecture

```
Sprich/
├── Core/
│   ├── AppState.swift            # App state management
│   ├── AudioRecorder.swift       # AVAudioEngine microphone capture
│   ├── HotkeyManager.swift       # Global shortcuts via CGEvent tap (flagsChanged only)
│   ├── TranscriptionService.swift # Multi-provider STT (Groq/OpenAI/Deepgram)
│   ├── LLMService.swift          # Multi-provider LLM (Gemini/Claude/OpenAI)
│   ├── TextInserter.swift        # Clipboard + Cmd+V paste (original clipboard restored)
│   ├── TextPostProcessor.swift   # Glossary + find/replace post-processing
│   └── PipelineCoordinator.swift # Orchestrates the full pipeline
├── Security/
│   ├── KeychainManager.swift     # Secure API key storage
│   ├── InputSanitizer.swift      # Control-char stripping before LLM calls
│   └── Permissions.swift         # Accessibility + Microphone handling
├── Views/
│   ├── SettingsView.swift        # Full settings UI
│   ├── OnboardingView.swift      # First-launch setup
│   ├── RecordingOverlay.swift    # Voice-reactive KITT scanner overlay
│   └── ShortcutHelpView.swift    # Menu bar "How to use" window
└── Models/
    ├── TranscriptionMode.swift   # Literal/Formal/Custom mode definitions + default prompts
    └── Settings.swift            # Codable app configuration
```

Zero external dependencies. Built with Swift, SwiftUI, AppKit, and AVFoundation.

## Contributing

PRs welcome. Please keep it simple — no unnecessary dependencies, no feature creep. See [ARCHITECTURE.md](ARCHITECTURE.md) (coming soon) for design principles.

## License

[MIT](LICENSE)
