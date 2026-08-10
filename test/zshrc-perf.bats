#!/usr/bin/env bats
#
# Startup-cost assertions for zsh/.zshrc.
#
# These guard the specific constructs that were measured (via zprof and an
# xtrace timing pass) as the dominant cost in interactive shell startup, plus
# one dead `source` that errored on every launch. They are content assertions
# rather than wall-clock assertions on purpose: wall-clock thresholds are
# machine- and load-dependent and would flake, whereas the constructs
# themselves are what actually regress when someone re-adds them.

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ZSHRC="$REPO_DIR/zsh/.zshrc"
}

@test "zsh/.zshrc opens with the p10k instant-prompt preamble before any output-producing line" {
  # Instant prompt must be sourced before anything that can write to stdout,
  # otherwise p10k disables it and the masking effect is lost entirely.
  local first_code_line
  first_code_line="$(grep -nvE '^\s*(#.*)?$' "$ZSHRC" | head -1 | cut -d: -f1)"

  run sed -n "${first_code_line},$((first_code_line + 6))p" "$ZSHRC"
  echo "$output" | grep -qF 'p10k-instant-prompt' || {
    echo "expected the p10k instant-prompt block at the top of .zshrc, first code line was ${first_code_line}:" >&2
    echo "$output" >&2
    return 1
  }
}

@test "zsh/.zshrc does not source the removed asdf.sh shim" {
  # asdf 0.16+ (the Go rewrite) no longer ships libexec/asdf.sh; the old
  # source line printed a 'no such file or directory' error on every start.
  # The shims directory is already on PATH, so nothing is lost by dropping it.
  ! grep -qF 'asdf/libexec/asdf.sh' "$ZSHRC"
}

@test "zsh/.zshrc keeps the asdf shims directory on PATH" {
  grep -qF '.asdf/shims' "$ZSHRC"
}

@test "pyenv and nodenv init run with --no-rehash" {
  # `rehash` was measured at 114ms (pyenv) + 59ms (nodenv) per shell start.
  # Shims are rebuilt at install time, so rebuilding them on every launch is
  # pure cost.
  grep -qE 'pyenv init - --no-rehash|pyenv init --no-rehash' "$ZSHRC"
  grep -qE 'nodenv init - --no-rehash|nodenv init --no-rehash' "$ZSHRC"
}

@test "zsh/.zshrc does not fork brew --prefix at startup" {
  # Two `brew --prefix libpq` forks cost ~36ms combined for a value that is
  # deterministic per-arch and already derivable from HOMEBREW_PREFIX, which
  # .zprofile exports via `brew shellenv`.
  ! grep -qE '\$\(brew --prefix' "$ZSHRC"
}

@test "zsh/.zshrc still exports LIBPQ_INCLUDE_DIR and LIBPQ_LIB_DIR" {
  # Behaviour preservation: the vars must survive the de-forking above.
  grep -qE '^\s*export\s+LIBPQ_INCLUDE_DIR=' "$ZSHRC"
  grep -qE '^\s*export\s+LIBPQ_LIB_DIR=' "$ZSHRC"
}

@test "the vscode shell-integration path is cached rather than resolved every start" {
  # `code --locate-shell-integration-path zsh` was the single most expensive
  # fork at 123ms. It is guarded by TERM_PROGRAM already; this asserts the
  # result is memoised rather than recomputed.
  grep -qF 'vscode-shell-integration' "$ZSHRC"
}

@test "zsh/.zshrc defines every alias and function the pre-change file defined" {
  # Hard behaviour-preservation gate: refactoring for speed must never drop a
  # command. The baseline list is checked in at test/fixtures/zshrc-symbols.txt
  # and is regenerated deliberately, never automatically.
  local baseline="$REPO_DIR/test/fixtures/zshrc-symbols.txt"
  [ -f "$baseline" ]

  local missing=0 sym
  while IFS= read -r sym; do
    [ -z "$sym" ] && continue
    if ! grep -qE "^\s*(alias\s+${sym}=|(function\s+)?${sym}\s*\(\))" "$ZSHRC"; then
      echo "MISSING from .zshrc: $sym" >&2
      missing=$((missing + 1))
    fi
  done < "$baseline"

  [ "$missing" -eq 0 ]
}
