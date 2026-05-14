# Supabase auth email templates — Sprich

Canonical HTML for every transactional auth email Supabase sends on behalf of
the Sprich project (`djiixtplbsutuiuxfhiy`). Files here are the source of
truth; the live dashboard is mirrored from these via the Management API.

## Files

| File | Supabase template | Subject heading |
|---|---|---|
| `confirm-signup.html` | Confirm signup | Confirm your email — Sprich |
| `magic-link.html` | Magic Link | Sign in to Sprich |
| `reset-password.html` | Reset Password | Reset your Sprich password |
| `change-email.html` | Change Email Address | Confirm your new email — Sprich |
| `invite.html` | Invite user | You're invited to Sprich |
| `reauthentication.html` | Reauthentication | Your Sprich verification code |

`_base.html` is documentation only.

## Files are HTML fragments

Each file is a fragment (no `<!DOCTYPE>` / `<html>` / `<body>` wrapper).
Supabase wraps them server-side. Inline styles only — Gmail / Outlook strip
`<style>` blocks.

## Template variables

- `{{ .ConfirmationURL }}` — the verify link (signup / magic / recovery / invite / email-change)
- `{{ .Token }}` — 8-digit OTP code (reauthentication only; project has `mailer_otp_length=8`)
- `{{ .Email }}` — current account email (used in footer / context lines)
- `{{ .NewEmail }}` — new email (change-email template only)

## Deploy (push files → live dashboard)

The repo has a script that PATCHes the Management API in one shot:

```bash
export SUPABASE_PAT='<personal access token from supabase.com/dashboard/account/tokens>'
/tmp/sprich-patch-templates.sh
```

The script POSTs all 6 subjects + bodies, then GETs back and diffs each
against the local file. Exits non-zero on any mismatch.

To pull live → file (e.g. if someone edited a template in the dashboard):

```bash
curl -sS "https://api.supabase.com/v1/projects/djiixtplbsutuiuxfhiy/config/auth" \
  -H "Authorization: Bearer $SUPABASE_PAT" | jq -r '.mailer_templates_magic_link_content'
```

## Manual fallback (no PAT)

If you don't have a PAT handy, open
https://supabase.com/dashboard/project/djiixtplbsutuiuxfhiy/auth/templates,
pick a template tab, set the **Subject heading** from the table above, paste
the matching file's contents into the **Message body** editor (Source view),
save. Repeat per template.

## Redirect-URL audit (already correct as of 2026-05-14)

- **Site URL**: `https://sprichapp.com` ✓
- **Redirect URLs** include: `https://sprichapp.com/auth/callback`, `https://sprichapp.com/auth/callback?next=/download`, `sprich://**` ✓

If a verify link ever points at `localhost:3000`, the developer triggering
the test signed up against the same Supabase project from a local dev
server — that's a client-side `emailRedirectTo` artifact, not a Supabase
config problem. Production signups (sprichapp.com) always pass the production
callback.
