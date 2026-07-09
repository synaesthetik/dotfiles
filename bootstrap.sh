#!/usr/bin/env bash
set -euo pipefail

# Phase 1 scope: minimal stow-only apply. Assumes stow, oh-my-zsh, and
# powerlevel10k are already installed (true on this machine). This bootstrap
# only APPLIES symlinks (idempotent) — it does NOT perform the one-time
# --adopt migration (that lives in the migration plan's own steps).
#
# Phase 3 will extend this with: Homebrew install, `brew bundle`,
# prerequisite installation, Apple-Silicon/Intel arch-awareness, and
# stowing multiple packages. None of that is in Phase 1 scope.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

stow --no-folding -t "$HOME" -d "$REPO_DIR" zsh
