#!/usr/bin/env bash
set -euo pipefail

# Pre-Homebrew fresh-Mac entry point. Assumes nothing beyond what macOS
# ships (/bin/bash-3.2-compatible syntax only). Installs Homebrew (which
# triggers the Xcode CLT installer) if it's not already present, resolves
# the Homebrew prefix arch-aware (Apple Silicon /opt/homebrew vs Intel
# /usr/local -- never hardcoded), then hands off to `bin/dot install`, which
# runs `brew bundle` and stows every package.
#
# The two-target stow (zsh/git -> $HOME; claude -> $HOME/.claude with a
# mkdir -p guard, because the claude/ package tracks paths as if its root
# were ~/.claude itself -- targeting $HOME directly would create stray
# symlinks at $HOME/CLAUDE.md, $HOME/settings.json, $HOME/skills/ instead of
# under ~/.claude/, see 02-02-SUMMARY.md) used to live directly in this
# script; it now lives in `bin/dot stow`, reused by both `dot install` and a
# standalone `./bin/dot stow` re-stow.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v brew >/dev/null 2>&1; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
else
  echo "ERROR: brew not found after install attempt" >&2
  exit 1
fi

exec "$REPO_DIR/bin/dot" install
