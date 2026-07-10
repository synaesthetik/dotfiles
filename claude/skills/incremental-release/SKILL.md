---
name: incremental-release
description: Decompose a too-large code change into a sequence of independently-mergeable PRs (one open at a time), each cut from current main, with a per-chunk code-review pass. Persists state across sessions so the engineer can ship-and-resume over days/weeks.
argument-hint: <subcommand> [args] — one of: plan, status, inspect, ship-next, update-current, abort, replan
allowed-tools: Bash(git *) Bash(gh *) Bash(pipenv *) Bash(pytest *) Bash(npm *) Bash(make *) Bash(mkdir *) Bash(ls *) Bash(test *) Bash(diff *) Bash(stat *) Bash(shasum *) Bash(sha256sum *) Read Write Edit Grep Glob
---

# Incremental Release

Decomposes a too-large PR into a sequence of small, sequentially-shipped PRs. Only one PR is open at a time; each is cut from current `main` after the prior one merges. State persists in a manifest at `~/.claude/state/<repo>-<ticket>-incremental-release/`, so the engineer can step away — different repo, different machine, weeks later — and resume.

## When to use

- A PR is too large for human (or specialized agent) review in a reasonable time window (typically 30 min/PR).
- The author may not have full familiarity with their own code (e.g., AI-generated work) and wants a code-review pass on each chunk.
- Sequential review/merge is OK; team doesn't need parallel stacked PRs.

## When NOT to use

- The PR has a single atomic concern that can't be cleanly split. Splitting just for size makes review *worse*.
- Tightly time-boxed shipping (this workflow trades wall-clock for review quality).
- Team uses Graphite/ghstack and prefers parallel stacks. This skill is sequential-only.

## Sacred invariants

These hold across every subcommand. Violations are bugs.

