---
name: my-voice
description: |
  Rewrite text to match the user's personal writing voice, or learn that voice
  from a sample. Use when the user runs /my-voice to align a draft with how they
  communicate, /my-voice learn <url|doc> to learn from one writing sample, or
  /my-voice learn slack to harvest the user's entire Slack message history and
  distill it into the central voice source of truth.
argument-hint: "[learn <url|file> | learn slack [--min-chars N]] [--auto] — no args: apply voice to the latest draft; learn: capture voice from a sample or your whole Slack history. Default is 1-by-1 back-and-forth; --auto runs the whole pass unattended. --min-chars sets the Slack noise floor (default 30)."
allowed-tools: Read Write Edit Grep Glob WebFetch AskUserQuestion mcp__claude_ai_Slack__slack_search_public_and_private mcp__claude_ai_Slack__slack_read_user_profile
---

# My Voice

One skill, two sides:

- **Apply mode** (`/my-voice`, no args) — rewrite the latest draft in context so it reads in the user's own voice.
- **Learn mode** — fold new style pointers and examples into the source of truth, from either:
  - `/my-voice learn <url|file>` — one writing sample.
  - `/my-voice learn slack` — the user's **entire Slack message history**, harvested automatically.

The source of truth is **`VOICE.md` in this skill directory** (`~/.claude/skills/my-voice/VOICE.md`).

> **Non-negotiable, both modes:** Read `VOICE.md` in full **before** making any adjustment — to a draft or to `VOICE.md` itself. Never edit blind.

> **Default, both modes:** Work in **small chunks**. Each chunk is a single back-and-forth: propose one focused change, stop, get the user's reaction, then move to the next. Never batch multiple chunks into one message, and never apply a chunk before the user responds to it. **This is the default and the heart of the skill.**

> **The one exception — `--auto`:** If the invocation includes `--auto`, skip the per-chunk discourse and run the whole pass unattended — rewrite every chunk / accept every distilled pointer in one go, then present the complete result for review. `--auto` overrides *only* the back-and-forth pausing. The other non-negotiables still hold: always read `VOICE.md` first, always back up or write to an adjacent file before touching a document on disk, and never silently truncate. Use `--auto` when the user has signalled they trust the pass and don't want to babysit it (e.g. a long draft).

---

## Step 0 — Always: load the source of truth

Read `~/.claude/skills/my-voice/VOICE.md` end to end. If it does not exist, create it from the scaffold in the appendix below before doing anything else.

Hold its principles and examples in mind for every chunk that follows. Do not summarize it back to the user unless asked — just use it.

Then branch on the argument.

---

## Apply mode — `/my-voice` (no args)

Goal: take the **most recent draft in the conversation** (the last substantive block of prose you or the user produced — an email, message, doc section, PR body, etc.) and rewrite it to match `VOICE.md`.

1. **Confirm the target.** State in one line what you're treating as "the latest draft" (quote its first few words). If it's ambiguous, ask which text to operate on before continuing. Note whether the target is **in-context text** or a **file on disk** (`Read` it) — the output handling in step 4 differs.

2. **Segment it.** Break the draft into small chunks — a paragraph, a list, or a single awkward sentence. One chunk = one idea the eye can land on.

