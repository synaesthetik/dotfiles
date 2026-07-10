#!/usr/bin/env bash
# restack.sh — cascading rebase of downstream stack PRs after a mid-stack edit.
#
# Usage: restack.sh <manifest-path> <from-pr-index>
#
# For each PR M from <from-pr-index>+1 to total, with status="open":
#   1. checkout PR M's branch
#   2. git rebase --onto <new_base_sha> <old_base_sha> (replays just M's commits onto new base)
#   3. run manifest.test_command — halt if fail
#   4. git push --force-with-lease --force-if-includes
#   5. update manifest with new tip + last_test_result + last_restacked_at
#
# The `git rebase --onto` form is the only correct incantation for stacked PRs.
# Plain `git rebase <new-base>` rewinds beyond the wanted commits and picks up
# unrelated changes. --onto says "take just my commits and replay them on top
# of new-base, treating old-base as the starting point."
#
# Force-push uses both --force-with-lease (refuses if remote moved since fetch)
# AND --force-if-includes (git 2.30+; refuses if local lacks remote commits).
# Together they prevent overwriting a teammate's push under any condition.

set -euo pipefail

MANIFEST_PATH="${1:?manifest path required}"
FROM_PR_INDEX="${2:?from-pr-index required (>=1)}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed" >&2
  exit 2
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "error: manifest not found: $MANIFEST_PATH" >&2
  exit 2
fi

if ! [[ "$FROM_PR_INDEX" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: from-pr-index must be a positive integer (got: $FROM_PR_INDEX)" >&2
  exit 2
fi

# Read manifest fields we need
PRS=$(jq -c '.prs' "$MANIFEST_PATH")
TOTAL=$(jq '.prs | length' "$MANIFEST_PATH")
TEST_COMMAND=$(jq -r '.test_command' "$MANIFEST_PATH")
REPO_PATH=$(jq -r '.repo_path' "$MANIFEST_PATH")
MAIN_BRANCH=$(jq -r '.main_branch // "main"' "$MANIFEST_PATH")

cd "$REPO_PATH"

echo "[restack] Starting cascade from PR $((FROM_PR_INDEX + 1)) of $TOTAL"

# Iterate downstream PRs in order
for ((M = FROM_PR_INDEX + 1; M <= TOTAL; M++)); do
  PR_INDEX=$((M - 1))  # 0-based array index
  PR=$(echo "$PRS" | jq -c ".[$PR_INDEX]")
  STATUS=$(echo "$PR" | jq -r '.status')

  if [[ "$STATUS" != "open" ]]; then
    echo "[restack] PR $M status=$STATUS — skipping"
    continue
  fi

  BRANCH=$(echo "$PR" | jq -r '.branch')

  # Find the nearest non-merged predecessor. If all upstream are merged/closed,
  # fall back to main (because GitHub auto-redirects merged-PR successors' base).
  NEW_BASE_REF="$MAIN_BRANCH"
  for ((P = PR_INDEX - 1; P >= 0; P--)); do
    CAND=$(echo "$PRS" | jq -c ".[$P]")
    CAND_STATUS=$(echo "$CAND" | jq -r '.status')
    if [[ "$CAND_STATUS" == "open" ]]; then
      NEW_BASE_REF=$(echo "$CAND" | jq -r '.branch')
      break
    fi
  done

  # Old base = the SHA the PR's commits were originally based on (recorded in manifest).
  # New base = the current tip of the nearest open predecessor (or main).
  OLD_BASE=$(echo "$PR" | jq -r '.base_branch_sha // empty')
  if [[ -z "$OLD_BASE" ]]; then
    echo "error: PR $M has no recorded base_branch_sha — cannot determine rebase --onto args" >&2
    echo "       The manifest must record base_branch_sha at PR-creation time." >&2
    exit 3
  fi

  if [[ "$NEW_BASE_REF" == "$MAIN_BRANCH" ]]; then
    git fetch origin "$MAIN_BRANCH" --quiet
    NEW_BASE=$(git rev-parse "origin/$MAIN_BRANCH")
  else
    git fetch origin "$NEW_BASE_REF" --quiet
    NEW_BASE=$(git rev-parse "$NEW_BASE_REF")
  fi

  echo "[restack] PR $M ($BRANCH): rebasing --onto $NEW_BASE (was $OLD_BASE)"

  git fetch origin "$BRANCH" --quiet
  git checkout "$BRANCH"

  # The key invocation. --onto <new_base> <old_base> <branch> means:
  # "take commits between <old_base> and <branch>, replay them starting at <new_base>"
  if ! git rebase --onto "$NEW_BASE" "$OLD_BASE"; then
    echo "[restack] HALT: rebase conflict on PR $M ($BRANCH)" >&2
    echo "         Resolve the conflict, then:  git rebase --continue" >&2
    echo "         Re-invoke restack.sh once resolved to pick up where we left off." >&2
    exit 4
  fi

  echo "[restack] running test command: $TEST_COMMAND"
  if ! eval "$TEST_COMMAND"; then
    echo "[restack] HALT: tests failed on PR $M after rebase" >&2
    echo "         Branch $BRANCH is rebased but unpushed. Fix tests, then re-invoke." >&2
    exit 5
  fi

  echo "[restack] tests green — pushing $BRANCH with lease"
  if ! git push --force-with-lease --force-if-includes origin "$BRANCH"; then
    echo "[restack] HALT: force-push lease failure on $BRANCH" >&2
    echo "         Someone may have pushed since our fetch. Investigate before retrying." >&2
    echo "         Never strip --force-with-lease as a workaround." >&2
    exit 6
  fi

  NEW_TIP=$(git rev-parse "$BRANCH")
  echo "[restack] PR $M done. New tip: $NEW_TIP"

  # Record success in manifest (atomic write via tmp+rename)
  TMP=$(mktemp)
  jq --argjson idx "$PR_INDEX" --arg tip "$NEW_TIP" --arg base "$NEW_BASE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.prs[$idx].branch_tip_sha = $tip
     | .prs[$idx].base_branch_sha = $base
     | .prs[$idx].last_restacked_at = $ts
     | .prs[$idx].last_test_result = {passed: true, summary: "rebased + tests green", ran_at: $ts}' \
    "$MANIFEST_PATH" > "$TMP"
  mv "$TMP" "$MANIFEST_PATH"
done

echo "[restack] cascade complete (PRs $((FROM_PR_INDEX + 1))..$TOTAL)"
echo "[restack] run /stacked-release update to refresh PR body callouts"
