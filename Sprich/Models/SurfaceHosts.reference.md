# Surface host catalog — business-app web hosts → `Surface`

Source of truth for the web-host mappings in `Surface.swift`
(`SurfaceMapping.fromURL` + `WebSurfaceLabel.displayName`). Verified
2026-05-31 (v1.0.13). When adding a host, update **both** functions and this
file together.

**Match type:** `exact` = full host string; `suffix` = any host ending in
this (covers tenant subdomains like `acme.atlassian.net`). Prefer suffix for
anything with per-customer/region subdomains.

**Status:** `mapped` = wired into an existing `Surface` this release.
`parked-vertical` = needs its own dedicated `Surface` case + tone prompt;
deferred to the vertical-launch phase (see memory
`project_sprich_vertical_app_surfaces`). For now these route to the closest
existing surface or `.generic` as noted.

---

## Mapped → existing surfaces

### email
| App | Host(s) | Match | Notes |
|---|---|---|---|
| Gmail | `mail.google.com` | exact | `/chat` path → googleChat (path wins) |
| Outlook (work) | `outlook.office.com`, `outlook.office365.com` | suffix | |
| Outlook.com (personal) | `outlook.live.com` | suffix | |
| Yahoo Mail | `mail.yahoo.com` | exact | |
| Proton Mail | `mail.proton.me` | exact | old `mail.protonmail.com` redirects |
| Fastmail | `app.fastmail.com` | exact | |
| Zoho Mail | `mail.zoho.com`, `mail.zoho.eu`, `mail.zoho.in` | exact/region | |
| HEY | `app.hey.com` | exact | |

### slack / teams / googleChat / discord
| App | Host(s) | Match | Surface |
|---|---|---|---|
| Slack | `app.slack.com`, `*.slack.com` | exact+suffix | slack |
| Teams | `teams.microsoft.com` | suffix | teams (note: `teams.live.com` is NOT an app host — removed) |
| Google Chat | `chat.google.com`; `mail.google.com` `/chat` | exact/path | googleChat |
| Discord | `discord.com` | suffix | discord |

### messages
| App | Host(s) | Match | Notes |
|---|---|---|---|
| WhatsApp Web | `web.whatsapp.com` | suffix | |
| Telegram Web | `web.telegram.org` | exact | `/k/ /a/ /z/` are paths |
| Messenger | `messenger.com` | suffix | |
| Signal | — | — | **no official web client; nothing to match** |

### docs
| App | Host(s) | Match | Notes |
|---|---|---|---|
| Google Docs | `docs.google.com` | exact | also Sheets/Slides — fine as one surface |
| Confluence | `*.atlassian.net` `/wiki` | suffix+path | splits from Jira by path |
| Coda | `coda.io` | suffix | |
| Dropbox Paper | `paper.dropbox.com` | exact | web-only since Oct 2025 |

### aiChat
| App | Host(s) | Match |
|---|---|---|
| ChatGPT | `chatgpt.com`, `chat.openai.com` | exact |
| Claude | `claude.ai`, `claude.com` | suffix |
| Gemini | `gemini.google.com`, `bard.google.com` | exact |
| Google AI Studio | `aistudio.google.com` | exact |
| Perplexity | `perplexity.ai` | suffix |
| Copilot | `copilot.microsoft.com` | exact |
| DeepSeek | `chat.deepseek.com`, `deepseek.com` | exact/suffix |
| Mistral (Le Chat) | `chat.mistral.ai`, `mistral.ai` | exact |
| Grok | `grok.com`, `x.ai` | exact/suffix |
| Poe | `poe.com` | suffix |
| Phind | `phind.com` | exact |
| You.com | `you.com`, `chat.you.com` | exact |