3. **For each chunk, one at a time** (default — skipped under `--auto`):
   - Show the **original** chunk verbatim in a fenced block.
   - Show your **voiced rewrite** in a second fenced block, using `VOICE.md` principles. Prefer a ` ```diff ` block when the change is small enough to read as +/- lines.
   - Name in one line *which* voice pointer drove the change (e.g. "shorter sentences, cut the hedge").
   - **Stop.** Ask the user: accept / tweak / skip. Do not touch the next chunk until they answer.

   Under **`--auto`**: skip the per-chunk stops entirely. Rewrite every chunk against `VOICE.md` in one pass, then jump straight to step 4 with the full result. Note inline (e.g. a short bracketed margin tag per section) which pointer drove each notable change, so the user can still audit the pass after the fact.

4. **After the last chunk**, assemble the accepted rewrites into the final text.
   - **In-context text** → present the final text in one clean block.
   - **File on disk** → **never modify the original in place by default.** Write the voiced result to a **new adjacent file**, `<name>.voiced.<ext>` (e.g. `blog-post.md` → `blog-post.voiced.md`), and tell the user both paths. The original is left untouched, so there's nothing to lose.
   - If the user explicitly wants it rewritten **in place**, first copy the original to a timestamped backup (`<name>.<YYYYMMDD-HHMMSS>.bak`) and confirm the backup exists before overwriting. Never overwrite an ingested document without a backup sitting next to it.

5. **Offer to learn.** If the back-and-forth surfaced a preference not yet in `VOICE.md` (the user corrected you in a consistent direction), offer — don't auto-write — to capture it via the learn-mode update flow.

Never rewrite the whole draft in one pass. The chunk-by-chunk discourse *is* the feature.

---

## Learn mode — routing

Look at the argument:

- `slack` → **Slack corpus path** (below).
- a URL or file path → **single-sample path** (further below).
- nothing → ask which: a Slack harvest, or a specific URL/file.

Both paths end the same way: candidate pointers go through the **chunked confirmation discourse** (one pointer, one back-and-forth) before anything is written to `VOICE.md`. The harvesting and analysis are abstracted away from the user; the *discourse happens over distilled pointers, never over raw messages*.

---

### Learn mode (Slack) — `/my-voice learn slack`

Goal: harvest as much of the user's own Slack history as Slack will return, distill it into a small set of voice pointers with real examples, then run those through the confirmation discourse. **The user never paginates, never sees raw pages — they connect Slack once and react to distilled findings.**

**1. Ensure the Slack MCP is connected.**
   - Probe by attempting `slack_read_user_profile` (no `user_id` → current user).
   - If the Slack tools are unavailable / unauthenticated, stop and guide the user — do not work around it:
     > Run `/mcp`, select **"claude.ai Slack"**, complete the browser authorization, then re-run `/my-voice learn slack`.
   - Resume only once the profile call succeeds.

**2. Resolve identity.** From the profile call, capture the user's Slack `user_id` (e.g. `UPNTZ7YPJ`). All harvesting filters on `from:<@USER_ID>`.

**3. Slurp as much as possible — silently.** Loop `slack_search_public_and_private`:
   - `query = "from:<@USER_ID>"`, `sort = "timestamp"`, `sort_dir = "desc"`, `limit = 20`, `include_context = false`, `response_format = "concise"`.
   - Follow the returned `cursor` page after page; keep going until no cursor comes back (history exhausted) or pages stop returning new messages.
   - **Stretch past the search cap with date windowing.** Slack search truncates deep history. When the cursor walk ends, keep reaching further back by adding `before:YYYY-MM-DD` set to the oldest message seen so far, and walk again. Repeat until a window returns nothing new. This is how "as much as possible" is actually achieved.
   - Accumulate every message's text. De-duplicate.
   - **No per-page chatter.** Emit at most a periodic one-line progress note (e.g. "harvested ~400 messages, reaching back to 2021…"). The user watches a counter, not pages.
   - If the API rate-limits or errors mid-walk, surface the raw error verbatim and report how many messages were gathered so far — then proceed to distill with what's in hand rather than failing.

**4. Filter for signal — drop noise, keep short substance.** Before distilling, prune the corpus so style analysis runs on messages that actually carry voice:
   - **Default floor: 30 characters.** Drop anything shorter. Overridable with `--min-chars N` in the invocation (e.g. `/my-voice learn slack --min-chars 80` for prose-heavy writers).
   - Regardless of length, also drop **emoji-only** messages and **single-token** reacts/acks (`lol`, `ty`, `nice`, `:heart:`, `+1`).
   - **Do not raise the floor to chase signal blindly.** Brevity is itself a voice trait for many people — punchy one-liners (`complex solution? REJECT`, `restart everytin`) live just above the noise line. The floor removes reactions, not short substance. If the corpus is dominated by very short messages, *note that brevity as a candidate pointer* rather than filtering the personality out.
   - **No silent cuts.** After filtering, log one line: `kept N of M messages (dropped K below floor / noise)` so the user sees what was excluded.

**5. Distill the corpus into candidate pointers.** Once harvesting and filtering end, analyze the whole collection at once:
   - **Treat voice as one unified thing — do not split "work" from "personal".** Messages span many contexts (banter, incidents, planning, DMs), but the goal is a single voice that travels everywhere; bringing the whole self is the point. Context-specific *formats* (e.g. a channel's posting convention) may be noted separately, but they are not a different voice.
   - Identify durable traits: capitalization habits, sentence length/fragments, punctuation, emoji use, vocabulary and stock phrases, openings/closings, how lists vs prose are handled, humor, hedging.
   - For each candidate pointer, pull **2–3 verbatim example messages** as evidence (examples beat rules).
   - Produce a short ranked shortlist (most → least characteristic). Do **not** write anything yet.

**6. Confirm via chunked discourse** (default), exactly as the single-sample path does (see step 3 below): one pointer at a time, with its examples, flagged new / reinforces / conflicts — `Edit` `VOICE.md` only on the user's OK, then move on. Under **`--auto`**: write every distilled pointer to `VOICE.md` in one pass (skipping per-pointer confirmation), then show the user the full list of what was added so they can review and prune.

**7. Log provenance.** Append to `## Sources learned from`: `Slack history — harvested <date>, ~N messages (kept after filtering), range <oldest>–<newest>`.

