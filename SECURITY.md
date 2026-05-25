# Security Policy

## Reporting a vulnerability

If you believe you've found a security issue in Sprich — anything that could
expose user audio, API keys, license tokens, or otherwise compromise a Sprich
install — please **do not open a public GitHub issue**.

Email **security@sprichapp.com** with:

- A description of the issue and the impact
- Steps to reproduce (a minimal proof-of-concept if you have one)
- The Sprich version (menu bar → About) and macOS version
- Whether the issue is exploitable on a default, freshly-installed Sprich

You'll get an acknowledgement within 3 business days. We aim to ship a fix
within 30 days for high-severity issues. Critical issues (remote code
execution, key extraction, audio exfiltration) get a same-week patch.

## Scope

In scope:

- The Sprich macOS app (Swift source in this repository)
- The Sprich backend (license redemption, auth, transactional email) — source
  lives in a separate private repo; report anything you can reproduce from the
  client side via the same email
- The Sprich auto-update channel (Sparkle appcast + signed DMG delivery)

Out of scope:

- Third-party services Sprich integrates with (Groq, OpenAI, Deepgram, Gemini,
  Anthropic, LemonSqueezy) — report those to the respective vendor
- Social-engineering attacks on Sprich users
- Physical access to an unlocked Mac
- Self-XSS or issues that require the user to disable their own OS security
  features

## What counts as a security issue

Yes:

- API keys leaking out of macOS Keychain into UserDefaults, logs, or crash reports
- Audio being written to disk anywhere outside of explicit user opt-in
- The hotkey `CGEvent` tap capturing keystrokes other than `flagsChanged`
- License-validation bypass that grants Pro/Studio features on a trial install
- Any path that lets a remote attacker execute code via the auto-update channel

No:

- "The app runs outside the App Sandbox" — required for the global hotkey and
  simulated paste. Documented in the README.
- "The Supabase publishable key is embedded in the binary" — by design, see
  [`Sprich/Core/Auth/SupabaseConfig.swift`](./Sprich/Core/Auth/SupabaseConfig.swift).

## Disclosure

We'll credit you in the release notes for the fix unless you'd rather stay
anonymous. We don't pay bug bounties, but we're happy to send Sprich Studio
licenses as a thank-you for substantive reports.
