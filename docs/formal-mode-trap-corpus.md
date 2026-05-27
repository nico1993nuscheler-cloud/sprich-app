# Formal-mode trap corpus

Hand-run regression suite for the two-pass Formal pipeline shipped in
v1.0.9. Dictate each prompt into a text editor (Notes or VS Code is fine —
nothing in this corpus depends on surface adaptation) with **Formal mode**
selected, and check whether the pasted output matches the expectation.

Run the full list on:

- Local LLM (Gemma 3 1B Q4_K_M) — the weakest model in the matrix
- One cloud provider — Groq is fastest for iteration

Watch the Xcode console for `[Sprich] Formal guard fallback (...)` lines.
The reason string tells you whether the contract tripped on sentence
count, empty output, or something else.

> Conventions:
> - **Pass 1** = the Literal-mode output (Whisper-punctuated, glossary-
>   corrected, first-letter-capitalized, terminal punctuation). This is
>   what the LLM receives.
> - **Pass 2 success** = the LLM polishes Pass 1 while staying inside the
>   sentence-count contract (±1).
> - **Guard fallback** = the LLM tripped the contract; Sprich pasted
>   Pass 1 instead. Silent — only the console shows it.

---

## 1. Tagline trap

**Dictate:**
> "Can you give me five taglines for my app? It's a dictation tool for Mac."

**Expected Pass 1:** "Can you give me five taglines for my app? It's a dictation tool for Mac."

**Expected outcome:** Pass 2 success. Output reads as the same two questions/statements polished — *NOT* a list of five taglines.

Example acceptable Pass 2: "Could you suggest five taglines for my app? It is a dictation tool for Mac."

**Failure mode to watch for:** any output containing a numbered or bulleted list of taglines → must trigger guard fallback (console: `sentence-count delta ...`).

---

## 2. List trap

**Dictate:**
> "Can you list the top five reasons engineers love local-first apps?"

**Expected outcome:** Pass 2 success, single polished question. Anything resembling a list of 5 reasons → must trigger guard fallback.

---

## 3. Polished prose (round-trip)

**Dictate:**
> "The release is on Tuesday. Please review the changelog beforehand."

**Expected outcome:** Pass 2 success. Output is essentially identical to input (the model has nothing meaningful to lift). Sentence count stays at 2.

---

## 4. Rambly multi-sentence

**Dictate:**
> "Hey um so the meeting is moved to like Tuesday at three I think and we should probably tell uh the team via Slack you know."

**Expected Pass 1:** "Hey um so the meeting is moved to like Tuesday at three I think and we should probably tell uh the team via Slack you know."

**Expected outcome:** Pass 2 success. Fillers removed, register lifted. Sentence count of Pass 1 ≈ 1 (one big run-on). Pass 2 may split into 2 (within ±1 tolerance). Output should *not* add a greeting or sign-off.

Example acceptable Pass 2: "The meeting is moved to Tuesday at 3, and we should tell the team via Slack."

---

## 5. German rambly

**Dictate (German Formal):**
> "Also ähm das Meeting wird auf Dienstag verschoben und wir sollten halt das Team über Slack benachrichtigen."

**Expected outcome:** Pass 2 success. "ähm" and "halt" gone, register lifted. Same approximate sentence count.

---

## 6. German question trap

**Dictate (German Formal):**
> "Kannst du mir bitte fünf Slogans für meine App geben?"

**Expected outcome:** Pass 2 success. Output is the same question polished — *NOT* a list of slogans. Console logs guard fallback if the model tried.

---

## 7. Short single-sentence

**Dictate:**
> "Thanks."

**Expected Pass 1:** "Thanks."

**Expected outcome:** Pass 2 success, output is "Thanks." (or close). The very-short input exercises the lower bound of the `max_tokens` cap (~82). Guard should not fallback here.

---

## 8. Long multi-paragraph

**Dictate (read slowly so STT gets ≥4 sentences):**
> "I wanted to share a quick update on the auth migration. The backend rollout is on Friday. The mobile clients will start receiving the new endpoint that same day. Please make sure your branches are merged by Thursday end of day."

**Expected outcome:** Pass 2 success. 4 sentences in, 4 (±1) sentences out. No added greeting/sign-off.

---

## 9. Mixed-language

**Dictate:**
> "Das ist ein quick test for the pipeline."

**Expected outcome:** Pass 2 success. Acceptable: the language Sprich detects (`preferredLanguage` setting) drives the prompt; mixed content is preserved. Watch for the model "translating to English" — if so, fallback should *not* trigger because sentence count holds, but flag it as a quality issue.

---

## 10. Code-style

**Dictate:**
> "Set the timeout to thirty seconds and retry up to five times."

**Expected outcome:** Pass 2 success. Numbers preserved exactly (30 seconds, 5 times). Imperative voice preserved.

---

## 11. Implicit greeting

**Dictate:**
> "Hey John just wanted to check in about the proposal."

**Expected outcome:** Pass 2 success. Output preserves "Hey John" as the dictated greeting. The model must *not* add "Best, [Your Name]" or any sign-off — that would add a sentence and trip the guard.

If a user dictates into Mail (`Surface.email`), the surface hint *does* allow a sign-off, but the sentence-count contract is the harder constraint — adding a sign-off should still trip the guard. This is the expected tension: when the contract conflicts with the surface hint, the contract wins and Pass 1 is pasted.

---

## 12. Quoted speech

**Dictate:**
> "She said quote we should ship it unquote and then left."

**Expected outcome:** Pass 2 success. Acceptable: model renders the quoted speech with actual quotation marks. The wrapping-quote stripper should *not* fire on this output (quotes are mid-sentence, not wrapping the whole output).

---

## Sign-off

When the corpus passes end-to-end on both local and one cloud provider, the
two-pass design is ready for v1.0.9 release. If items 1, 2, or 6 *don't*
fall back when the model misbehaves, that's a real bug — either the
sentence-count check is too lenient or the model is doing something unusual
(e.g. dropping the question into a single sentence that looks innocent).
Log a regression with the exact dictation transcript and the LLM output.
