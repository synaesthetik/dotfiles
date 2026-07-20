#!/usr/bin/env bats
#
# End-to-end assertion spec for the zsh package migration (walking skeleton).
# Expected RED here (Plan 01, before migration) — turns GREEN in Plan 02.
#
# Guards the whole file: if the migration hasn't run yet, every test skips
# with a clear message instead of erroring, since the assertions below are
# about POST-migration state.

setup_file() {
  local repo_dir
  repo_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  if command -v brew >/dev/null 2>&1 && brew bundle check --file="$repo_dir/Brewfile" >/dev/null 2>&1; then
    echo 1 > "$BATS_FILE_TMPDIR/brew_healthy"
  else
    echo 0 > "$BATS_FILE_TMPDIR/brew_healthy"
  fi
}

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ZSHRC_LINK_TARGET=""
  MIGRATED=0
  GIT_MIGRATED=0
  CLAUDE_MIGRATED=0
  BREW_HEALTHY="$(cat "$BATS_FILE_TMPDIR/brew_healthy" 2>/dev/null || echo 0)"

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

skip_if_no_dot() {
  if [ ! -e "$REPO_DIR/bin/dot" ]; then
    skip "bin/dot does not exist yet (Plan 03-02 GREEN) -- skipping dot CLI assertions"
  fi
}

