# Supabase auth email templates — Sprich

Canonical HTML for every transactional auth email Supabase sends on behalf of
the Sprich project (`djiixtplbsutuiuxfhiy`). Files here are the source of
truth — paste into the Supabase Dashboard whenever the live templates drift.

## Files

| File | Supabase template | Subject heading |
|---|---|---|
| `confirm-signup.html` | Confirm signup | Confirm your email — Sprich |
| `magic-link.html` | Magic Link | Sign in to Sprich |
| `reset-password.html` | Reset Password | Reset your Sprich password |
| `change-email.html` | Change Email Address | Confirm your new email — Sprich |
| `invite.html` | Invite user | You're invited to Sprich |
| `reauthentication.html` | Reauthentication | Your Sprich verification code |

`_base.html` is documentation only; do not paste.

## Deploy

1. Open https://supabase.com/dashboard/project/djiixtplbsutuiuxfhiy/auth/templates
2. Pick a template tab on the left.
3. Set **Subject heading** from the table above.
4. Paste the matching file's entire contents into the **Message body** editor (Source view, not WYSIWYG).
5. Save. Repeat for every template.

## Template variables

Every template uses `{{ .ConfirmationURL }}` for the action link, except
`reauthentication.html` which uses `{{ .Token }}` (a 6-digit OTP code).
Supabase substitutes the correct verify type per template automatically — the
HTML stays identical across types.

## Test

After saving each template, fire the corresponding flow against production:

- **Confirm signup** — sign up at https://sprichapp.com/signup with a **fresh** email never seen on the project. The email subject should be "Confirm your email — Sprich" and the body should render the branded card. Click the CTA → the link should land on `https://sprichapp.com/auth/callback#access_token=…` (verify the host is `sprichapp.com`, not `localhost`).
- **Magic Link** — sign in with an **existing** email. Regression check that the magic-link template still renders.
- **Reset / Change / Reauth** — low surface area; trigger from the dashboard's "Send test email" if available, or skip.

## Redirect-URL audit

If a verify link points at `localhost:3000` instead of `sprichapp.com`, the
project's **Site URL** and **Redirect URLs** allow-list need updating:

https://supabase.com/dashboard/project/djiixtplbsutuiuxfhiy/auth/url-configuration

- **Site URL**: `https://sprichapp.com`
- **Redirect URLs** must include: `https://sprichapp.com/auth/callback`, `https://sprichapp.com/auth/callback?**`, and `sprich://auth/callback`

The signup form at `app/signup/page.tsx` (landing repo) builds the redirect
via `window.location.origin` + `/auth/callback`, so production signups always
ask Supabase to redirect to `https://sprichapp.com/auth/callback`. Localhost
artifacts in old test emails came from dev-mode signups against the same
Supabase project.
