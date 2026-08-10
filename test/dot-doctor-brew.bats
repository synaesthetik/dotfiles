#!/usr/bin/env bats
#
# `dot doctor` must distinguish two failure modes that `brew bundle check`
# reports through the same non-zero exit status:
#
#   1. Packages are genuinely missing        -> actionable, `dot update` fixes it
#   2. The check could not be evaluated at all -> `dot update` will NOT fix it
#
# Mode 2 is not hypothetical: as of this commit the upstream libtiff and webp
# formulae declare each other as dependencies, so brew's dependency sorter
# aborts before evaluating a single entry and then lists *every* formula as
# "needs to be installed or updated" -- including ones that are demonstrably
# installed and on PATH. Reporting that as "missing packages" sends you to
# `dot update`, which cannot help, and buries any real drift in the noise.
#
# Both paths are driven through a stubbed `brew` so the assertions do not
# depend on the health of the machine's actual Homebrew installation.

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
}

# Emits the exact shape of the upstream circular-dependency abort.
write_cyclic_brew_stub() {
  cat > "$STUB_DIR/brew" << 'STUB'
#!/usr/bin/env bash
cat >&2 << 'MSG'
Warning: Formulae dependency graph sorting found a circular dependency:
  libtiff, webp
This is usually caused by stale dependency data in installed keg tabs.
MSG
cat << 'MSG'
brew bundle can't satisfy your Brewfile's dependencies.
→ Formula fzf needs to be installed or updated.
→ Formula gh needs to be installed or updated.
Satisfy missing dependencies with `brew bundle install`.
MSG
exit 1
STUB
  chmod +x "$STUB_DIR/brew"
}

# Emits an ordinary "these specific things are missing" failure.
write_missing_brew_stub() {
  cat > "$STUB_DIR/brew" << 'STUB'
#!/usr/bin/env bash
cat << 'MSG'
→ Formula dot-doctor-nonexistent-formula needs to be installed or updated.
Satisfy missing dependencies with `brew bundle install`.
MSG
exit 1
STUB
  chmod +x "$STUB_DIR/brew"
}

@test "dot doctor flags an unevaluable Brewfile check as such, not as missing packages" {
  write_cyclic_brew_stub

  run env PATH="$STUB_DIR:$PATH" "$REPO_DIR/bin/dot" doctor
  [ "$status" -ne 0 ]

  echo "$output" | grep -qiE 'could not (be )?evaluat|unable to evaluate' || {
    echo "expected an explicit 'could not evaluate' diagnosis, got: $output" >&2
    return 1
  }
}

@test "dot doctor does not send you to 'dot update' when the check could not be evaluated" {
  write_cyclic_brew_stub

  run env PATH="$STUB_DIR:$PATH" "$REPO_DIR/bin/dot" doctor

  # `dot update` runs `brew bundle`, which hits the identical sorter abort --
  # recommending it here is a dead end.
  ! echo "$output" | grep -qF "run 'dot update'"
}

@test "dot doctor surfaces the circular-dependency detail so the cause is visible" {
  write_cyclic_brew_stub

  run env PATH="$STUB_DIR:$PATH" "$REPO_DIR/bin/dot" doctor
  echo "$output" | grep -qF 'circular dependency' || {
    echo "expected the underlying brew output to be surfaced, got: $output" >&2
    return 1
  }
}

@test "dot doctor still reports genuinely missing packages with a dot update hint" {
  write_missing_brew_stub

  run env PATH="$STUB_DIR:$PATH" "$REPO_DIR/bin/dot" doctor
  [ "$status" -ne 0 ]

  echo "$output" | grep -qF "dot update" || {
    echo "expected a 'dot update' hint for genuinely missing packages, got: $output" >&2
    return 1
  }
  echo "$output" | grep -qF 'dot-doctor-nonexistent-formula' || {
    echo "expected the missing formula to be named, got: $output" >&2
    return 1
  }
}
