---
name: stacked-release
description: Decompose a too-large code change into a chain of independently-reviewable PRs that all open in parallel — each PR's base is the prior PR's branch. Built for repos that ship through managed release pipelines (where merges are batched into release cycles), so reviewers can work concurrently without wall-clock time blocking on each PR's merge. Sibling skill to `incremental-release` (sequential).
argument-hint: <subcommand> [args] — one of: plan, status, inspect, update, restack, update-current, abort, replan
allowed-tools: Bash(git *) Bash(gh *) Bash(pipenv *) Bash(pytest *) Bash(npm *) Bash(make *) Bash(mkdir *) Bash(ls *) Bash(test *) Bash(diff *) Bash(stat *) Bash(shasum *) Bash(sha256sum *) Read Write Edit Grep Glob
---

# Stacked Release

Decomposes a too-large PR into a chain of small PRs that open in parallel. Each PR's base is the prior PR's branch (PR 1's base = `main`; PR N's base = PR N-1's branch). Reviewers see all PRs in the stack at once and can work through them at their own pace. As PRs merge, GitHub auto-redirects downstream bases; mid-stack edits trigger a cascading rebase via the `restack` subcommand.

State persists in a manifest at `~/.claude/state/<repo>-<ticket>-stacked-release/`, so the engineer can step away and resume.

## When to use

- Repo ships through a managed release pipeline (`.release-pipeline`, `lotus.yaml`, batched-merge CI, etc.) where waiting for each PR to merge before opening the next would extend wall-clock time across multiple release cycles.
- Reviewers can handle multiple PRs in flight simultaneously and want context on the full series.
- Author can manage a cascading rebase on review-feedback changes.

## When NOT to use

- Fast merge cadence (PRs land within minutes/hours of approval). Sequential-from-main (`incremental-release`) is simpler with no rebase ceremony.
- The team prefers strict serialization of review focus. Use `incremental-release` instead.
- The change is a single atomic concern that can't be cleanly split. Don't split for size alone.

## Sacred invariants

These hold across every subcommand. Violations are bugs.

1. **The source branch is read-only.** Never `git checkout <source-branch>` to switch onto it. Only `git checkout <source-branch> -- <paths>` to copy files out. Never push, rebase, reset, force-push, amend, or delete the source branch.
2. **Only branches matching the manifest's `branch_pattern` accept writes.** Never push to `main`, the source branch, or any branch not in the manifest's PR list.
3. **Force-push only with `--force-with-lease`, only on stack branches.** Force-push is routine in stacked mode (every restack). Always include `--force-with-lease` (and `--force-if-includes` on modern git) — never raw `--force`. If the lease check fails, stop: someone else may have pushed; investigate before retrying.
4. **Each PR must independently pass all its tests on its own branch tip.** Tests run before every push — initial open, restack, update-current. The test command is `manifest.test_command`. Never `--no-verify`, never skip tests, never push and "fix later." If PR M's tests fail, the chain halts at M: PRs M+1..N are not opened, restacked, or pushed until M is green. Each PR's last test result is recorded in the manifest as `prs[N-1].last_test_result: {passed: bool, summary, ran_at}` so `update` can surface it in the navigation callout.
5. **Source SHA is locked at plan time.** Extract files via `git checkout <source_sha> -- <path>`. If the source moves, run `replan`.
6. **Cascading consistency.** If PR N is updated mid-stack, PRs N+1..M are restacked atomically before any other workflow continues. Never leave the chain in a partially-restacked state — if restack halts (conflict, test failure), surface the error and stop. Other PRs in the chain wait.
7. **Status callouts must reflect manifest state.** When upstream state changes (a PR merges, an in-flight PR is updated), in-flight downstream PRs' status callouts (and only the callouts) MUST be updated before the next user touches them. This is the one case where reaching back to in-flight PR bodies is allowed — the callout is *about state*, not narrative.
8. **Merged PRs are immutable.** Once a PR is merged, the skill never edits its body again. Same as `incremental-release`.
9. **Pre-flight checks before every commit/push:** verify `HEAD` matches the expected branch, `git status` shows no unintended files, `git remote -v` is unchanged.
10. **Surprise = stop.** Any unresolved merge conflict, dirty working tree, unfamiliar branch state, or test failure: stop and surface. Never use destructive operations as a workaround.
11. **Source SHA is preserved by a tag.** `plan` pushes a `stacked-release-<ticket>-source` tag at plan time so the SHA survives force-push of the source.

## Manifest layout

```
~/.claude/state/<repo>-<ticket>-stacked-release/
├── manifest.json                  # top-level state, ordered PR list, cursor
├── pr-NN-<slug>/
│   ├── plan.json                  # ship_actions, code_review_focus, body_template_file
│   ├── body.md                    # PR body template (with placeholders)
│   └── patches/                   # unified diffs
│       ├── <name>.patch
│       └── ...
```

**Same shape as incremental-release** — the manifest format is shared between both skills in the family. Only the `skill` field and `branch_pattern` differ. Plus stacked manifests track per-PR `base_branch` (the prior PR's branch, or `main` for PR 1) and `base_redirect_to_main` boolean (true once the upstream PR merges and GitHub redirects the base).

`manifest.json` top-level fields:

- `skill: "stacked-release"`
- `source_branch`, `source_sha` — locked at plan time
- `source_protection_tag` — e.g. `stacked-release-PLAT-111-source`
- `main_branch`, `main_sha_at_plan`
- `branch_pattern` — e.g. `PLAT-111-stacked/{index:02d}-{slug}`
- `test_command`
- `post_apply_commands` — same shape and semantics as `incremental-release`
- `code_review` — `{primary_agent, fallback_agent, blocking_severities}`
- `release_context` — same shape
- `cursor` — index of the **active review focus** (the lowest-index PR with `status: open`). Advances as PRs merge.
- `halted` — boolean
- `prs[]` — each entry has: `index, slug, branch, base_branch, title, display_name, role, summary, status, pr_number, pr_url, shipped_at, merged_at, last_synced_at`

Per-PR `plan.json` fields are identical to incremental-release: `ship_actions`, `renames`, `test_command`, `code_review_focus`, `review_findings_to_carry_into_pr_body`.

## Subcommand: plan

Initialize a new stacked release.

### Arguments

- `$0` — Source branch name
- `$1` — (Optional) Ticket prefix
- `$2` — (Optional) Repo path; defaults to `pwd`

### Procedure

Steps 1–6 (working tree clean, source branch verify, lockfiles, source-protection tag, default-branch detect, release context and constraints discovery) are **identical to incremental-release**. Refer to that skill for details.

7. **Cross-skill recommendation: incremental-release if NO managed pipeline detected.** If step 6a found no `.release-pipeline` / `lotus.yaml` / `cloudbuild.yaml` / release-pipeline GitHub workflow markers, the repo likely lands PRs as soon as approved (no batched release cycles). Stacked-release's cascading-rebase ceremony is overhead with no payoff in that case.

   Surface a recommendation:
   ```
   No managed release pipeline detected.
   `stacked-release` is built for repos where merges are gated by release
   cycles. With fast merge cadence, the cascading-rebase overhead per
   review-feedback change isn't worth it.
   Recommended: `/incremental-release plan <source>`.
   Continue with stacked-release anyway? [y/N]
   ```
   Default no. Capture the override decision in `manifest.release_context.recommendation`.

8. Compute `git diff <main_sha>...<source_sha> --stat` for the file change inventory.
9. Filter out paths the user wants stripped (default: `.planning/`).
10. Group changes into logical chunks. Same strategy hints as incremental-release.
11. Size each chunk against the target review budget.
12. **Code-review pass** per chunk — same as incremental-release. Findings flagged for carry-into-PR-body.
13. Generate body templates with the **navigation callout pair** at the top of every PR (see "Per-PR body composition" below).
14. Write manifest + per-PR `plan.json`/`body.md`/patches.
15. **Plan preview gate.** Print:
    - Source @ sha
    - Main @ sha
    - Files affected (added/modified/deleted/renamed)
    - Proposed PRs as a chain table: index, branch, base_branch, title, est. review minutes, file count, code-review findings count
    - Manifest path
    Then ask: **"Open all 10 PRs as a stack? [y/N]"**. Default no.
16. **If confirmed: open all PRs as a chain in dependency order.**
    For each PR `N` in `1..total`:
    1. `git checkout main` (for PR 1) or `git checkout <prs[N-2].branch>` (for PR N>1).
    2. `git checkout -b <prs[N-1].branch>`.
    3. Apply ship_actions (same patch-apply procedure as incremental-release: try `--check`, fall back to `--3way`, halt on actual conflict markers).
    4. Apply renames.
    5. Run `post_apply_commands`.
    6. Run code-review pass on staged diff (per-chunk findings already captured at plan time, but run again to confirm clean state).
    7. Run tests. If fail, stop with the test-failure options.
    8. Commit with the body template; render the navigation callout as **▶ Ready for review** for PR 1, **⏸ Blocked** for PRs 2..N (will become ready as upstream merges).
    9. `git push -u origin <branch>`.
    10. `gh pr create --base <prs[N-1].base_branch> --head <prs[N-1].branch> --title <title> --body @<body_path>`.
    11. Update manifest: `prs[N-1].status = "open"`, `pr_number`, `pr_url`, `shipped_at`.
17. After all PRs are open, render the increment chart in each PR body (with the current cursor as `▶`, others as `⏸`).
18. Status report: print the chain summary with all PR URLs. Engineer can stop reviewing at this point — reviewers take it from here.

If declined: manifest is saved. User can run `ship-all` (alias of step 16) when ready, or open PRs incrementally via `inspect <n>` for examination first.

## Subcommand: status

Same as incremental-release. The increment chart in stacked mode shows multiple in-flight PRs (icons: `✓` merged, `▶` active focus, `⏸` open-but-blocked, `✗` closed, blank for planned-not-yet-opened).

## Subcommand: inspect

Same as incremental-release. Read-only dump of a specific PR's plan.

## Subcommand: update

Refresh local manifest with the live state on GitHub, and re-render all in-flight PR bodies so navigation callouts and increment charts reflect cardinality accurately. **This is the active subcommand in stacked mode** — replaces incremental-release's `ship-next` for the post-plan lifecycle.

Run `update` whenever a PR merges, gets approved, or you suspect state has drifted. It's idempotent and safe to run as often as the engineer wants.

### Procedure

1. Locate manifest. For each PR with `status: open`:
   - `gh pr view <pr_number> --json state,mergedAt,baseRefName`
   - Compare against manifest. Detect transitions:
     - `OPEN` → `MERGED`: update `status`, `merged_at`. If this PR was the cursor, advance cursor to the next-lowest-index open PR.
     - `OPEN` → `CLOSED` (not merged): halt and prompt user (replan? abort?).
     - Base ref changed (e.g., from prior branch to `main` after upstream merge): update `base_branch` in manifest.
2. **Compute cardinality** for body re-render:
   - `merged_count` = count of PRs with `status: merged`
   - `open_count` = count of PRs with `status: open` (still in flight)
   - `closed_count` = count of PRs with `status: closed`
   - `cursor_index` = current active focus
   - `next_cursor` = the PR that becomes active when the current cursor merges (cursor + 1 typically)
3. **Re-render all in-flight PR bodies** with fresh navigation callouts and increment charts:
   - For each PR with `status: open`, regenerate `body.md` from the template using current cardinality, then `gh pr edit <num> --body @<rendered>`.
   - The cursor PR's callout: **▶ Ready for review (X of N) — Y merged before; next: Z.**
   - Blocked PRs: **⏸ Blocked (X of N) — waiting on PR Y (currently active). Y merged before this PR.**
   - The merged PR: untouched (immutable).
   - The increment chart in every in-flight body re-renders with current symbols.
4. Status report: print which PRs transitioned, the new cursor, the cardinality summary (`X merged · 1 active · Y waiting`), and any user prompts that need attention.

## Subcommand: restack

Cascading rebase of downstream PRs after a mid-stack edit. Triggered automatically by `update-current`; can be invoked manually via `/stacked-release restack <from-pr-index>`.

### Procedure

Given a starting index `N` (the PR that was just updated), restack PRs `N+1..total` in order:

For each PR `M` from `N+1` to `total` (only those with `status: open`):

1. `git fetch origin <prs[M-1].branch>` (the new tip of M's base).
2. `git checkout <prs[M-1].branch>` (M's branch — note the index is M, branch is at `prs[M-1]`).
3. **Determine old and new base.** Old base is the prior tip recorded in manifest; new base is the just-updated tip of `prs[M-2]` (M's predecessor).
4. `git rebase --onto <new_base_sha> <old_base_sha> <branch>`. This replays M's commits on top of the new base.
5. If conflict: stop. Surface the conflicting paths. User resolves manually, then resumes via `git rebase --continue`. Once resolved, the skill picks up where it left off.
6. Run tests on the rebased branch. If fail: stop with test-failure options.
7. `git push --force-with-lease --force-if-includes origin <branch>`. If lease fails: stop, surface, ask user to investigate before retry.
8. Update manifest: refresh M's branch tip SHA, `last_restacked_at`.

After all downstream PRs are restacked, run `update` to refresh status callouts (downstream reviewers may need re-notification; their PR bodies should reflect the new state).

If any step in the cascade fails (conflict, test, lease), the chain halts. Engineer fixes and re-invokes `restack <from-pr-index>` to resume from the failed PR.

## Subcommand: update-current

Apply changes to a specific PR and cascade the update through the stack.

### Arguments

- `$0` — PR index to update (e.g., `3`)
- `$1` — (Optional) Free-text description of the change. If absent, prompt interactively.

### Procedure

1. Locate manifest. Verify PR `$0` has `status: open`.
2. `git checkout <prs[$0-1].branch>`. Verify clean working tree.
3. Apply the user-described changes via Edit/Write. Stage as you go. Capture the change as a new patch in `<pr-dir>/patches/` so a future `replan` can reproduce it.
4. Run code-review pass on the new diff vs the prior tip.
5. Run tests.
6. Commit a new commit on top of the branch (don't amend — preserves review history).
7. `git push --force-with-lease --force-if-includes origin <branch>` (force only because cascading-rebase semantics may require it; the branch's first push wasn't forced).
8. **Auto-trigger `restack`** starting from `$0+1` to cascade the change through downstream PRs.
9. Update manifest: append a `revisions[]` entry with timestamp + summary on PR `$0`.
10. Run `update` to refresh navigation callouts and increment charts on all open PRs.

## Subcommand: abort

Close the entire stack and halt the workflow.

### Procedure

1. For each PR with `status: open`: `gh pr close <pr_number> --comment "Closing — stacked-release abort. Will replan."`. Update manifest status to `closed`.
2. For local stack branches: `git checkout main; git branch -D <branch>` for each. Optionally `git push origin --delete <branch>` (ask user — remote branch deletion is irreversible).
3. Set `manifest.halted = true`.
4. Status report: print "Aborted. Run `/stacked-release replan` to revise the plan, or manually edit the manifest."

Notes:
- Merged PRs are not touched (they're already in main).
- If only some PRs are merged, abort closes the rest and halts. Engineer can replan from the next unmerged index.

## Subcommand: replan

Re-plan a halted or mid-stack workflow. Common triggers: source updated, chunk strategy needs revision, or aborted stack needs to be re-cut.

### Arguments

- `$0` — (Optional) `--from-pr <n>`: re-plan from PR `n` onward, preserving merged PRs.

### Procedure

1. Locate manifest. If `--from-pr <n>`:
   - Validate PRs `1..n-1` are all merged or closed. If any is still open, prompt to close them via abort first.
   - Truncate `prs[]` to `1..n-1`.
2. Refresh source SHA. If different from `manifest.source_sha`, ask user to confirm new SHA.
3. Re-compute file change inventory.
4. Run the planning loop (chunking, code-review, body template generation).
5. Write updated manifest. Old per-PR directories rename to `pr-NN-<slug>.replanned-<timestamp>/` for audit trail.
6. Set `halted = false`. Cursor = `n` (or 1 for full replan).
7. Confirm with user before opening the new PRs (same plan-preview gate as `plan`).

## Manifest discovery

Same as incremental-release. Subcommands locate the active manifest via `~/.claude/state/*-stacked-release/manifest.json` matching `repo_path` to `pwd`. If multiple match, present a picker.

## Per-PR body composition

Same overall sections as incremental-release (Scope, Origin, What this PR does, What to focus on, optional Test housekeeping, Test plan, Increments, Release context). **One critical addition for stacked-release**: every PR body opens with a **navigation callout pair** before any other content.

### Navigation callout pair

The first thing in every stacked PR's body — above Scope, above everything. Status-derived from manifest at PR-render time. Refreshed by `update` whenever upstream state changes.

The callouts include **cardinality** (where this PR sits in the stack and what's already done) so a reviewer landing on any single PR can orient instantly without clicking through to siblings.

For the active review focus (cursor PR), with `M` PRs already merged before it and `total` total PRs:
```markdown
> **▶ Ready for review · increment N of total · M merged before this · next: increment N+1.**
> **Tests:** ✓ {{test_summary}} on this branch tip ({{last_test_ran_at}}).
> **What you should do:** Approve or request changes. All upstream increments are merged.
> **After approval/merge:** Increment N+1 transitions to ▶ active focus; its reviewers will be re-notified. Author rebases downstream PRs onto new main.
```

For a blocked PR (open but waiting on upstream), with `M` merged before, currently waiting on PR `K`:
```markdown
> **⏸ Blocked · increment N of total · M merged so far · waiting on increment K (currently active).**
> **Tests:** ✓ {{test_summary}} on this branch tip ({{last_test_ran_at}}).
> **What you should do:** Read for context if useful — don't approve yet. Increment K is currently being reviewed.
> **What unblocks it:** Increments K through N-1 merging.
```

For an updated-mid-flight PR (the cursor PR was just restacked or updated):
```markdown
> **▶ Ready for review (updated) · increment N of total · M merged before this.**
> **Tests:** ✓ {{test_summary}} on the new branch tip ({{last_test_ran_at}}).
> **What changed:** New commits pushed in response to feedback. See Revisions section below.
> **What you should do:** Re-review the new commits and approve, or request additional changes.
> **After approval/merge:** Increment N+1 transitions to ▶ active focus.
```

If `prs[N-1].last_test_result.passed` is false, the **Tests** line shows `✗` instead of `✓` and the callout's "What you should do" line changes to `Hold off — tests are failing on this branch tip. The author needs to fix before re-review.` This should never happen on a published PR (the chain halts on test failure per invariant 4) but the rendering is defined for safety.

Symbol legend:
- `▶` — active / ready for review
- `⏸` — blocked / waiting on upstream
- `◌` — draft (rare in stacked; only for explicit author-marked drafts)
- `✓` — merged (used in increment chart, not in callouts)
- `✗` — closed

### Increments format

Same as incremental-release's `{{increments}}` placeholder, with extended status icons for stacked:

```markdown
## Increment {{this_pr_index}}/{{total_prs}} — ✓ {{merged_count}} merged · ▶ 1 active · ⏸ {{blocked_count}} waiting

```
  ✓ 1 · Models                       foundation: data shapes
  ▶ 2 · Redis client                 ◀ we are here — foundation: state storage
  ⏸ 3 · Cluster discovery            first layer of OpenSearch reads
  ⏸ 4 · Snapshots & repos            full discovery surface
  ⏸ 5 · Indices                      indices listing
  ⏸ 6 · Restore service              restore execution layer
  ⏸ 7 · Restore router + Slack       HTTP surface for restore
  ⏸ 8 · Restore monitor              background lifecycle tracking
  ⏸ 9 · Web UI: browse               read-only OpenSearch UI
  ⏸ 10 · Web UI: restore + tracking  full restore UX
```
```

In stacked, `⏸` rows mean "open on GitHub but waiting." Distinct from blank (planned, not yet opened — rare in stacked).

### Anti-patterns

Same as incremental-release: no source-branch links, no `#N` PR-number cross-refs at body-creation time, no heavy preambles before Scope, no all-caps imperatives. Plus: don't link to upstream PRs in the navigation callout — refer to them by branch name (`PR M` is fine; `#129` would auto-link).

## Code-review subagent prompt

Identical to incremental-release. Same severity buckets, same JSON output schema.

## Failure handling

In addition to the failures `incremental-release` documents, stacked-release has these stacked-specific modes — all stop with an explicit user prompt, never auto-retry:

- **Mid-stack rebase conflict.** PR M's restack fails to apply. User resolves, runs `git rebase --continue`. Skill resumes the cascade.
- **Force-push lease failure.** Branch was modified externally since the local copy. Investigate (likely a teammate pushed); never resolve by stripping `--force-with-lease`.
- **Base-redirect didn't happen on merge.** GitHub usually auto-redirects PR N+1's base to main when PR N merges. If `update` detects the base hasn't redirected (`baseRefName` still points at the merged-branch name), prompt user — may indicate auto-delete-on-merge is off, or the merge happened via a non-standard path.
- **Reviewer approved a PR that subsequently got restacked.** New commits invalidate the approval (GitHub default). Re-notify the reviewer; the body's "Revisions" section explains what changed.
- **Stale review state.** Reviewer comments reference code that's been rebased away. Flag in the body's Revisions section; suggest reviewer re-reviews the post-rebase diff.

Recovery is always: surface the situation, present 2–4 explicit options, never improvise. Same posture as incremental-release.
