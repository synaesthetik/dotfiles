# dotfiles

Patrick's personal dotfiles: shell, git, and Claude/AI config, plus the package
manifest for a fresh Mac — all applied via [GNU Stow](https://www.gnu.org/software/stow/)
symlinks so edits in this repo go live instantly.

## Quick start

```
git clone <repo-url> && cd dotfiles && ./bootstrap.sh
```

That single command:

1. Installs Homebrew if it isn't already present (this triggers the Xcode
   Command Line Tools installer on a genuinely blank Mac).
2. Resolves the Homebrew prefix arch-aware — Apple Silicon (`/opt/homebrew`) or
   Intel (`/usr/local`) — never hardcoded.
3. Hands off to `dot install`, which runs `brew bundle` against the curated
   [`Brewfile`](./Brewfile) and stows every package into place.

The whole flow is idempotent: re-running `./bootstrap.sh` on an
already-configured machine is a clean no-op (no errors, no duplicated work).

## Packages

| Package | Target | What it covers |
|---|---|---|
| `zsh/` | `$HOME` | Shell config — `.zshrc`, `.zprofile`, PATH setup, aliases/functions |
| `git/` | `$HOME` | Git config, global gitignore, commit template hooks |
| `claude/` | `$HOME/.claude` | Claude Code / AI config — `CLAUDE.md`, `settings.json`, skills |

`zsh` and `git` are dot-prefixed packages, so they map directly onto `$HOME`
(e.g. `zsh/.zshrc` → `~/.zshrc`). `claude/` is different: it tracks paths as if
its own root *were* `~/.claude` (e.g. `claude/CLAUDE.md`, not
`claude/.claude/CLAUDE.md`), so it's stowed with a separate `-t "$HOME/.claude"`
target — pointing it at `$HOME` directly would create stray symlinks at
`~/CLAUDE.md`, `~/settings.json`, `~/skills/` instead of under `~/.claude/`.
All three packages are stowed with `--no-folding`, which keeps `~/.claude` a
real directory (not a single symlink to the whole package) so Claude Code's
own runtime writes — transcripts, todo state — land on disk locally instead of
inside the git tree.

## The `dot` CLI

Once `bin/` is on your `PATH` (the `zsh` package adds it), a dependency-free
`dot` command manages the repo:

```
dot install     brew bundle + stow every package (run after ./bootstrap.sh)
dot stow [pkg]  stow a single package (zsh, git, claude) or all if omitted
dot help        show usage
```

`dot update`, `dot doctor`, and `dot uninstall` exist as **v2 stubs** — they
print `not yet implemented (v2)` and exit non-zero. They are placeholders in
the command surface, not working features, for:

- `dot update` (`SYNC-01`) — `git pull` + `brew bundle` + re-stow in one call
- `dot doctor` (`HEALTH-01`) — symlink/brew/secret health checks
- `dot uninstall` (`STOW-01`) — unstow wrapper (`stow -D`)

## Secrets — the `.local` keep-out

This is a public repo, so no secret value is ever committed. Machine-specific
secrets (API keys, tokens, passwords) live in a gitignored `~/.zshrc.local`
that never enters git in any form. `zsh/.zshrc` sources it with a guarded line:

```
[ -f ~/.zshrc.local ] && source ~/.zshrc.local
```

To reconstruct it on a new machine, copy the tracked example stub and fill in
real values:

```
cp zsh/zshrc.local.example ~/.zshrc.local
```

`.gitignore` enforces the split: `*.local` is ignored (real secrets never land
in the repo), while `*.local.example` stays tracked (it's a documentation
stub, not a secret).

## v2 roadmap

Deferred to a future milestone, reserved as stubs/comments today rather than
built:

- `SYNC-01` — `dot update`
- `HEALTH-01` — `dot doctor`
- `STOW-01` — `dot uninstall`
- `MACOS-01` — `macos.sh` system defaults
- `MISE-01` — consolidate asdf/nodenv/pyenv onto `mise`
- `CI-01` — GitHub Actions lint for the bootstrap scripts
