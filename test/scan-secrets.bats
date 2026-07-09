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
