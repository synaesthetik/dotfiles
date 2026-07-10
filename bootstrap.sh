#!/usr/bin/env bash
set -euo pipefail

# Stows every configured package (zsh, git, claude) into $HOME. Assumes
# stow, oh-my-zsh, and powerlevel10k are already installed (true on this
# machine). This bootstrap only APPLIES symlinks (idempotent) — it does NOT
# perform the one-time --adopt migration (that lives in each migration
# plan's own steps).
#
# The zsh/ and git/ packages track dotfile-named paths (e.g. zsh/.zshrc,
# git/.gitconfig), so their contents map directly under $HOME. The claude/
# package tracks paths as if its root were ~/.claude itself (e.g.
# claude/CLAUDE.md, not claude/.claude/CLAUDE.md), so it must target
# $HOME/.claude specifically -- targeting $HOME would create stray symlinks
# at $HOME/CLAUDE.md, $HOME/settings.json, $HOME/skills/ instead of under
# ~/.claude/ (see 02-02-SUMMARY.md).
#
# Phase 3 will extend this with: Homebrew install, `brew bundle`,
# prerequisite installation, and Apple-Silicon/Intel arch-awareness. None of
# that is in scope here.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

stow --no-folding -t "$HOME" -d "$REPO_DIR" zsh git
stow --no-folding -t "$HOME/.claude" -d "$REPO_DIR" claude
