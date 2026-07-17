# Curated fresh-Mac toolset consumed by `dot install` (bin/dot -> `brew bundle
# --file="$REPO_DIR/Brewfile"`, see 03-RESEARCH.md Code Examples). Hand-picked
# from `brew leaves`/`brew list --cask`/`code --list-extensions` on Patrick's
# current machine (D-06) -- NOT a raw `brew bundle dump` (D-07). Reviewed by
# Patrick before commit (Task 2 checkpoint, 03-01-PLAN.md).
#
# No `tap "homebrew/bundle"` line: merged into Homebrew/brew core since April
# 2025, the tap step is a deprecated no-op (03-RESEARCH.md Pitfall 6).

# --- Flow-critical: the bootstrap flow itself depends on these ---
brew "stow"          # dot stow's symlink engine (bin/dot stow, D-05)
brew "git-secrets"   # required by git/.git-templates/hooks (Phase 2 IN-01) -- not in `brew leaves` yet, added explicitly
brew "bats-core"     # test harness for test/*.bats (idempotency + post-stow assertions)

# --- Shell / CLI tooling ---
brew "coreutils"     # GNU coreutils (gnu-sed pairing, zsh/.zshrc PATH block)
brew "fzf"
brew "gh"
brew "gnu-sed"
brew "jq"
brew "ripgrep"
brew "shellcheck"    # lints this repo's own bash scripts
brew "watch"
brew "wget"
brew "yj"
brew "yq"

# --- Runtimes / language tooling ---
# NOTE for review: asdf/nodenv/pyenv overlap as version managers; MISE-01
# (mise migration) is deferred to v2 per STATE.md Deferred Items, so these
# stay as today's actual runtime managers until that migration lands.
brew "asdf"
brew "bash"
brew "go"
brew "node"
brew "nodenv"
brew "pyenv"
brew "rbenv-vars"
brew "uv"
brew "yarn"

# --- Cloud / infra ---
brew "aws-vault"
brew "awscli"
brew "docker"
brew "docker-credential-helper-ecr"
brew "stern"         # Kubernetes log tailer

# --- Dev / build tools ---
brew "cmake"         # NOTE for review: native-module builds -- confirm still needed
brew "duckdb"
brew "imagemagick"
brew "libpq@16"
brew "mkcert"        # local TLS certs for dev
brew "poppler"       # PDF tooling
brew "unrtf"         # NOTE for review: RTF conversion -- niche, confirm still needed

# --- Networking / diagnostics ---
# NOTE for review: arp-scan/mtr/nmap are investigative/one-off-shaped tools --
# confirm which (if any) are worth keeping on every fresh Mac vs. installing
# ad hoc when actually needed.
brew "arp-scan"
brew "mtr"
brew "nmap"

# --- Media ---
brew "ffmpeg"

# --- Data stores ---
brew "valkey"        # Redis-compatible, local dev

cask "visual-studio-code"       # MUST precede the vscode stanza below -- provides the `code` CLI (03-RESEARCH.md Pattern 5)
cask "session-manager-plugin"   # AWS SSM session-manager, already in use today

vscode "anthropic.claude-code"
vscode "bierner.markdown-mermaid"
vscode "esbenp.prettier-vscode"
vscode "golang.go"
vscode "google.gemini-cli-vscode-ide-companion"
vscode "hashicorp.terraform"
vscode "ms-python.debugpy"
vscode "ms-python.python"
vscode "ms-python.vscode-pylance"
vscode "ms-python.vscode-python-envs"
vscode "redhat.vscode-yaml"
vscode "yzhang.markdown-all-in-one"
