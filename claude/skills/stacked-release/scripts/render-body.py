#!/usr/bin/env python3
"""render-body.py — render a stacked-release PR body from manifest + template.

Usage: render-body.py <manifest-path> <pr-index>  (1-based)

Outputs the rendered markdown to stdout. Pipe into a file then `gh pr edit`:

    render-body.py manifest.json 3 > /tmp/body.md
    gh pr edit <num> --body @/tmp/body.md

Why a script: there are ~10 placeholders ({{this_pr_index}}, {{merged_count}},
{{blocked_count}}, {{prev_pr_branch}}, {{next_pr_branch}}, {{test_summary}},
{{last_test_ran_at}}, {{display_name}}, {{role}}, {{increments}}) and three
callout variants (active / blocked / updated) selected by status. Hand-rolling
this every `update` invocation is error-prone; one missed substitution silently
breaks reviewer experience.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

STATUS_ICONS = {
    "merged": "✓",
    "open_active": "▶",   # cursor PR (active review focus)
    "open_blocked": "⏸",  # open but waiting on upstream
    "closed": "✗",
    "planned": " ",       # rare in stacked
}


def load(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def compute_cardinality(prs: list) -> dict:
    merged = [p for p in prs if p["status"] == "merged"]
    open_ = [p for p in prs if p["status"] == "open"]
    closed = [p for p in prs if p["status"] == "closed"]
    return {
        "merged_count": len(merged),
        "open_count": len(open_),
        "closed_count": len(closed),
        "total": len(prs),
        "cursor_index": min((p["index"] for p in open_), default=None),
    }


def render_increments(prs: list, this_index: int, cursor_index: int | None) -> str:
    rows = []
    for p in prs:
        idx = p["index"]
        status = p["status"]
        if status == "merged":
            icon = STATUS_ICONS["merged"]
        elif status == "closed":
            icon = STATUS_ICONS["closed"]
        elif status == "open" and idx == cursor_index:
            icon = STATUS_ICONS["open_active"]
        elif status == "open":
            icon = STATUS_ICONS["open_blocked"]
        else:
            icon = STATUS_ICONS["planned"]

        display_name = p.get("display_name", p.get("slug", "?"))
        role = p.get("role", "")
        # The role column always starts at the same offset. For the current PR,
        # the column starts with "◀ we are here — " followed by the role.
        role_part = f"◀ we are here — {role}" if idx == this_index else role
        line = f"  {icon} {idx:2d} · {display_name:30s}  {role_part}"
        rows.append(line)
    return "\n".join(rows)


def select_callout(pr: dict, cardinality: dict) -> str:
    status = pr["status"]
    n = pr["index"]
    total = cardinality["total"]
    merged = cardinality["merged_count"]
    cursor = cardinality["cursor_index"]
    test = pr.get("last_test_result") or {}
    test_passed = test.get("passed", True)
    test_summary = test.get("summary", "tests not yet run")
    test_ran_at = test.get("ran_at", "—")
    test_icon = "✓" if test_passed else "✗"
    test_line = (
        f"> **Tests:** {test_icon} {test_summary} on this branch tip ({test_ran_at})."
    )

    revisions = pr.get("revisions", [])
    is_updated = bool(revisions)

    if status == "open" and n == cursor:
        if is_updated:
            return "\n".join([
                f"> **▶ Ready for review (updated) · increment {n} of {total} · {merged} merged before this.**",
                test_line,
                "> **What changed:** New commits pushed in response to feedback. See Revisions section below.",
                "> **What you should do:** Re-review the new commits and approve, or request additional changes.",
                f"> **After approval/merge:** Increment {n + 1} transitions to ▶ active focus.",
            ])
        return "\n".join([
            f"> **▶ Ready for review · increment {n} of {total} · {merged} merged before this · next: increment {n + 1 if n < total else '(end)'}.**",
            test_line,
            "> **What you should do:** Approve or request changes. All upstream increments are merged.",
            f"> **After approval/merge:** Increment {n + 1} transitions to ▶ active focus; its reviewers will be re-notified. Author rebases downstream PRs onto new main.",
        ])

    if status == "open":
        return "\n".join([
            f"> **⏸ Blocked · increment {n} of {total} · {merged} merged so far · waiting on increment {cursor} (currently active).**",
            test_line,
            "> **What you should do:** Read for context if useful — don't approve yet. Increment {} is currently being reviewed.".format(cursor),
            f"> **What unblocks it:** Increments {cursor} through {n - 1} merging.",
        ])

    if status == "merged":
        return f"> **✓ Merged · increment {n} of {total}.**"

    if status == "closed":
        return f"> **✗ Closed · increment {n} of {total}.**"

    return ""


def render(manifest_path: Path, pr_index: int) -> str:
    manifest = load(manifest_path)
    prs = manifest["prs"]
    pr = next(p for p in prs if p["index"] == pr_index)
    cardinality = compute_cardinality(prs)

    pr_dir = manifest_path.parent / f"pr-{pr_index:02d}-{pr['slug']}"
    body_template = (pr_dir / "body.md").read_text()

    callout = select_callout(pr, cardinality)
    increments = render_increments(prs, pr_index, cardinality["cursor_index"])

    blocked_count = sum(
        1 for p in prs if p["status"] == "open" and p["index"] != cardinality["cursor_index"]
    )

    placeholders = {
        "{{callout}}": callout,
        "{{increments}}": increments,
        "{{this_pr_index}}": str(pr_index),
        "{{total_prs}}": str(cardinality["total"]),
        "{{merged_count}}": str(cardinality["merged_count"]),
        "{{blocked_count}}": str(blocked_count),
        "{{display_name}}": pr["display_name"],
        "{{role}}": pr["role"],
        "{{ticket}}": manifest.get("ticket", ""),
    }

    out = body_template
    for k, v in placeholders.items():
        out = out.replace(k, v)
    return out


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: render-body.py <manifest-path> <pr-index>", file=sys.stderr)
        return 2

    try:
        sys.stdout.write(render(Path(sys.argv[1]), int(sys.argv[2])))
        return 0
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