### taskManager
| App | Host(s) | Match | Notes |
|---|---|---|---|
| Notion | `notion.so`, `notion.site`, **`notion.com`, `app.notion.com`** | suffix | **`notion.com`/`app.notion.com` added in v1.0.13 — confirmed on a real device log (`app.notion.com → generic` was the bug). Notion has been migrating off `notion.so`; keep BOTH.** |
| Linear | `linear.app` | suffix | |
| Jira | `*.atlassian.net` (non-`/wiki`) | suffix | |
| Asana | `app.asana.com`, `*.asana.com` | suffix | |
| ClickUp | `app.clickup.com`, `*.clickup.com` | exact/suffix | |
| Trello | `trello.com` | suffix | |
| Todoist | `app.todoist.com`, `todoist.com` | suffix | |
| Monday | `*.monday.com` | suffix | every account is a subdomain |
| Basecamp | `*.basecamp.com`, `3.basecamp.com` | suffix | |
| Height | `height.app` | suffix | |
| Shortcut | `app.shortcut.com`, `*.shortcut.com` | suffix | |
| Smartsheet | `app.smartsheet.com`, `app.smartsheet.eu` | exact | added v1.0.13 |
| Airtable | `airtable.com` | suffix | added v1.0.13 |

---

## Parked — need a dedicated vertical surface (route to closest fit / generic for now)

These have a distinct register (a CRM note ≠ an email ≠ a task). Until they
get their own `Surface` + prompt, they fall through to `.generic` (no tone
adaptation). Cataloged here so the future vertical work has verified hosts.

### CRM / sales (→ future `crm`)
| App | Host(s) | Match |
|---|---|---|
| Salesforce | `*.lightning.force.com`, `*.my.salesforce.com` | suffix |
| HubSpot | `*.hubspot.com` (`app.hubspot.com`, `app-eu1.hubspot.com`) | suffix |
| Pipedrive | `*.pipedrive.com` | suffix |
| Zoho CRM | `crm.zoho.com/.eu/.in` | suffix |
| Close | `app.close.com` | exact |

### Support / helpdesk (→ future `support`)
| App | Host(s) | Match |
|---|---|---|
| Zendesk | `*.zendesk.com` | suffix |
| Intercom | `app.intercom.com`, `app.eu.intercom.com`, `app.au.intercom.com` | suffix |
| Freshdesk | `*.freshdesk.com` | suffix |
| Help Scout | `secure.helpscout.net` | exact |
| Front | `app.frontapp.com`, `app.front.com` | suffix |

### Finance / accounting (→ future `accounting`; DACH priority for Phase 2)
| App | Host(s) | Match | Notes |
|---|---|---|---|
| DATEV | `*.datev.de` (`apps.datev.de`) | suffix | inferred — verify module host |
| Lexware Office (ex-lexoffice) | `app.lexware.de`, `app.lexoffice.de` | suffix | both live post-rename |
| QuickBooks | `*.qbo.intuit.com` | suffix | |
| Xero | `go.xero.com` | exact | app host (login is `www.xero.com`) |
| sevDesk | `my.sevdesk.de` | exact | |
| Stripe | `dashboard.stripe.com` | exact | |

### HR (→ future `hr`)
| App | Host(s) | Match |
|---|---|---|
| Personio | `*.app.personio.com` | suffix |
| Workday | `*.myworkday.com`, `*.workday.com` | suffix |
| BambooHR | `*.bamboohr.com` | suffix |

### Marketing / dev / storage
Mailchimp `*.admin.mailchimp.com`, Buffer `publish.buffer.com`, Hootsuite
`app.hootsuite.com`; GitHub `github.com`, GitLab `gitlab.com`, Bitbucket
`bitbucket.org`; Google Drive `drive.google.com`, Dropbox `*.dropbox.com`,
OneDrive `onedrive.live.com`, SharePoint `*.sharepoint.com`, Box
`*.app.box.com`. Most route to `.generic` today; revisit if dictation usage
warrants a `docs`/dedicated mapping.

---

## Implementation notes
1. **Suffix matching is mandatory** for tenant-subdomain apps (Salesforce,
   Atlassian, Zendesk, Monday, Personio, Workday, Pipedrive, SharePoint).
2. **Path disambiguation on shared hosts:** `mail.google.com` (`/mail` vs
   `/chat`), `*.atlassian.net` (`/wiki` = Confluence/docs, else Jira/task).
3. **Multiple live hosts per app:** Lexware (`app.lexware.de` +
   `app.lexoffice.de`), Front, Outlook, ChatGPT — match all.
4. **Lower-confidence rows** (verify before relying): DATEV module hosts,
   Office-web `officeapps.live.com`, Freshsales, FreshBooks, Copper,
   Rippling, Gusto, Marketo instance hosts.
