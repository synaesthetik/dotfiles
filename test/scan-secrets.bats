#!/usr/bin/env bats
#
# TDD spec for the two-layer secret-scan gate. Written before
# scripts/scan-secrets.sh exists (RED first, per D-09/D-04/D-05).

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCAN="$REPO_DIR/scripts/scan-secrets.sh"
  SAMPLE="$REPO_DIR/test/fixtures/zshrc.sample"
  SANITIZED="$REPO_DIR/test/fixtures/zshrc.sanitized"
}

@test "scan-secrets.sh exits 1 against the unsanitized fixture (five named secrets present)" {
  run "$SCAN" "$SAMPLE"
  [ "$status" -eq 1 ]
}

@test "scan-secrets.sh exits 0 against the sanitized fixture (no stored literal remains)" {
  run "$SCAN" "$SANITIZED"
  [ "$status" -eq 0 ]
}

@test "scan-secrets.sh does not flag CODEARTIFACT_TOKEN command substitution on the sanitized fixture" {
  run "$SCAN" "$SANITIZED"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'CODEARTIFACT_TOKEN=\$('
}

@test "scan-secrets.sh does not flag the POETRY_HTTP_BASIC_CODEARTIFACT_PASSWORD variable reference on the sanitized fixture" {
  run "$SCAN" "$SANITIZED"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'POETRY_HTTP_BASIC_CODEARTIFACT_PASSWORD='
}

@test "scan-secrets.sh does not flag AWS_SESSION_TOKEN_TTL (reviewed-safe allowlist) on the sanitized fixture" {
  run "$SCAN" "$SANITIZED"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'AWS_SESSION_TOKEN_TTL'
}

@test "scan-secrets.sh's abort message names the offending file" {
  run "$SCAN" "$SAMPLE"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "$SAMPLE"
}

# --- Hardening regression tests (Phase 1 code review, CR-1..CR-4) ---

@test "CR-1: a nonexistent target file fails (does not report clean)" {
  run "$SCAN" "$BATS_TEST_TMPDIR/does-not-exist.zsh"
  [ "$status" -ne 0 ]
}

@test "CR-2: a literal secret after a \${VAR} prefix is flagged (exclusion is end-anchored)" {
  printf 'export API_KEY=${PREFIX}-actual-literal-secret-data\n' > "$BATS_TEST_TMPDIR/c2.zsh"
  run "$SCAN" "$BATS_TEST_TMPDIR/c2.zsh"
  [ "$status" -eq 1 ]
}

@test "CR-3: lowercase secret-shaped variable names are flagged (case-insensitive)" {
  printf 'export api_key=realsecretvalue123\nexport DB_password=hunter2\n' > "$BATS_TEST_TMPDIR/c3.zsh"
  run "$SCAN" "$BATS_TEST_TMPDIR/c3.zsh"
  [ "$status" -eq 1 ]
}

@test "CR-4: a whole-RHS runtime reference with quotes still passes (no over-flag)" {
  printf 'export SOME_TOKEN="${OTHER_VAR}"\nexport OTHER_TOKEN=$(echo hi)\n' > "$BATS_TEST_TMPDIR/c4ok.zsh"
  run "$SCAN" "$BATS_TEST_TMPDIR/c4ok.zsh"
  [ "$status" -eq 0 ]
}

@test "CR-4: Layer 1 does not print the raw secret value on a named-secret hit" {
  printf 'export PGPASSWORD=SUPERSECRETVALUE42\n' > "$BATS_TEST_TMPDIR/c4leak.zsh"
  run "$SCAN" "$BATS_TEST_TMPDIR/c4leak.zsh"
  [ "$status" -eq 1 ]
  ! echo "$output" | grep -q 'SUPERSECRETVALUE42'
}

@test "CR-2: a multi-line command substitution opener (=\$( at EOL) is not flagged" {
  printf 'export API_TOKEN=$(\n  echo hi \\\n  )\n' > "$BATS_TEST_TMPDIR/c2ml.zsh"
  run "$SCAN" "$BATS_TEST_TMPDIR/c2ml.zsh"
  [ "$status" -eq 0 ]
}