**8. Verify.** Re-read the edited `VOICE.md` sections to confirm the writes landed.

---

### Learn mode (single sample) — `/my-voice learn <url|file>`

Goal: extract durable voice pointers and concrete examples from one sample, then fold them into `VOICE.md` — in small, confirmed chunks.

1. **Load the sample.**
   - URL → `WebFetch`.
   - Local path → `Read`.

2. **Analyze against what's already known.** With `VOICE.md` already in mind (Step 0), identify candidate pointers the sample demonstrates: sentence length and rhythm, punctuation habits, vocabulary, openings/closings, formality, structure, humor, hedging, how they handle lists or transitions. Pull **verbatim example snippets** from the sample as evidence — examples are worth more than abstract rules.

3. **Propose findings one chunk at a time** (default — skipped under `--auto`):
   - State **one** candidate pointer.
   - Back it with a short verbatim quote from the sample.
   - Say whether it's **new**, **reinforces** an existing pointer, or **conflicts** with one already in `VOICE.md` (flag conflicts explicitly — they need the user's call).
   - **Stop.** Ask: add it / reword it / drop it. Wait.

   Under **`--auto`**: skip the stops — write all new/reinforcing pointers to `VOICE.md` in one pass, but still **surface conflicts** for the user's call rather than auto-resolving them, then show the full list of what was added.

4. **On acceptance of a chunk**, `Edit` `VOICE.md` immediately to record that one pointer (and its example), then move to the next candidate. Small, incremental writes — not one big rewrite at the end.

5. **Log the source.** Append the URL/file (and date) to the `## Sources learned from` section so the provenance is traceable.

6. **Verify.** After the final write, re-read the edited sections to confirm the changes landed (per the user's "verify before claiming done" rule).

---

## Appendix — `VOICE.md` scaffold

If `VOICE.md` is missing, create it with this structure (empty sections, no invented content — it gets populated only through `learn` and confirmed apply-mode corrections):

```markdown
# Patrick's Writing Voice — Source of Truth

> Populated by `/my-voice learn`. Read in full before any voice adjustment.
> Each pointer carries a concrete example; examples beat rules.
> One unified voice — the same person everywhere. Do not split "work" from "personal";
> bringing the whole self is the point. (Context-specific *formats* like a channel
> convention can still be noted, but they are not a different voice.)

## Voice pointers
<!-- one flat list of durable traits, each with a verbatim example -->

## Context-specific formats (not a different voice)
<!-- channel/template conventions that apply only in a named place -->

## Sources learned from
<!-- url|file|slack — date -->
```
