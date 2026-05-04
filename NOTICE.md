# NOTICE

Sprich is **source-available** software, not open source. It is licensed under the
[Business Source License 1.1](./LICENSE) (BUSL 1.1) with auto-conversion to the
[Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/) (MPL 2.0)
on **2030-05-04**.

This file explains the dual-state license history of this repository so that
auditors, contributors, and downstream users have a clear picture of what
applies to which commits.

## License history

| Period | License | Scope |
|---|---|---|
| Initial commit → relicense commit | MIT | All commits up to and including the commit immediately before the BUSL relicense commit. The MIT text is preserved verbatim in [`LICENSE-MIT-historic`](./LICENSE-MIT-historic). |
| Relicense commit onward | BUSL 1.1 | All commits from the BUSL relicense commit onward. The BUSL text with Sprich's parameters is in [`LICENSE`](./LICENSE). |
| Change Date 2030-05-04 onward | MPL 2.0 | Same Sprich source covered by BUSL above auto-converts to MPL 2.0. No further action by the Licensor required. |

The relicense was a unilateral act by the sole copyright holder (Nico Nuscheler).
At the time of relicense, this repository had no external contributors of record
under any other identity, so no third-party rights were affected.

## What you can do under the current BUSL 1.1

In short — and never as a substitute for reading [`LICENSE`](./LICENSE) yourself:

- **Personal, non-commercial use**: permitted, including building from source
  for your own personal use.
- **Reading, auditing, learning from the source**: permitted.
- **Modifying for personal use**: permitted.
- **Use within an organization**, deployment for paying customers, or
  distribution of compiled binaries: requires a commercial license.
- **Forking publicly**: permitted (BUSL doesn't prohibit forks), but downstream
  users of your fork are bound by the same BUSL terms unless they obtain a
  commercial license.

A commercial license, including the lifetime AppSumo deal during Phase 1, is
available at [https://sprichapp.com](https://sprichapp.com).

## Why BUSL and not MIT, Apache 2.0, or fully proprietary?

- **MIT / Apache 2.0** would let a competitor fork the codebase and undercut
  the commercial offering wholesale. Sprich is a single-author project with
  zero VC runway, so a clone-and-undercut would end the project.
- **Fully proprietary / closed source** would deny users the ability to audit
  the dictation pipeline — and Sprich's privacy claims (no audio on disk, no
  telemetry beyond explicit consent, Keychain-only credential storage, etc.)
  are only credible if the code is readable.
- **BUSL 1.1** lands in between: source is public, you can audit and self-build
  for personal use, but a competitor cannot legally ship a productized fork.
  The 4-year auto-conversion to MPL 2.0 means even the commercial moat is
  time-boxed — every release becomes properly open-source on a known date.

## Further reading

- BUSL 1.1 FAQ (general): [https://mariadb.com/bsl-faq-adopting/](https://mariadb.com/bsl-faq-adopting/)
- MariaDB's BUSL FAQ: [https://mariadb.com/bsl-faq-mariadb/](https://mariadb.com/bsl-faq-mariadb/)
- MPL 2.0 (Sprich's Change License): [https://www.mozilla.org/en-US/MPL/2.0/](https://www.mozilla.org/en-US/MPL/2.0/)
- Commercial licensing for Sprich: [https://sprichapp.com](https://sprichapp.com)
- Licensing questions: [licensing@sprichapp.com](mailto:licensing@sprichapp.com)
