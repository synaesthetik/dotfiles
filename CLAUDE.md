<!-- GSD:project-start source:PROJECT.md -->
## Project

**dotfiles**

A single central dotfiles repository that consolidates Patrick's Claude/AI setup, shell configuration, git configuration, and package/tool manifests into one source of truth. A bootstrap script turns a brand-new Mac into a fully configured machine with one command, and GNU Stow symlinks keep the live system and the repo in sync so edits go live instantly. Built for personal use across Patrick's own machines.

**Core Value:** On a fresh Mac, one bootstrap command restores the complete working environment — Claude/AI config, shell, git, and all tools — with zero manual reconstruction.

### Constraints

- **Tech stack**: GNU Stow for symlink management — chosen for transparency and git-friendliness over chezmoi/bare-git/copy approaches
- **Platform**: macOS only — bootstrap assumes a Mac (Homebrew, macOS conventions)
- **Compatibility**: migration must be non-destructive — existing live configs keep working throughout
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| GNU Stow | 2.4.1 (`brew install stow`) | Symlink farm manager — repo holds real files, symlinks land in `$HOME` | Already decided by the user; current stable per Homebrew formula. No change needed. |
| Homebrew | latest (self-updating; bootstrapped via official installer) | macOS package manager, foundation of the whole bootstrap | Only realistic package manager for a personal Mac in 2026; installs itself, Xcode CLT, and everything else the bootstrap needs. |
| Homebrew Bundle (`brew bundle`) | built into Homebrew core since Apr 22, 2025 (formerly the separate `Homebrew/homebrew-bundle` tap) | Declarative package manifest (`Brewfile`) covering `brew`, `cask`, `mas`, `vscode`, `tap`, plus newer `go`/`cargo`/`uv`/`krew`/`winget`/`flatpak` entry types | `brew bundle install --file=Brewfile` is the standard "restore all packages" primitive; `brew bundle dump --describe --force` regenerates the manifest from what's actually installed. No separate tap step is needed anymore — **do not** `brew tap homebrew/bundle`, it's a no-op/deprecated step in current Homebrew. |
| mise | 2026.7.2 (calendar-versioned; `brew install mise`) | Runtime version manager (Node, Python, Ruby, Go, etc.) | Rust binary, no shim overhead (PATH-based activation, ~5-10ms vs asdf's shim-per-call cost), single tool replaces nvm/pyenv/rbenv/goenv, reads asdf's plugin registry as a fallback so nothing in the ecosystem is unavailable. This is the 2025/2026 default pick over asdf. |
| 1Password CLI (`op`) | 2.34.1 (`brew install --cask 1password-cli`) | Secret resolution at bootstrap/shell-start time | See dedicated Secrets section below — this is the recommended approach. |
| bash (system `/bin/bash` 3.2) | n/a (ships with macOS, do not upgrade before Homebrew exists) | Bootstrap entry-point script only | The very first script (`bootstrap.sh`) runs *before* Homebrew and therefore before any newer bash is available. Write it against bash 3.2 semantics (no associative arrays, no `mapfile`) with `set -euo pipefail`. Once Homebrew is installed, later scripts may assume a modern bash from `brew install bash` if desired — but the entry point itself must not depend on it. |
| zsh | macOS default shell since Catalina (10.15) | Target shell for the actual stowed configs (`.zshrc`, etc.) | This is the shell the user already has and is migrating — no reason to introduce a different target shell for the *configs themselves*, only the bootstrap script needs bash-3.2 portability. |
### Supporting Libraries
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `mas` (Mac App Store CLI) | latest via `brew install mas` | Install Mac App Store apps declaratively | Only if any tools in the target set (Xcode, Pages, etc.) come from the App Store; declare as `mas "App Name", id: 12345` in the Brewfile — `brew bundle` handles installation directly, no separate script needed. |
| shellcheck | latest via `brew install shellcheck` | Static analysis for the bootstrap/install bash scripts | Dev-time only; run against every `.sh` file in the repo before committing. |
| shfmt | latest via `brew install shfmt` | Consistent bash formatting | Pairs with shellcheck; optional but keeps a multi-script bootstrap readable over time. |
| bats-core | latest via `brew install bats-core` | Bash test framework | Optional — the user's global CLAUDE.md defaults to red/green TDD for testable behavior but explicitly allows IaC/one-off scripts to opt out if stated. Bootstrap/install scripts are borderline: idempotency checks (e.g., "running stow twice doesn't error", "Brewfile diff is empty after a second bundle install") are testable and bats-core is the standard tool if the user wants that coverage. Otherwise, explicitly note the opt-out per the global convention. |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| `brew bundle dump --describe --force` | Regenerate `Brewfile` from currently-installed packages, with comments | Run periodically after `brew install`/`brew install --cask` so the manifest stays the source of truth instead of drifting. |
| `brew bundle check --verbose` | Verify the current machine matches the Brewfile without installing anything | Good as a pre-flight / CI-less sanity check before a bootstrap run. |
| `brew bundle cleanup --force` | Remove packages not listed in the Brewfile | Optional, aggressive — only wire this into the bootstrap if the user wants strict manifest enforcement; otherwise leave manual. |
| `stow -R` / `stow --adopt` | Re-stow after adding files; adopt existing real files into the repo | `--adopt` is specifically useful during the one-time migration of existing live configs into the repo (moves the real file into the repo dir and replaces it with a symlink) — matches the "migrate existing configs first" requirement in PROJECT.md. |
| `code --list-extensions` | Legacy VS Code extension export | **Superseded** — see Brewfile's native `vscode` entry type below. Only needed once, to seed the initial Brewfile list. |
## Installation
# 1. Bootstrap entry point (bash 3.2 compatible, runs before Homebrew exists)
#    e.g. ./bootstrap.sh or `curl -fsSL <raw-repo-url>/bootstrap.sh | bash`
# 2. Install everything declared in the manifest (formulae, casks, App Store apps, VS Code extensions)
# 3. Apply dotfiles via Stow (per package directory)
# 4. Runtime versions (Node/Python/etc.) declared in a stowed mise config
# 5. Secrets — resolve op:// templates into gitignored real files (see Secrets section)
# Dev tooling for maintaining the bootstrap scripts themselves
### Brewfile shape (example)
# mas "Xcode", id: 497799835
## Secrets Management — Recommendation
### Why this over the alternatives
- **Zero secrets ever touch git — not even encrypted.** Templates containing `op://vault/item/field` references are 100% safe to commit; the actual secret values never exist in the repo in any form, so there's no encrypted blob to accidentally leak, no key-rotation-on-compromise story, and no diff-review burden for "is this ciphertext actually new."
- **Composes cleanly with Stow.** Keep the secret-bearing file as a `.tpl` sibling inside the relevant Stow package (so it lives next to the config it belongs with), but do **not** stow the `.tpl` itself — the bootstrap script renders it directly into `$HOME` with `op inject`, gitignored:
- **Matches the "zero-to-ready" goal.** On a blank Mac, after `op signin` (one manual auth step, unavoidable with any approach), the bootstrap script can resolve every secret automatically — no hunting through password managers by hand, no re-typing API keys from memory.
- **No key-custody problem.** SOPS+age and git-crypt all have a bootstrapping paradox: the encryption key itself must come from *somewhere* on a blank Mac, and that somewhere is usually "manually copy an age/GPG private key file via AirDrop/USB before you can decrypt anything." 1Password sidesteps this because the credential store (1Password itself, via iCloud/1Password sync) is already the trusted distribution channel — Touch ID / system keychain unlocks it, no separate key file to protect or back up.
- **Auth is already biometric.** `op inject` resolves in ~200-400ms with Touch ID/biometric unlock enabled — fast enough to call once at shell startup or once during bootstrap without a noticeable delay.
### What this looks like day-to-day
- Values that belong in `~/.zshrc`, `~/.claude/settings.json`, `~/.npmrc`, etc. get pulled out into small `.tpl` files with `op://` references, tracked in git.
- The main config file sources the rendered secrets file if it exists (`[ -f ~/.zshrc.secrets ] && source ~/.zshrc.secrets`), so the repo works even before `op signin` has happened (secrets-dependent features just no-op).
- Re-running `op inject` is the update path when a secret rotates — no git commit involved.
### Sources
- [1Password CLI: Load secrets into scripts](https://developer.1password.com/docs/cli/secrets-scripts) — `op inject` mechanics, HIGH confidence (official docs)
- [Homebrew formula: 1password-cli, v2.34.1](https://formulae.brew.sh/cask/1password-cli) — version, HIGH confidence
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|--------------------------|
| 1Password CLI (`op inject`) | SOPS + age | No 1Password subscription, or a strong preference for fully offline/FOSS tooling with no dependency on a commercial vault. Encrypts values (not keys) in YAML/JSON so diffs stay readable; `age` recipient/identity keypair replaces GPG's complexity. Tradeoff: the age private key itself must be manually distributed to each new Mac before the repo is useful (no bootstrapping shortcut) — usually solved by storing the key in iCloud Keychain or a password manager, which somewhat undercuts the "no commercial vault dependency" argument. |
| 1Password CLI (`op inject`) | Plain untracked `.local` files sourced by shell config (e.g., `~/.zshrc.local`, gitignored) | Simplest possible approach, zero new tooling, zero learning curve. Acceptable if the user actively wants to avoid any secrets tooling at all. Downside: does not compose with "zero-to-ready bootstrap" — there is no source of truth to bootstrap *from*, so every new Mac requires manually re-typing/re-copying every secret by hand, which is exactly the manual-reconstruction problem the project's Core Value is trying to eliminate. |
| mise | asdf | Only if the user has an existing team/CI standardized on asdf's shim architecture and plugin ecosystem elsewhere. Not applicable here (single personal user, no team constraint) — mise is strictly faster and reads the same asdf plugin registry, so there's no capability lost by switching. |
| Homebrew Bundle native `vscode` entries | `code --list-extensions` export script | If VS Code isn't installed yet at Brewfile-apply time (native `vscode` entries require `code` on PATH to install extensions), or if extensions need to be installed as a distinctly separate step from package installation for sequencing reasons. |
| Bootstrap as a plain `bootstrap.sh` | Makefile-driven bootstrap (`make bootstrap`, `make stow`, `make brew`) | A Makefile is a fine *day-2* convenience layer once Homebrew/Xcode CLT already exist (discoverable via `make help`, gives named targets for `stow`, `brew-check`, `update`). It should not be the very first entry point, though: on a genuinely blank Mac, invoking `git`/`make` before Xcode Command Line Tools exist can trigger an interactive GUI installer prompt that isn't scriptable. The official Homebrew install script handles CLT installation itself; a plain bash `bootstrap.sh` as the true first command sidesteps the ordering hazard. A Makefile can wrap everything *after* that first step. |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|--------------|
| git-crypt | Encrypts whole files as opaque binary blobs — diffs become useless (`git diff` shows nothing meaningful pre/post change), no per-value granularity, GPG key management is heavier than age's. Materially worse than SOPS+age for a 2025/2026 dotfiles repo even as a fallback option. | SOPS + age (if avoiding 1Password), or 1Password CLI (primary recommendation). |
| `brew tap homebrew/bundle` | Unnecessary as of Homebrew merging `homebrew-bundle` into `Homebrew/brew` core (April 2025). Many older tutorials still show this tap step; it's a harmless no-op on current Homebrew but signals stale guidance. | Just use `brew bundle` directly — no tap required. |
| asdf (classic, shim-based) | Shims add per-invocation overhead (~120ms) to every runtime call; historically pure-bash implementation was slower for installs too. The 2025 Go rewrite closed some of the gap but mise remains faster and simpler to install (single static binary vs asdf's shell-plugin architecture). | mise |
| nvm / pyenv / rbenv (single-language version managers) | Redundant once mise is adopted — mise natively handles Node, Python, Ruby, Go, and dozens of others through one config file and one activation hook, instead of stacking N separate tools with N separate shell init blocks. | mise, with `.mise.toml` or `~/.config/mise/config.toml` declaring all runtimes |
| Plaintext secrets committed directly in tracked dotfiles (e.g., API keys inline in `.zshrc`) | The exact failure mode PROJECT.md flags as a concern (`~/.claude/settings.json` and shell configs may already contain API keys/tokens) | 1Password CLI `op inject` templates (primary), or gitignored `.local` files (fallback) |
| Writing the true bootstrap entry point in a language/tool that isn't guaranteed present on a factory-fresh Mac (Python, Ruby, Node, `make` before CLT) | The whole point of "zero-to-ready" is that nothing beyond what Apple ships is a hard prerequisite | Plain bash (`/bin/bash`, ships with macOS) as the very first script; everything else can depend on Homebrew-installed tools once that step completes |
## Stack Patterns by Variant
- Use `stow --adopt` to pull the currently-live real file into the repo directory and replace it with a symlink in one step, rather than manually copying then deleting then re-stowing.
- Because this directly satisfies the "non-destructive migration, existing configs keep working throughout" constraint in PROJECT.md — `--adopt` never breaks the live file, it just relocates it under Stow's management.
- Use `op read op://vault/item/field` directly in the bootstrap script rather than rendering a persistent `.tpl` file.
- Because one-shot bootstrap-time secrets don't need a standing gitignored file on disk at all — resolve, use, discard.
- Keep all machine-specific values (hostnames, per-machine tool lists) in a small untracked `~/.config/mise/config.local.toml`-style override or a `Brewfile.local` included from the main `Brewfile` via `eval $(cat Brewfile.local 2>/dev/null)`-style guard, rather than branching the whole repo per machine.
- Because Stow, Brewfile, and mise all support this "shared manifest + small local override" shape natively, avoiding repo forks per machine.
## Version Compatibility
| Package A | Compatible With | Notes |
|-----------|------------------|-------|
| Homebrew (current) | `brew bundle` native `vscode`/`mas`/`go`/`cargo`/`uv`/`krew` entry types | Requires Homebrew from April 2025 or later (when `homebrew-bundle` was merged into core); any Homebrew installed via the current official installer already satisfies this. |
| mise 2026.7.2 | asdf plugin registry (fallback) | mise falls back to asdf's plugin format for tools without a native mise plugin — no ecosystem tools become unavailable by switching. |
| GNU Stow 2.4.1 | macOS system `perl` (Stow is a Perl script) | No action needed — macOS ships a system Perl sufficient for Stow; do not let Homebrew's Perl shadow it in a way that breaks Stow's shebang resolution. |
| 1Password CLI 2.34.1 | 1Password 8 desktop app, "Integrate with 1Password CLI" setting | The CLI's biometric-unlock fast path requires the desktop app installed and that integration toggle enabled (Settings → Developer) — without it, `op` falls back to interactive `op signin` with a service account or manual unlock, which is fine for bootstrap but not for a snappy per-shell-startup secret load. |
## Sources
- [Homebrew Formulae: stow (2.4.1)](https://formulae.brew.sh/formula/stow) — version, HIGH confidence
- [Homebrew Formulae: mise (2026.7.2)](https://formulae.brew.sh/formula/mise) — version, HIGH confidence
- [Homebrew Formulae: sops (3.13.2)](https://formulae.brew.sh/formula/sops) — version, HIGH confidence (fallback path)
- [Homebrew Formulae: age (1.3.1)](https://formulae.brew.sh/formula/age) — version, HIGH confidence (fallback path)
- [Homebrew cask: 1password-cli (2.34.1)](https://formulae.brew.sh/cask/1password-cli) — version, HIGH confidence
- [Homebrew Docs: Brew Bundle and Brewfile](https://docs.brew.sh/Brew-Bundle-and-Brewfile) — entry types (`brew`/`cask`/`tap`/`mas`/`vscode`/`go`/`cargo`/`uv`/`winget`/`krew`/`flatpak`), subcommands (`install`/`check`/`dump`/`cleanup`/`list`), HIGH confidence, official docs
- [Homebrew/homebrew-bundle GitHub (archived, merged into Homebrew/brew core, April 2025)](https://github.com/Homebrew/homebrew-bundle) — confirms native-core merge, HIGH confidence
- [1Password Developer Docs: Load secrets into scripts](https://developer.1password.com/docs/cli/secrets-scripts) — `op inject` mechanics, HIGH confidence, official docs
- [mise-en-place: Comparison to asdf](https://mise.jdx.dev/dev-tools/comparison-to-asdf.html) — performance/architecture comparison, HIGH confidence, official docs
- [mise-en-place: Bootstrap](https://mise.jdx.dev/bootstrap.html) — mise's own experimental machine-bootstrap feature (`mise bootstrap`); noted but **not recommended here** since it would duplicate/compete with the already-decided Stow-based bootstrap rather than complement it — mise's role in this stack is scoped to runtime version management only, MEDIUM confidence on scope decision
- WebSearch (multiple, cross-verified): dotfiles.io secret-management guide, paulocurado.com SOPS/age/1Password writeup, samedwardes.com 1Password-in-.zshrc posts, GitHub `scripts-to-rule-them-all`-style bootstrap conventions — MEDIUM confidence, used to corroborate patterns already confirmed via official docs above, not as sole source for any claim
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
