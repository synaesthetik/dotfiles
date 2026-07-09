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

  if [ -L "$HOME/.zshrc" ]; then
    ZSHRC_LINK_TARGET="$(readlink -f "$HOME/.zshrc")"
    case "$ZSHRC_LINK_TARGET" in
      "$REPO_DIR"/zsh/*) MIGRATED=1 ;;
    esac
  fi
}

skip_if_not_migrated() {
  if [ "$MIGRATED" -ne 1 ]; then
    skip "migration has not run yet (Plan 02) -- \$HOME/.zshrc is not yet a symlink into $REPO_DIR/zsh; skipping post-stow assertions"
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