1. **The source branch is read-only.** Never `git checkout <source-branch>` to switch onto it. Only `git checkout <source-branch> -- <paths>` to copy files out (a read operation; doesn't modify the branch). Never push, rebase, reset, force-push, amend, or delete the source branch.
2. **Only branches matching the manifest's `branch_pattern` accept writes.** Never push to `main`, `master`, the source branch, or any branch not in the manifest's PR list.
3. **Force-push only with `--force-with-lease`, only to a branch in the manifest's PR list.** Never force-push to anything else.
4. **Tests must pass on every PR before push.** Never `--no-verify`, never skip tests, never push and "fix later." If tests fail: stop, report, surface options.
5. **Source SHA is locked at plan time.** Files extracted via `git checkout <source>@<source_sha> -- <path>`. If the source branch has moved since plan time and the user wants the new state, they must run `replan`.
6. **One PR open at a time.** `ship-next` refuses to create PR N+1 until PR N is merged (verified via `gh pr view --json state`).
7. **Pre-flight checks before every commit/push:** verify `git rev-parse --abbrev-ref HEAD` matches the expected branch, verify `git status` shows no unintended files, verify `git remote -v` is unchanged.
8. **Surprise = stop.** Any unresolved merge conflict, dirty working tree, unfamiliar branch state, or test failure: stop and surface to the user. Never use destructive operations (`reset --hard`, `clean -fd`, `checkout -f`) as a workaround. Drift in shared files is handled via `git apply --3way`; only halt if the 3-way merge produces actual conflict markers.

9. **Source SHA is preserved by a tag.** `plan` pushes a `incremental-release-<ticket>-source` tag at plan time so the source SHA survives force-push of the source branch. `ship-next` reads files via the SHA (verified reachable via the tag if necessary).

## Manifest layout

```
~/.claude/state/<repo>-<ticket>-incremental-release/
├── manifest.json                  # top-level state, ordered PR list, cursor
├── pr-NN-<slug>/
│   ├── plan.json                  # ship_actions, code_review_focus, body_template_file
│   ├── body.md                    # PR body template (with placeholders)
│   └── patches/                   # unified diffs (small, focused, drift-resistant)
│       ├── <name>.patch           # e.g. scan_iter_fix.patch, add_redis_url.patch
│       └── ...
```

**No stored full files.** The source branch is our truth for new files; small patches handle improvements over source and additions to shared files. This keeps the manifest small, drift-resistant, and easy to audit.

`manifest.json` top-level fields:
- `source_branch`, `source_sha` — locked at plan time
- `source_protection_tag` — e.g. `incremental-release-PLAT-111-source`. Pushed at plan time so source_sha survives force-push.
- `main_branch`, `main_sha_at_plan` — for drift detection
- `branch_pattern` — e.g. `PLAT-111/{index:02d}-{slug}`
- `test_command` — e.g. `pipenv run pytest`
- `post_apply_commands` — ordered list of `{name, command, stages_files, required}` items. Runs after ship_actions and renames, before code review and tests. Common cases: regenerate OpenAPI schema, compile protobufs, generate TypeScript types from a schema, run a formatter on changed files. Each command runs in repo root; if `stages_files` is true, the skill runs `git add -u` after to pick up modifications. If `required` is true, a non-zero exit halts ship-next. Captured at plan time via repo discovery + user confirmation (see `plan` step "Release constraint discovery").
- `code_review` — `{primary_agent, fallback_agent, blocking_severities}`
- `release_context` — captured at plan time from step 6 (release context discovery). Shape: `{org_pipeline, ci_provider, ci_workflows[], branch_protection, pre_commit_hooks[]}`. Each subfield is null/empty if not detected. Used to render an optional "Release context" section in PR bodies, and to prioritize required vs optional `post_apply_commands`.
- `cursor` — index of the next PR to ship
- `halted` — boolean; true means workflow paused (e.g. after abort)
- `prs` — ordered list with per-PR metadata: `index, slug, branch, title, summary, status, pr_number, pr_url, shipped_at, merged_at`

Per-PR `plan.json` fields:
- `ship_actions` — list of `{type, ...}` items. Two action types only: `take_from_source` and `patch_main`.
- `renames` — list of `{source_path_in_source_branch, target_path, reason}`
- `test_command` — overrides manifest's default if set
- `code_review_focus` — list of strings; specific things to look for
- `review_findings_to_carry_into_pr_body` — findings caught during plan time that should appear in the PR body

## Subcommand: plan

Initialize a new incremental release for a too-large branch.

### Arguments

- `$0` — Source branch name (the too-large branch to split)
- `$1` — (Optional) Ticket prefix (e.g. `PLAT-111`); inferred from branch name if matched
- `$2` — (Optional) Repo path; defaults to `pwd`

### Procedure

1. Verify clean working tree (`git status` shows no uncommitted changes). If dirty, stop and ask the user to commit or stash.
2. Verify the source branch exists (`git rev-parse --verify <source>`).
3. Capture lockfiles: `git rev-parse <source>` → `source_sha`; `git rev-parse origin/main` → `main_sha_at_plan`.
4. **Push source-protection tag.** `git tag incremental-release-<ticket>-source <source_sha>` then `git push origin incremental-release-<ticket>-source`. This pins the source SHA against future force-pushes of the source branch. ship-next will recover from the tag if the SHA becomes unreachable locally.
5. **Detect default branch.** `git symbolic-ref refs/remotes/origin/HEAD` → `main_branch`. Falls back to `main` if the symbolic-ref is unset.
6. **Release context and constraints discovery.** Scan the repo for everything that affects how PRs ship and merge. The goal: surface the full picture so the user can decide what `post_apply_commands` are actually needed and so each PR's body can reference relevant constraints.

   **6a. Org-specific release pipelines.** Check for files that signal the codebase ships via a managed pipeline:
   - `.release-pipeline` — Greenhouse release pipeline marker. If present, note its contents and that this repo ships via the Greenhouse pipeline.
   - `lotus.yaml` — Greenhouse Lotus deployment config. Read components, datastores, firewall_rules.
   - `catalog-info.yaml` — Backstage catalog entry.
   - `service.yaml` / `cloudbuild.yaml` / `app.yaml` / `vercel.json` / `fly.toml` / `render.yaml` — common managed-platform manifests.
   - `Dockerfile` and `docker-compose*.yaml` — note if present (affects how tests run vs how prod runs).

   **6b. CI pipeline configs.** Inspect:
   - `.github/workflows/*.yml` — list workflow names + the commands they run
   - `.circleci/config.yml`, `.gitlab-ci.yml`, `Jenkinsfile`, `.buildkite/`, `azure-pipelines.yml`, `.drone.yml`, `.travis.yml`
   For each, extract: jobs that run on PRs, the commands they execute, what they gate on (status checks).

   **6c. Branch protection rules.** `gh api repos/<owner>/<repo>/branches/<main>/protection` (if accessible). Capture: required reviews count, required status checks, required signatures, restrictions. If `gh api` returns 403 (insufficient perms), note "could not read branch protection — assume merge requires green CI" and continue.

   **6d. Pre-commit hooks.** `.pre-commit-config.yaml`, `.husky/`, lint-staged config. Note what runs locally on commit (so we don't re-run in `post_apply_commands`).

   **6e. Post-apply command candidates.** Now scan for likely commands to run between patch application and tests:
   - `Makefile` — targets matching `schema`, `openapi`, `generate*`, `gen*`, `proto*`, `types`, `regen*`, `codegen`
   - `bin/` directory — scripts named `generate_*`, `regen_*`, `gen_*`, `compile_*`, `codegen*`
   - `package.json` `scripts` — entries matching `generate`, `gen:`, `build:types`, `openapi:`, `proto:`
   - `Justfile`, `Taskfile.yml`, `pyproject.toml` `[tool.poetry.scripts]`, `Cargo.toml` etc.
   - Cross-reference with **6c**: if CI requires a status check that runs schema-validation, prioritize the corresponding regen command as `required: true`.

   **6f. Present findings to the user.** Show a single coherent picture:
   ```
   Release context for <repo>:
   ──────────────────────────────────────────────────────────
   Org pipeline:   Greenhouse (.release-pipeline + lotus.yaml)
                   → ships on merge to main via Lotus
   CI:             GitHub Actions (.github/workflows/test.yml)
                   → runs `pipenv run pytest` on PRs
                   → required status check: ci/test
   Branch protection (main):
                   → 1 approving review required
                   → required checks: ci/test, ci/lint
   Pre-commit:     ruff, black (run locally on commit)

   Discovered post-apply command candidates:
   1. [✓] bin/generate_schema.sh  REQUIRED  — regenerate OpenAPI schema
                                            (CI runs test_schema.py which fails if schema drifts)
   2. [ ] make lint                          — runs ruff + black
                                            (already in pre-commit; not needed here)

   Any release constraints I missed? Type the command, or "none" to confirm.
   ```
   The user toggles entries, may add commands the skill missed (e.g., proprietary in-house codegen tools), and confirms. Capture the final selection as `post_apply_commands` in the manifest, and capture the broader release context (org pipeline, CI provider, branch protection) as `manifest.release_context` for inclusion in PR bodies.

7. **Cross-skill recommendation: stacked-release for managed-pipeline repos.** If step 6a detected any of: `.release-pipeline`, `lotus.yaml`, `cloudbuild.yaml`, GitHub Actions release workflows under `.github/workflows/release*`, or any other managed-pipeline marker — the codebase likely has a release cadence that batches merges into release windows rather than landing each approved PR immediately. Sequential-from-main (this skill's mode) waits for the prior PR to merge before opening the next one, which means N PRs × release-cadence wall-clock time. That's frequently a bad fit.

   Surface a recommendation to the user:
   ```
   ⚠️  Managed release pipeline detected (.release-pipeline + lotus.yaml).

   `incremental-release` is sequential-from-main: each PR waits for the
   prior to merge before the next opens. With release-pipeline cadence,
   that gates wall-clock time on release cycles — for 10 PRs this can
   mean weeks of waiting even with instant reviewer turnaround.

   Recommended: `/stacked-release plan <source>`. Stacked-release opens
   all PRs in parallel as a chain (PR N's base = PR N-1's branch); 
   reviewers can work concurrently and merges happen as the release 
   pipeline naturally progresses.

   Continue with incremental-release anyway? [y/N]
   ```

   Default no. Capture the recommendation and the user's decision in `manifest.release_context.recommendation`:
   ```json
   {
     "recommended_skill": "stacked-release",
     "reason": "managed pipeline detected (.release-pipeline)",
     "user_chose_to_override": false
   }
   ```

   If the user accepts the recommendation, exit cleanly and instruct them to run `/stacked-release plan <source>`. If they override, proceed; the override decision is logged in the manifest for traceability.

8. Compute `git diff <main_branch_sha>...<source_sha> --stat` for the file change inventory.
9. Filter out paths the user wants stripped (default: `.planning/`; ask interactively to confirm or extend).
10. Group changes into logical chunks. Strategy hints (in priority order):
    - Atomic functionality boundaries (don't split things that depend on each other)
    - Architectural layers (models → services → routers → UI)
    - Test files travel with their subject code
    - Schema regen happens automatically (don't manually slice schema.yaml; the regen command handles it)
11. Size each chunk against the target review budget (default 30min ≈ 300–500 reviewable LOC).
12. **Code-review pass** — for each chunk, spawn `gsd-code-reviewer` (or `general-purpose` fallback) on the chunk's diff, looking for:
    - Bugs and anti-patterns (e.g., `keys()` vs `scan_iter()`, `mock.patch` typos, missing error handling)
    - Duplicated/conflict-marked code (unresolved merge artifacts)
    - Style inconsistencies vs the rest of the codebase
    - Missing tests for new code
    Surface findings per-chunk; user decides per-finding: fix-now (captured as patch), defer-to-later-PR, acknowledge-and-ship.
13. Generate the body template for each PR (from a standard template + per-PR summary + carried-over findings).
14. Write `manifest.json` and per-PR `plan.json` + `body.md` files under `~/.claude/state/<repo>-<ticket>-incremental-release/`. Manifest is written atomically (temp file + rename) to handle concurrent skill invocations.
15. **Plan preview gate.** Print:
    - Source: `<source>@<sha[:8]>` ("<latest commit subject>")
    - Main: `<main_branch>@<sha[:8]>`
    - Files affected: count, breakdown of added/modified/deleted/renamed
    - Proposed PRs (table): index, branch, title, estimated review minutes, file count, code-review findings count
    - Manifest path
    Then ask: **"Open PR 1 (`<branch>`) and start the queue? [y/N]"**. Default no.
16. **If confirmed:** invoke `ship-next` internally to open PR 1.
    **If declined:** manifest is saved; print "Manifest saved at `<path>`. Run `/incremental-release status` to review, `/incremental-release inspect <n>` to dig into a specific PR's plan, or `/incremental-release ship-next` when ready."

### After plan

If user confirmed: manifest exists with `cursor=2` (PR 1 was just shipped). User reviews PR 1; once it merges, runs `/incremental-release ship-next` to ship PR 2.

If user declined: cursor=1. User runs `ship-next` manually when ready.

## Subcommand: status

Print a human-readable view of the current manifest.

### Arguments

None (uses repo path to find the matching manifest directory).

### Procedure

1. Locate manifest: search `~/.claude/state/*-incremental-release/manifest.json` where `repo_path` matches `pwd`. If none found, report and stop.
2. Read manifest. For each PR in `prs[]`:
   - `merged` — fetch latest state via `gh pr view <pr_number> --json state` (handles cases where merged externally)
   - Pretty-print as a table:

```
Incremental Release: <ticket> on <repo>
Source: <source_branch>@<source_sha[:8]>  Main@plan: <main_sha_at_plan[:8]>
Cursor: PR <cursor> (next to ship)  Halted: <halted>

#  Branch                            Status         PR     Review time
─  ────────────────────────────────  ─────────────  ─────  ───────────
1  PLAT-111/01-models                ✅ merged       #128   15min
2  PLAT-111/02-redis-client          🔄 in flight    #129   15min
3  PLAT-111/03-cluster-discovery     ⏸  planned      —      20min
...
```

3. If any PR is `in_flight`, also print: "Run `/incremental-release ship-next` once #N merges to ship PR N+1."

## Subcommand: inspect

Read-only dump of a specific PR's plan.

### Arguments

- `$0` — PR index (1-based)

### Procedure

1. Locate manifest. Read `pr-NN-<slug>/plan.json` and `body.md`.
2. Print:
   - Branch name, title, summary, depends_on
   - Ship actions (file paths, source/target, reasons)
   - Renames
   - Code review focus areas
   - Review findings carried into body
   - Body preview
3. No state changes.

## Subcommand: ship-next

Ship the next PR in the queue.

### Arguments

None (uses cursor from manifest).

### Procedure

1. **Verify prerequisite is merged.**
   - If `cursor == 1`, prerequisite is the manifest's `main_branch`; skip this check.
   - Otherwise: get `prs[cursor-2]` (the previous PR). If `pr_number` is null, abort with "Previous PR was never opened — run `replan`?"
   - Run `gh pr view <prev_pr_number> --json state,mergedAt`. Parse:
     - If `state == "MERGED"`: proceed.
     - If `state == "OPEN"`: stop with "Waiting on #<N>; review and merge first."
     - If `state == "CLOSED"` and not merged: stop with "Previous PR was closed without merging. Investigate, then `replan` or manually re-open."
   - Update the prior PR's manifest entry: `status = "merged"`, `merged_at = mergedAt`.
2. **Verify clean working tree.** If dirty, stop and ask user to handle.
3. **Update local main.** `git fetch origin <main_branch>` then `git checkout <main_branch>` then `git pull origin <main_branch>`. Note: this is one of two places we may switch onto `main` — read-only intent (we only switch to use as a base, not to commit).
4. **Branch collision check.** Verify the target branch doesn't already exist:
   - `git rev-parse --verify <target_branch>` — if local exists, ask user: delete the stale local branch, rename it (`<target>.bak-<timestamp>`), or abort.
   - `git ls-remote --exit-code origin <target_branch>` — if remote exists, ask user: was this PR previously opened (open it instead via `update-current`?), or delete the remote (only if user confirms it's stale), or abort.
   Once clean: `git checkout -b <prs[cursor-1].branch>`.
5. **Apply ship actions in order.** For each action in `plan.json -> ship_actions`:
   - **`take_from_source`** — verify `source_sha` is reachable: `git rev-parse <source_sha>` (if it fails, run `git fetch origin <source_protection_tag>` to recover). Then `git checkout <source_sha> -- <path>`. If `post_patches` is set, apply each via the patch-apply procedure below. Stage with `git add <path>`. Use this for files the PR creates/owns; post_patches handle improvements over source (e.g., bug fixes caught by the plan-time code review).
   - **`patch_main`** — for shared files (config, conftest, schema). The file already exists on disk from the just-cut main branch. Apply via the patch-apply procedure below. Stage.

   **Patch-apply procedure** (used by both action types):
   1. `git apply --check <pr-dir>/patches/<name>.patch`. If clean → `git apply <pr-dir>/patches/<name>.patch`. Done.
   2. If `--check` fails (context drift): `git apply --3way <pr-dir>/patches/<name>.patch`. This uses the patch's `index` lines to do an ancestor-aware merge.
   3. If `--3way` produces conflict markers (`<<<<<<<` in any file): stop. Surface to user with options: (a) edit the file/patch manually and continue, (b) `replan` from this PR onward, (c) `abort`.
   4. If `expected_main_sha256` is set on the action (informational/audit only): compute current sha256, log it. If it differs from the recorded value, note in the PR body that drift was reconciled. Do NOT block on this alone.

   Patches are stored as standard unified diffs in `<pr-dir>/patches/`. They should be small, focused (one logical change per patch when possible), and reference the file paths they apply to.
6. **Apply renames.** For each `renames[]` entry: `git mv <source> <target>` (or `git rm` + `git add` if cross-directory). Note: source path is from the source branch, so first `git checkout <source_sha> -- <source_path>`, then `git mv` to target.

7. **Run post-apply commands.** For each item in `manifest.post_apply_commands` (in order):
   - Print the command name + command string.
   - Run the command from repo root.
   - If `stages_files`: `git add -u` to pick up modifications.
   - If exit code is non-zero AND `required` is true: stop. Surface stderr. Options: skip-this-command (if not required), abort.
   - If `required` is false and the command fails: log the failure, continue.
   Skip this step entirely if `post_apply_commands` is empty/missing. **Why this step exists:** repo-specific derived artifacts (OpenAPI schemas, generated TypeScript types, compiled protobufs, formatter passes) need to run after code changes but before tests, so the PR's diff includes their effects atomically and tests assert the up-to-date state. Captured at plan time via repo discovery.
8. **Run code-review pass.** Spawn `gsd-code-reviewer` (fallback `general-purpose`) with prompt:
   - "Review the staged changes on the current branch against `main`. Focus areas: <plan.json.code_review_focus>. Flag any: bugs, anti-patterns, duplications, missing tests, style drift, security issues. Severity buckets: critical, high, medium, low, info."
   - Wait for findings. If any with severity in `manifest.code_review.blocking_severities`: surface to user per-finding with three options:
     - **fix-now**: user describes the fix; agent applies; capture as a new patch in `<pr-dir>/patches/`; loop back to step 8.
     - **acknowledge-and-ship**: add finding to PR body; proceed.
     - **abort**: discard changes, return cursor unchanged. Run cleanup: `git checkout main && git branch -D <branch>`.
9. **Run tests.** Execute `manifest.test_command` (or `plan.json.test_command` override). If failures:
   - Surface output. Options:
     - **fix-now**: user describes; agent applies; re-test. Capture the fix as a new patch in `<pr-dir>/patches/` so a future `replan` reproduces it.
     - **override**: requires explicit token of the form `override-test-failure-<ticket>-<pr-index>` (e.g. `override-test-failure-PLAT-111-02`). High friction by design — typos shouldn't ship broken PRs.
     - **abort**: cleanup as in step 8.
   - Never proceed past failures without one of the above.
10. **Final commit.** Construct commit message from `plan.json.body_template` + carried findings. Format the message body so `git commit -m "$(cat <<EOF ... EOF)"` produces clean output. Sign-off following project convention if present.
11. **Push.** `git push -u origin <branch>` (no force on first push).
12. **Open PR via `gh pr create`.**
    - `--base main` (always — sequential-from-main)
    - `--head <branch>`
    - `--title <plan.json.title>`
    - `--body` from `<pr-dir>/body.md` with placeholders substituted (see "Body placeholders" section below).
13. **Update manifest.** `prs[cursor-1].status = "in_flight"`, `pr_number`, `pr_url`, `shipped_at`. Increment cursor.
14. **Status report.** Print "Shipped PR #<n> at <url>. Run `/incremental-release ship-next` once it merges to ship PR <cursor>/<total>."

**Merged PRs are not modified after merge.** Each PR's body is rendered once at creation time. The "what's coming next" table reflects the queue at that moment; reviewers can `/incremental-release status` if they need a live view. Reaching back to update merged PRs would add complexity without benefit — a merged PR is a checked box.

### Stack progress chart helper

When rendering `{{stack_progress_chart}}` in PR bodies:

```markdown
## Stack progress (PLAT-111)

| # | PR | Description | Status |
|---|----|-------------|--------|
| 1 | #128 | Pydantic models | ✅ merged |
| 2 | **#129** | Redis client | 🔄 **this PR** |
| 3 | — | Cluster discovery | ⏸ planned |
| ... | | | |
```

The reviewer sees their PR bolded and the chain context.

## Subcommand: update-current

Apply review-feedback changes to the currently in-flight PR.

### Arguments

- `$0` — (Optional) Free-text description of changes to apply. If absent, prompt interactively.

### Procedure

1. Locate manifest. Find the in-flight PR (`status == "in_flight"`). If none, stop with "No PR is currently in flight."
2. Verify HEAD is on the in-flight PR's branch. If not, `git checkout <branch>`.
3. Verify clean working tree. If dirty, stop.
4. Apply the user-described changes via Edit/Write tools. Stage as you go.
5. **Re-run code-review pass** on the new diff vs `main`. Same flow as `ship-next` step 7.
6. **Re-run tests.** Same flow as `ship-next` step 8.
7. **Commit.** New commit on top of the branch (don't amend — preserves review history).
8. **Push with `--force-with-lease`** (only because the PR may have already been reviewed; new commits are added, not history rewritten — `--force-with-lease` is a safety net in case GitHub state diverged).
   - Actually: prefer `git push origin <branch>` (no force) unless we rewrote history. Detect via `git log origin/<branch>..HEAD` count; if 0 we're not advancing, if >0 we are.
9. Update manifest: append a `revisions[]` entry under the PR's record with timestamp + summary of changes.
10. Status report: print "PR #N updated. Push pushed. Reviewers will be notified."

## Subcommand: abort

Close the in-flight PR (or halt before opening one), clean up the branch, and mark the workflow halted.

### Arguments

None.

### Procedure

1. Locate manifest. Determine state:
   - If a PR is in flight: close via `gh pr close <pr_number> --comment "Closing — incremental-release abort. Will re-plan and re-ship."`
   - If no PR in flight (cursor points at planned): nothing to close.
2. If on a stack branch: `git checkout main; git branch -D <branch>; git push origin --delete <branch>` (if remote exists).
3. Set `manifest.halted = true`. Update the affected PR's status to `closed` (with `closed_reason: "abort"`).
4. Status report: print "Aborted. Run `/incremental-release replan` to revise the plan, or manually edit the manifest."

## Subcommand: replan

Re-plan a halted or mid-stack workflow. Common triggers: source branch updated, chunk strategy needs revision, or user wants to re-cut PR contents.

### Arguments

- `$0` — (Optional) `--from-pr <n>`: re-plan from PR `n` onward, preserving merged PRs upstream. Default: full re-plan.

### Procedure

1. Locate manifest. If `--from-pr <n>`:
   - Validate that PRs 1..n-1 are all merged (else stop, ask user to merge or abort first).
   - Truncate `prs[]` to keep 1..n-1, then re-plan n..end.
2. Refresh source SHA: `git fetch origin && git rev-parse <source_branch>`. If different from manifest's `source_sha`, ask user to confirm new SHA before proceeding.
3. Refresh main SHA similarly.
4. Re-compute the file change inventory. Diff against the prior plan; show user what changed.
5. Run the planning loop (same logic as `plan` step 6+): regroup chunks, size, code-review pass, generate plans.
6. Write updated manifest and per-PR files. Old per-PR directories for affected PRs are renamed to `pr-NN-<slug>.replanned-<timestamp>/` for audit trail (never deleted).
7. Set `halted = false`, set cursor to `n` (or 1 if full replan).
8. Status report: "Replanned. Run `/incremental-release ship-next` to ship PR <cursor>."

## Code review subagent prompt template

When invoking the code reviewer for a chunk:

```
Review the following file diff against `main`:

<paste git diff main...HEAD output, or git diff --staged>

Context: this is chunk <N> of <M> in an incremental release of a larger
branch. Source branch is `<source>`. Target review time: <K>min.

Focus areas (from plan.json.code_review_focus):
- <focus area 1>
- <focus area 2>
- ...

Flag findings in these severity buckets:
- critical: would break production or tests in main
- high: latent bugs, performance traps, security issues
- medium: maintainability, missing tests, style drift
- low: nits, naming, doc gaps
- info: observations, not actionable

Output structured JSON:
{
  "findings": [
    {"id": "<short-id>", "severity": "...", "file": "<path>",
     "line": <int|null>, "issue": "...", "suggested_fix": "..."}
  ],
  "summary": "<one-sentence overall verdict>"
}
```

## Manifest discovery

Subcommands other than `plan` need to locate the active manifest given the engineer's `pwd`.

1. List `~/.claude/state/*-incremental-release/manifest.json` files.
2. For each, read `repo_path`. If it matches `pwd` (or `pwd` is a subdir of it), it's a candidate.
3. If exactly one match: use it.
4. If multiple matches: present a picker showing ticket, source branch, cursor, halted status. User selects.
5. If zero matches: error with "No incremental-release manifest found for this repo. Run `/incremental-release plan <source-branch>` to start one."

## Body placeholders

PR body templates use `{{placeholder}}` syntax. The skill substitutes these at PR-create time and re-render time (step 14 of `ship-next`). Defined placeholders:

- `{{prev_pr}}` — `#<previous PR's pr_number>` if cursor > 1, else the literal `main` (PR 1 has no prior PR; this placeholder generally shouldn't appear in PR 1's body)
- `{{prev_pr_url}}` — full URL to the previous PR
- `{{this_pr_index}}` — current PR's index (e.g. `2`)
- `{{total_prs}}` — total count of PRs in the stack
- `{{increments}}` — the rendered vertical "Increments" section with a "we are here" marker (see below)
- `{{ticket}}` — the manifest's ticket (e.g. `PLAT-111`)
- `{{source_branch}}` — name of the source branch
- `{{review_findings_section}}` — bulleted list of `review_findings_to_carry_into_pr_body` entries; empty string if none

Increments format (vertical, role-tagged, "we are here" marker):

```markdown
## Increment {{this_pr_index}}/{{total_prs}}

```
  ✓ 1 · Models                       foundation: data shapes
  ✓ 2 · Redis client                 foundation: state storage
  ▶ 3 · Cluster discovery            ◀ we are here — first layer of OpenSearch reads
    4 · Snapshots & repos            full discovery surface
    5 · Indices                      indices listing
    6 · Restore service              restore execution layer (no router yet)
    7 · Restore router + Slack       HTTP surface for restore + lifecycle Slack
    8 · Restore monitor              background lifecycle tracking
    9 · Web UI: browse               read-only OpenSearch UI
   10 · Web UI: restore + tracking   full restore UX
```
```

Row format: `<status-icon> <index> · <display_name>  <role>`. Two columns aligned for readability.

The "we are here" framing is intentional — it conveys collaboration ("the team is shipping this together") rather than an audit-style "you are PR N." The `▶` marker on the row plus the `◀ we are here` callout double-anchor the reviewer's position.

## Per-PR body composition

Each PR's body should include the following sections, in this order. The skill generates the body from the manifest + per-PR plan; the body template at `<pr-dir>/body.md` provides the scaffolding.

### Required (every PR)

1. **Scope** — terse fact line: file count, LOC, one-phrase scope description. Don't editorialize about triviality, risk, or impact; let the reviewer calibrate from the diff.
2. **Origin** — one paragraph noting how this work originated (e.g., AI-assisted, regular feature work) and that the `incremental-release` skill ran a code-review pass before the PR opened. Disclose AI origin without apology or extra warning — reviewers should know the provenance.
3. **What this PR does** — concrete bulleted list of additions/changes.
4. **What to focus on** — terse 3–4 bullets specific to this PR. For a models PR: type correctness, naming consistency. For a service PR: error handling, retry semantics, side-effect boundaries. For a router PR: input validation, status code choices, auth.
5. **Test plan** — checkboxes; what was verified locally + what reviewer should confirm.
6. **Increments** — the rendered "we are here" visual (`{{increments}}` placeholder).
7. **Release context** — populated from `manifest.release_context`; tells the reviewer how this PR ships and what gates merge.

### Conditional (include only when valuable)

- **What's NOT in this PR** — include when the reviewer might reasonably wonder about a missing piece (e.g., a models-only PR with no consumers, a service-without-router PR). Skip when the PR's contents are self-explanatory.
- **Test housekeeping** — include when test files are renamed, moved, or restructured in ways that look weird in isolation. Always inline-attribute with `*(caught at <when> review)*` if applicable.
- **Caught at <when> review** — when the code-review pass found and fixed something, surface it. Pulled from `plan.json.review_findings_to_carry_into_pr_body`. Can also live as an inline annotation on another section's header (e.g., `## Test housekeeping *(caught at plan-time review)*`).
- **Carried-over fixes / amendments** — include when `update-current` applied changes mid-flight.

**Attribution language for findings:**

The "code-review pass" can be performed in two modes — both count as the skill's review:
- **Spawned subagent** (`gsd-code-reviewer` or `general-purpose`) — the standard mode at ship time.
- **Claude during the planning conversation** — when bootstrapping the skill itself (e.g., the very first stack it ships) or when the user is pair-planning a chunk interactively.

When attributing a finding in a PR body, prefer:
- `*(caught at plan-time review)*` — finding flagged during `plan` (or during planning conversation).
- `*(caught at ship-time review)*` — finding flagged during `ship-next`'s code-review step.

Avoid the word "automated" in PR bodies when the finding may have come from Claude+user planning rather than a spawned agent. The mechanism doesn't matter to the reviewer; the systematic check is the thing.

### One-shot only (PR 1 of the first stack the team ships via this skill)

- **About the skill** — full workflow explanation (sequential-from-main, manifest, code-review pass, etc.). Subsequent PRs in the same stack get a passing reference at most ("Decomposed via the `incremental-release` skill — see #<PR1> for the workflow overview"). Subsequent stacks (different ticket / different team-member) likewise get a passing reference, not the full overview.

### Anti-patterns — DO NOT include

- **Links to the source branch.** Each PR must stand on its own merits, mergeable based on its diff against current main. Linking to the source branch undermines that — it suggests reviewers should "look at the bigger picture" when the bigger picture should be invisible.
- **Cross-references to PRs that don't exist yet.** Use branch names (`PLAT-111/03-cluster-discovery`), not `#N` placeholders.
- **Heavy preambles before the diff context.** "Scope" should be at the very top so a reviewer scrolling fast can calibrate in 5 seconds.

Status icons:
- `✓` — merged
- `▶` — current increment (also append `◀ we are here — ` prefix to the role column)
- (blank, two spaces) — planned
- `✗` — closed

`display_name` and `role` are per-PR fields in `manifest.prs[]`, captured at plan time. `display_name` is a 1–3 word noun phrase; `role` is a one-line verb-or-noun phrase that helps a reviewer understand what work this PR represents in the arc.

## Failure handling

Any of the following: stop, surface to user, never improvise:

- Test failure (only proceed via explicit override token)
- Merge conflict that `--3way` couldn't reconcile (file contains conflict markers)
- `gh pr view` returns unexpected state
- Network error mid-push or mid-PR-create
- Source SHA unreachable AND `source_protection_tag` fetch failed
- Manifest `schema_version` doesn't match the skill's expected version
- Branch already exists (local or remote) and user declined the offered options
- Code review subagent crashed or returned malformed output

Recovery is always: surface the situation, present 2–4 explicit options to the user. Never `git reset --hard`, never `git push --force` (without `--force-with-lease`), never delete branches without explicit user confirmation, never skip tests without the override token.
