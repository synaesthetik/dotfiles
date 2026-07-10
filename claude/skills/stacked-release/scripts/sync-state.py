#!/usr/bin/env python3
"""sync-state.py — poll all in-flight PRs, diff against manifest, emit transitions.

Usage: sync-state.py <manifest-path>

Outputs a JSON diff to stdout:

    {
      "transitions": [
        {"index": 1, "old_status": "open", "new_status": "merged",
         "merged_at": "...", "base_redirected": true},
        ...
      ],
      "new_cursor": 2,
      "halts": [
        {"index": 5, "reason": "closed without merging — needs user input"}
      ]
    }

Then writes the updated manifest atomically (temp + rename).

Why a script: poll-and-diff logic is fiddly; missing the base-redirect detection
or doing a non-atomic write under Ctrl+C corrupts state. Bundling it removes
the chance for an agent to derive it slightly wrong each time.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def check_gh_available() -> None:
    if subprocess.run(["which", "gh"], capture_output=True).returncode != 0:
        raise RuntimeError("gh CLI not installed (brew install gh)")


def gh_pr_view(num: int) -> dict:
    result = subprocess.run(
        ["gh", "pr", "view", str(num), "--json", "state,mergedAt,baseRefName,closedAt"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh pr view {num} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def find_next_open_pr(prs: list, after_index: int) -> dict | None:
    """Return the lowest-index PR with status='open' whose index > after_index."""
    candidates = [p for p in prs if p["status"] == "open" and p["index"] > after_index]
    return min(candidates, key=lambda p: p["index"]) if candidates else None


def atomic_write(path: Path, data: dict) -> None:
    tmp_fd, tmp_path = tempfile.mkstemp(dir=path.parent, prefix=".manifest-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def sync(manifest_path: Path) -> dict:
    check_gh_available()

    with open(manifest_path) as f:
        manifest = json.load(f)

    transitions = []
    halts = []

    for pr in manifest["prs"]:
        if pr["status"] != "open" or not pr.get("pr_number"):
            continue

        try:
            live = gh_pr_view(pr["pr_number"])
        except RuntimeError as e:
            halts.append({"index": pr["index"], "reason": str(e)})
            continue

        live_state = live["state"]
        old_status = pr["status"]

        if live_state == "MERGED":
            # When PR N merges, GitHub auto-redirects PR N+1's base to main (or
            # whatever PR N's prior base was). Detect this by checking PR N+1's
            # baseRefName, NOT PR N's own baseRefName.
            next_pr = find_next_open_pr(manifest["prs"], pr["index"])
            base_redirected = False
            new_base_for_next = None
            if next_pr:
                try:
                    next_live = gh_pr_view(next_pr["pr_number"])
                    if next_live["baseRefName"] != next_pr.get("base_branch", ""):
                        base_redirected = True
                        new_base_for_next = next_live["baseRefName"]
                        # Update next PR's base in manifest
                        for p in manifest["prs"]:
                            if p["index"] == next_pr["index"]:
                                p["base_branch"] = next_live["baseRefName"]
                                break
                except RuntimeError:
                    pass

            transition = {
                "index": pr["index"],
                "old_status": old_status,
                "new_status": "merged",
                "merged_at": live.get("mergedAt"),
                "downstream_base_redirected": base_redirected,
                "downstream_pr_index": next_pr["index"] if next_pr else None,
                "downstream_new_base": new_base_for_next,
            }
            transitions.append(transition)
            pr["status"] = "merged"
            pr["merged_at"] = live.get("mergedAt")
        elif live_state == "CLOSED":
            transitions.append({
                "index": pr["index"],
                "old_status": old_status,
                "new_status": "closed",
                "closed_at": live.get("closedAt"),
            })
            pr["status"] = "closed"
            pr["closed_at"] = live.get("closedAt")
            halts.append({
                "index": pr["index"],
                "reason": "closed without merging — needs user input (replan or abort)",
            })
        elif live["baseRefName"] != pr.get("base_branch", ""):
            transitions.append({
                "index": pr["index"],
                "old_status": old_status,
                "new_status": "open",
                "base_redirected": True,
                "old_base": pr.get("base_branch"),
                "new_base": live["baseRefName"],
            })
            pr["base_branch"] = live["baseRefName"]

    open_indices = [p["index"] for p in manifest["prs"] if p["status"] == "open"]
    new_cursor = min(open_indices) if open_indices else None
    manifest["cursor"] = new_cursor

    atomic_write(manifest_path, manifest)

    return {
        "transitions": transitions,
        "new_cursor": new_cursor,
        "halts": halts,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: sync-state.py <manifest-path>", file=sys.stderr)
        return 2

    try:
        result = sync(Path(sys.argv[1]))
        print(json.dumps(result, indent=2))
        return 0
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
