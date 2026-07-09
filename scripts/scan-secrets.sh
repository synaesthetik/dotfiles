#!/usr/bin/env bash
set -euo pipefail

# Two-layer secret-scan gate (D-09). Invoked manually before a commit that
# touches zsh/.zshrc -- NOT a git hook: this repo has no .git of its own
# scope separate from the outer ~/code repo's hook infrastructure, and a
# gate that fires on every commit would be the wrong footprint for a
# one-time migration check (see 01-RESEARCH.md).

TARGET="${1:-zsh/.zshrc}"

# Fail closed: an unscannable target must never report "clean" (exit 2 =
# operational error, distinct from exit 1 = secret found).
if [[ ! -f "$TARGET" ]]; then
  echo "ABORT: scan target not found or not a regular file: $TARGET" >&2
  exit 2
fi

NAMED_SECRETS='AWS_VAULT_FILE_PASSPHRASE|PGPASSWORD|SEND_SAFELY_KEY_ID|SEND_SAFELY_KEY_SECRET|CIRCLE_TOKEN'

# Reviewed-safe: name matches the generic KEY|SECRET|TOKEN|PASSWORD shape but
# the value is not a credential.
#   AWS_SESSION_TOKEN_TTL -- a duration string (e.g. "12h"), not a token.
ALLOWLIST='AWS_SESSION_TOKEN_TTL'

echo "== Layer 1: named secrets (D-04) =="
# Case-insensitive so case-variants of a known secret name are still caught.
# Capture-then-redact: never echo the literal value (it would land in scrollback).
L1=$(grep -inE "^\s*export\s+(${NAMED_SECRETS})=" "$TARGET" || true)
if [[ -n "$L1" ]]; then
  echo "ABORT: named secret still present in $TARGET" >&2
  echo "$L1" | sed -E 's/=.*/=<redacted, review manually>/' >&2
  exit 1
fi

echo "== Layer 2: generic key/token/secret shape =="
# Matches export VAR=literal where VAR name looks credential-shaped (-i:
# case-insensitive) AND the right-hand side is NOT runtime-fetched (D-05).
# Runtime-fetched RHS forms, all excluded:
#   1. a complete command substitution / single var reference to EOL
#      ($(...) , ${VAR} , $VAR ), optionally quoted -- END-ANCHORED so a
#      stored literal after a ${VAR} prefix (=${PREFIX}-realsecret) is still
#      flagged.
#   2. the opener of a MULTI-LINE command substitution: a line ending in "=$("
#      (grep is line-based; everything until the closing ) is executed, not a
#      stored literal, so this is safe to exclude).
# shellcheck disable=SC2016  # single-quoted regexes are literal by design ($ ( { are regex, not shell)
HITS=$(grep -inE '^\s*export\s+\w*(KEY|SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE)\w*=' "$TARGET" \
  | grep -vE '=\s*"?\$(\(.*\)|\{?[A-Za-z_][A-Za-z0-9_]*\}?)"?\s*$' \
  | grep -vE '=\s*"?\$\(\s*$' \
  | grep -vE "^[0-9]+:\s*export\s+(${ALLOWLIST})=" || true)

if [[ -n "$HITS" ]]; then
  echo "ABORT: generic secret-shaped literal(s) found in $TARGET (review before committing):" >&2
  echo "$HITS" | sed -E 's/=.*/=<redacted, review manually>/' >&2
  exit 1
fi

echo "OK: no secret-shaped literals found in $TARGET"
