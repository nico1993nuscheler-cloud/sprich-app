# Contributing to Sprich

Sprich is **source-available, not open source** — licensed under
[BUSL 1.1](./LICENSE) with auto-conversion to MPL 2.0 on 2030-05-04. That
shapes how contributions work here.

## What kind of contributions are welcome

**Yes, please:**

- Bug reports — file an [Issue](https://github.com/nico1993nuscheler-cloud/sprich-app/issues)
  with repro steps, macOS version, and Sprich version (menu bar → About)
- Fixes for bugs you've filed (or any open issue tagged `good-first-pr`)
- Accessibility improvements
- Documentation fixes (typos, broken links, unclear instructions)
- Small, focused improvements to existing features

**Probably no, ask first:**

- New providers (additional STT or LLM backends) — Sprich's provider list is
  curated. Open an Issue before implementing.
- New modes beyond Literal / Formal / Custom — the three-mode design is
  intentional.
- Refactors that don't fix a concrete bug or unblock a feature

**No:**

- Feature additions intended to be shipped in a competing fork — the BUSL
  Additional Use Grant explicitly excludes commercial redistribution.

## Submitting a PR

1. Fork, branch off `main`, open the PR against `main`
2. Keep the diff small and focused — one logical change per PR
3. Match the existing code style (Swift formatting follows the in-repo
   conventions; no `.swiftformat` config means: look at neighboring files)
4. Include a short test plan in the PR description — what you did to verify
   the change works
5. Update the README or in-code docs if your change affects user-facing
   behavior or build steps

## CLA / IP

By submitting a contribution you grant Nico Nuscheler a perpetual, worldwide,
royalty-free license to use, modify, and relicense your contribution under
BUSL 1.1 and its eventual MPL 2.0 conversion. This is necessary because Sprich
is sold commercially under the same license; without this, contributed code
couldn't ship in the paid build.

There's no separate CLA form to sign — opening a PR is your acceptance of the
above.

## Building from source

See the [Build from source](./README.md#build-from-source) section of the
README. Personal, non-commercial builds are explicitly permitted under the
BUSL Additional Use Grant.

## Security

Don't file security issues as public Issues — email `security@sprichapp.com`.
See [SECURITY.md](./SECURITY.md).