skip_if_brewfile_dirty() {
  if [ "$BREW_HEALTHY" -ne 1 ]; then
    skip "Brewfile is not currently satisfied on this machine (pre-existing package drift, unrelated to dot doctor's implementation) -- skipping assertion that assumes a healthy Brewfile baseline"
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

# --- Phase 3 (Plan 03-02): dot CLI, stow idempotency, arch-awareness ---

@test "bin/dot is executable" {
  skip_if_no_dot

  [ -x "$REPO_DIR/bin/dot" ]
}

@test "dot help exits 0 and lists all five subcommands" {
  skip_if_no_dot

  run "$REPO_DIR/bin/dot" help
  [ "$status" -eq 0 ]
  for cmd in install stow update doctor uninstall; do
    echo "$output" | grep -qw "$cmd" || { echo "expected 'dot help' output to list '$cmd'" >&2; return 1; }
  done
}

@test "dot uninstall zsh --yes removes the zsh symlinks and exits 0" {
  skip_if_no_dot
  skip_if_not_migrated

  run "$REPO_DIR/bin/dot" uninstall zsh --yes
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.zshrc" ]

  "$REPO_DIR/bin/dot" stow zsh
}

@test "dot uninstall zsh --yes run again on an already-unstowed package is a clean no-op" {
  skip_if_no_dot
  skip_if_not_migrated

  run "$REPO_DIR/bin/dot" uninstall zsh --yes
  [ "$status" -eq 0 ]
  run "$REPO_DIR/bin/dot" uninstall zsh --yes
  [ "$status" -eq 0 ]

  "$REPO_DIR/bin/dot" stow zsh
}

@test "dot uninstall claude --yes is non-destructive: ~/.claude stays a real dir with runtime state and repo files intact" {
  skip_if_no_dot
  skip_if_claude_not_migrated

  run "$REPO_DIR/bin/dot" uninstall claude --yes
  [ "$status" -eq 0 ]

  [ -d "$HOME/.claude" ]
  [ ! -L "$HOME/.claude" ]
  for d in projects sessions shell-snapshots; do
    [ -d "$HOME/.claude/$d" ]
    [ ! -L "$HOME/.claude/$d" ]
  done
  [ -f "$REPO_DIR/claude/CLAUDE.md" ]

  "$REPO_DIR/bin/dot" stow claude
}

@test "dot uninstall zsh with non-TTY stdin bypasses the confirmation prompt and exits 0" {
  skip_if_no_dot
  skip_if_not_migrated

  run bash -c "printf '' | \"$REPO_DIR/bin/dot\" uninstall zsh"
  [ "$status" -eq 0 ]

  "$REPO_DIR/bin/dot" stow zsh
}

@test "dot uninstall --yes with no package argument unstows all packages" {
  skip_if_no_dot
  skip_if_not_migrated
  skip_if_claude_not_migrated

  run "$REPO_DIR/bin/dot" uninstall --yes
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.zshrc" ]
  [ ! -L "$HOME/.claude/CLAUDE.md" ]

  "$REPO_DIR/bin/dot" stow
}

@test "dot update is idempotent across two consecutive runs on a clean tree" {
  skip_if_no_dot

  if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    skip "working tree is not clean at test entry -- dot update's own dirty-tree guard would refuse; skipping idempotency assertion"
  fi

  if ! git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    skip "no git upstream/tracking branch configured on this machine -- 'git pull' cannot succeed here, unrelated to dot update's implementation"
  fi

  run "$REPO_DIR/bin/dot" update
  [ "$status" -eq 0 ]
  run "$REPO_DIR/bin/dot" update
  [ "$status" -eq 0 ]
}

@test "dot update on a dirty working tree exits 1 with a commit-or-stash message and never pulls" {
  skip_if_no_dot

  echo '# dot-update-test' >> "$REPO_DIR/Brewfile"

  run "$REPO_DIR/bin/dot" update
  git -C "$REPO_DIR" checkout -- Brewfile

  [ "$status" -eq 1 ]
  echo "$output" | grep -qiE "commit or stash" || { echo "expected a commit-or-stash message, got: $output" >&2; return 1; }
}

@test "dot doctor on a healthy post-stow machine exits 0" {
  skip_if_no_dot
  skip_if_not_migrated
  skip_if_brewfile_dirty

  run "$REPO_DIR/bin/dot" doctor
  [ "$status" -eq 0 ]
}

@test "dot doctor detects a broken managed symlink and names it" {
  skip_if_no_dot
  skip_if_not_migrated

  rm -f "$HOME/.zprofile"
  run "$REPO_DIR/bin/dot" doctor
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF ".zprofile" || { echo "expected 'dot doctor' output to mention .zprofile, got: $output" >&2; "$REPO_DIR/bin/dot" stow zsh; return 1; }

  "$REPO_DIR/bin/dot" stow zsh
}

@test "dot doctor --fix restores a broken managed symlink back into the repo" {
  skip_if_no_dot
  skip_if_not_migrated
  skip_if_brewfile_dirty

  rm -f "$HOME/.zprofile"
  run "$REPO_DIR/bin/dot" doctor --fix
  [ "$status" -eq 0 ]

  [ -L "$HOME/.zprofile" ]
  case "$(readlink -f "$HOME/.zprofile")" in
    "$REPO_DIR"/zsh/*) : ;;
    *) echo "expected $HOME/.zprofile to resolve inside $REPO_DIR/zsh after --fix, got $(readlink -f "$HOME/.zprofile")" >&2; return 1 ;;
  esac
}

@test "dot doctor --fix does not clobber a real (non-symlink) file at a stowed path" {
  skip_if_no_dot
  skip_if_not_migrated

  rm -f "$HOME/.zprofile"
  echo "not a symlink" > "$HOME/.zprofile"

  run "$REPO_DIR/bin/dot" doctor --fix
  [ ! -L "$HOME/.zprofile" ]
  grep -qF "not a symlink" "$HOME/.zprofile"

  rm -f "$HOME/.zprofile"
  "$REPO_DIR/bin/dot" stow zsh
}

@test "dot doctor reports a missing Brewfile-declared binary with a dot update hint" {
  skip_if_no_dot

  echo 'brew "dot-doctor-nonexistent-formula"' >> "$REPO_DIR/Brewfile"

  run "$REPO_DIR/bin/dot" doctor
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "dot update" || { echo "expected 'dot doctor' output to hint at 'dot update', got: $output" >&2; git -C "$REPO_DIR" checkout -- Brewfile; return 1; }

  git -C "$REPO_DIR" checkout -- Brewfile
}

@test "dot bogus (unknown subcommand) exits non-zero" {
  skip_if_no_dot

  run "$REPO_DIR/bin/dot" bogus
  [ "$status" -ne 0 ]
}

@test "dot stow zsh is idempotent across two consecutive runs and still resolves into repo/zsh" {
  skip_if_no_dot
  skip_if_not_migrated

  run "$REPO_DIR/bin/dot" stow zsh
  [ "$status" -eq 0 ]
  run "$REPO_DIR/bin/dot" stow zsh
  [ "$status" -eq 0 ]

  [ -L "$HOME/.zshrc" ]
  case "$(readlink -f "$HOME/.zshrc")" in
    "$REPO_DIR"/zsh/*) : ;;
    *) echo "expected $HOME/.zshrc to resolve inside $REPO_DIR/zsh, got $(readlink -f "$HOME/.zshrc")" >&2; return 1 ;;
  esac
}

@test "dot stow (no arg) keeps ~/.claude a real directory with CLAUDE.md symlinked into repo/claude" {
  skip_if_no_dot
  skip_if_claude_not_migrated

  run "$REPO_DIR/bin/dot" stow
  [ "$status" -eq 0 ]

  [ -d "$HOME/.claude" ]
  [ ! -L "$HOME/.claude" ]
  [ -L "$HOME/.claude/CLAUDE.md" ]
  case "$(readlink -f "$HOME/.claude/CLAUDE.md")" in
    "$REPO_DIR"/claude/*) : ;;
    *) echo "expected $HOME/.claude/CLAUDE.md to resolve inside $REPO_DIR/claude" >&2; return 1 ;;
  esac
}

@test "dot install with brew hidden from PATH dies with the missing-brew guard (does not run brew bundle)" {
  skip_if_no_dot

  run env PATH="/usr/bin:/bin" "$REPO_DIR/bin/dot" install
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "Run ./bootstrap.sh first" || { echo "expected missing-brew guard message, got: $output" >&2; return 1; }
}

@test "zsh/.zprofile resolves the brew prefix arch-aware (both existence-check branches present)" {
  grep -qF '[[ -x /opt/homebrew/bin/brew ]]' "$REPO_DIR/zsh/.zprofile"
  grep -qF '[[ -x /usr/local/bin/brew ]]' "$REPO_DIR/zsh/.zprofile"
}

@test "no new hardcoded homebrew prefix leaks outside .zprofile's arch branches / pre-existing baselines" {
  run bash -c "grep -rn '/opt/homebrew\|/usr/local' '$REPO_DIR/zsh' '$REPO_DIR/git' '$REPO_DIR/claude' | grep -v '/\.zprofile:' | grep -v '/\.zshrc:' | grep -v '/settings\.json:'"
  [ "$status" -ne 0 ]
}
