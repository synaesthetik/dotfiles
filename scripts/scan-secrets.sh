#!/usr/bin/env bash
set -euo pipefail

# Two-layer secret-scan gate (D-09). Invoked manually before a commit that
# touches zsh/.zshrc -- NOT a git hook: this repo has no .git of its own
# scope separate from the outer ~/code repo's hook infrastructure, and a
# gate that fires on every commit would be the wrong footprint for a
# one-time migration check (see 01-RESEARCH.md).

TARGET="${1:-zsh/.zshrc}"

NAMED_SECRETS='AWS_VAULT_FILE_PASSPHRASE|PGPASSWORD|SEND_SAFELY_KEY_ID|SEND_SAFELY_KEY_SECRET|CIRCLE_TOKEN'

# Reviewed-safe: name matches the generic KEY|SECRET|TOKEN|PASSWORD shape but
# the value is not a credential.
#   AWS_SESSION_TOKEN_TTL -- a duration string (e.g. "12h"), not a token.
ALLOWLIST='AWS_SESSION_TOKEN_TTL'

echo "== Layer 1: named secrets (D-04) =="
if grep -nE "^\s*export\s+(${NAMED_SECRETS})=" "$TARGET"; then
  echo "ABORT: named secret still present in $TARGET" >&2
  exit 1
fi

echo "== Layer 2: generic key/token/secret shape =="
# Matches export VAR=literal where VAR name looks credential-shaped AND the
# right-hand side is NOT a command substitution ($(...)) or a variable
# reference (${OTHER_VAR} / $OTHER_VAR) -- those are runtime-fetched (D-05),
# not stored literals, and must stay inline.
HITS=$(grep -nE '^\s*export\s+\w*(KEY|SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE)\w*=' "$TARGET" \
  | grep -vE '=\s*\$\(|="?\$\{?[A-Za-z_]' \
  | grep -vE "^[0-9]+:\s*export\s+(${ALLOWLIST})=" || true)

if [[ -n "$HITS" ]]; then
  echo "ABORT: generic secret-shaped literal(s) found in $TARGET (review before committing):" >&2
  echo "$HITS" | sed -E 's/=.*/=<redacted, review manually>/' >&2
  exit 1
fi

echo "OK: no secret-shaped literals found in $TARGET"
