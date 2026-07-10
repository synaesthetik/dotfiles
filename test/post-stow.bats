#!/usr/bin/env bats
#
# End-to-end assertion spec for the zsh package migration (walking skeleton).
# Expected RED here (Plan 01, before migration) — turns GREEN in Plan 02.
#
# Guards the whole file: if the migration hasn't run yet, every test skips
# with a clear message instead of erroring, since the assertions below are
# about POST-migration state.

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ZSHRC_LINK_TARGET=""
  MIGRATED=0
  GIT_MIGRATED=0
  CLAUDE_MIGRATED=0

  if [ -L "$HOME/.zshrc" ]; then
    ZSHRC_LINK_TARGET="$(readlink -f "$HOME/.zshrc")"
    case "$ZSHRC_LINK_TARGET" in
      "$REPO_DIR"/zsh/*) MIGRATED=1 ;;
    esac
  fi

  if [ -L "$HOME/.gitconfig" ]; then
    case "$(readlink -f "$HOME/.gitconfig")" in
      "$REPO_DIR"/git/*) GIT_MIGRATED=1 ;;
    esac
  fi

  if [ -L "$HOME/.claude/CLAUDE.md" ]; then
    case "$(readlink -f "$HOME/.claude/CLAUDE.md")" in
      "$REPO_DIR"/claude/*) CLAUDE_MIGRATED=1 ;;
    esac
  fi
}

skip_if_not_migrated() {
  if [ "$MIGRATED" -ne 1 ]; then
    skip "migration has not run yet (Plan 02) -- \$HOME/.zshrc is not yet a symlink into $REPO_DIR/zsh; skipping post-stow assertions"
  fi
}

skip_if_git_not_migrated() {
  if [ "$GIT_MIGRATED" -ne 1 ]; then
    skip "git migration has not run yet (Plan 02-01) -- \$HOME/.gitconfig is not yet a symlink into $REPO_DIR/git; skipping post-stow assertions"
  fi
}

skip_if_claude_not_migrated() {
  if [ "$CLAUDE_MIGRATED" -ne 1 ]; then
    skip "claude migration has not run yet (Plan 02-02) -- \$HOME/.claude/CLAUDE.md is not yet a symlink into $REPO_DIR/claude; skipping post-stow assertions"
  fi
}

@test "HOME/.zshrc, .zprofile, .p10k.zsh resolve into the repo's zsh/ package" {
  skip_if_not_migrated

  for f in .zshrc .zprofile .p10k.zsh; do
    [ -L "$HOME/$f" ]
    target="$(readlink -f "$HOME/$f")"
    case "$target" in
      "$REPO_DIR"/zsh/*) : ;;
      *) echo "expected $HOME/$f to resolve inside $REPO_DIR/zsh, got $target" >&2; return 1 ;;
    esac
  done
}

@test "zsh/.zshrc contains the guarded source line for ~/.zshrc.local" {
  skip_if_not_migrated

  grep -qF '[ -f ~/.zshrc.local ] && source ~/.zshrc.local' "$REPO_DIR/zsh/.zshrc"
}

@test "zsh/.zshrc contains none of the five secret variables with a literal RHS" {
  skip_if_not_migrated

  ! grep -nE '^\s*export\s+(AWS_VAULT_FILE_PASSPHRASE|PGPASSWORD|SEND_SAFELY_KEY_ID|SEND_SAFELY_KEY_SECRET|CIRCLE_TOKEN)=' "$REPO_DIR/zsh/.zshrc"
}

@test "a .DS_Store placed in zsh/ is not symlinked into HOME after a stow run" {
  skip_if_not_migrated

  touch "$REPO_DIR/zsh/.DS_Store"
  stow --no-folding -t "$HOME" -d "$REPO_DIR" zsh
  [ ! -e "$HOME/.DS_Store" ] || [ ! -L "$HOME/.DS_Store" ]
  rm -f "$REPO_DIR/zsh/.DS_Store"
}

@test "~/.zshrc.local exists and defines the five secret variables" {
  skip_if_not_migrated

  [ -f "$HOME/.zshrc.local" ]
  for var in AWS_VAULT_FILE_PASSPHRASE PGPASSWORD SEND_SAFELY_KEY_ID SEND_SAFELY_KEY_SECRET CIRCLE_TOKEN; do
    grep -qE "^\s*export\s+${var}=" "$HOME/.zshrc.local"
  done
}

@test "HOME/.gitconfig, .git-templates/hooks/*, .config/git/ignore resolve into the repo's git/ package" {
  skip_if_git_not_migrated

  [ -L "$HOME/.gitconfig" ]
  case "$(readlink -f "$HOME/.gitconfig")" in
    "$REPO_DIR"/git/*) : ;;
    *) echo "expected $HOME/.gitconfig to resolve inside $REPO_DIR/git" >&2; return 1 ;;
  esac

  for hook in pre-commit commit-msg prepare-commit-msg; do
    [ -L "$HOME/.git-templates/hooks/$hook" ]
    case "$(readlink -f "$HOME/.git-templates/hooks/$hook")" in
      "$REPO_DIR"/git/*) : ;;
      *) echo "expected $HOME/.git-templates/hooks/$hook to resolve inside $REPO_DIR/git" >&2; return 1 ;;
    esac
  done

  [ -L "$HOME/.config/git/ignore" ]
  case "$(readlink -f "$HOME/.config/git/ignore")" in
    "$REPO_DIR"/git/*) : ;;
    *) echo "expected $HOME/.config/git/ignore to resolve inside $REPO_DIR/git" >&2; return 1 ;;
  esac
}

@test "~/.claude is a real directory, not a symlink" {
  skip_if_claude_not_migrated

  [ -d "$HOME/.claude" ]
  [ ! -L "$HOME/.claude" ]
}

@test "~/.claude/CLAUDE.md and settings.json resolve into the repo's claude/ package" {
  skip_if_claude_not_migrated

  for f in CLAUDE.md settings.json; do
    [ -L "$HOME/.claude/$f" ]
    case "$(readlink -f "$HOME/.claude/$f")" in
      "$REPO_DIR"/claude/*) : ;;
      *) echo "expected $HOME/.claude/$f to resolve inside $REPO_DIR/claude" >&2; return 1 ;;
    esac
  done
}

@test "each of the 4 tracked claude skills' SKILL.md resolves into the repo's claude/ package" {
  skip_if_claude_not_migrated

  for skill in dsm-validate incremental-release my-voice stacked-release; do
    [ -L "$HOME/.claude/skills/$skill/SKILL.md" ]
    case "$(readlink -f "$HOME/.claude/skills/$skill/SKILL.md")" in
      "$REPO_DIR"/claude/skills/"$skill"/*) : ;;
      *) echo "expected $HOME/.claude/skills/$skill/SKILL.md to resolve inside $REPO_DIR/claude/skills/$skill" >&2; return 1 ;;
    esac
  done
}

@test "~/.claude runtime dirs stay real directories, not symlinks" {
  skip_if_claude_not_migrated

  for d in projects sessions shell-snapshots; do
    [ -d "$HOME/.claude/$d" ]
    [ ! -L "$HOME/.claude/$d" ]
  done
}

@test "no 160000 gitlink entries under claude/skills/ in the repo index" {
  skip_if_claude_not_migrated

  ! git -C "$REPO_DIR" ls-files -s claude/skills/ | grep -q '^160000'
}
