#!/usr/bin/env python3
"""extract-hunks.py — extract specific hunks from a unified diff.

Usage:
    extract-hunks.py <spec> [--input FILE]

Examples:
    git diff main..source -- app/config.py | extract-hunks.py 1
    extract-hunks.py 1,3 < full.diff
    extract-hunks.py 1-2,4 --input full.diff

Writes the extracted unified diff to stdout. Preserves file headers
(`diff --git`, `index`, `--- a/`, `+++ b/`) so the output can be applied
with `git apply` or `patch -p1`.

Hunks are 1-indexed per file (matching filterdiff(1) convention). For
multi-file diffs, hunk numbering restarts at each new file. The intended
caller pipes `git diff` for ONE file at a time, so single-file context is
the common case.

Why a script: stdlib-only Python. No external dependency. Deterministic.

Limitations (matched against filterdiff(1)):
  - Pure-metadata file changes (rename without content edit, mode-only,
    deletion of empty file) produce empty output — they have no hunks.
  - Binary file headers in multi-file diffs are dropped when the binary
    file isn't selected. Same as filterdiff.
  - Out-of-range hunk indices (e.g., spec=99 when only 3 hunks exist)
    silently produce empty output. Same as filterdiff. Callers wanting
    strict mode should validate hunk counts upstream.

Requires Python 3.9+ (uses PEP 585 / 604 type syntax under
`from __future__ import annotations`).
"""

from __future__ import annotations

import argparse
import sys


def parse_spec(s: str) -> set[int]:
    """Parse '1,3' or '1-3,5' into a set of 1-indexed hunk numbers.

    Rejects: negative indices, zero, non-numeric tokens, reversed ranges
    (e.g. '5-3'). Empty post-comma parts (trailing comma) are skipped.
    """
    out: set[int] = set()
    for part in s.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            if "-" in part and not part.startswith("-"):
                lo_s, hi_s = part.split("-", 1)
                lo, hi = int(lo_s), int(hi_s)
                if lo < 1:
                    raise ValueError(f"hunk index must be >= 1 (got {lo})")
                if hi < lo:
                    raise ValueError(f"reversed range (lo={lo} > hi={hi})")
                out.update(range(lo, hi + 1))
            else:
                n = int(part)
                if n < 1:
                    raise ValueError(f"hunk index must be >= 1 (got {n})")
                out.add(n)
        except ValueError as e:
            print(f"error: invalid hunk spec {part!r}: {e}", file=sys.stderr)
            sys.exit(2)
    return out


def extract(text: str, wanted: set[int]) -> str:
    """Walk the unified diff, emit only file headers + hunks at requested indices.

    State:
      - file_header: lines from `diff --git` (or `--- a/`) up to first `@@`
      - cur_hunk: lines of the current hunk (starting with `@@`)
      - hunk_count: 1-indexed position within the current file (resets per file)
      - header_emitted: whether file_header has been written for current file
    """
    lines = text.splitlines(keepends=True)
    out: list[str] = []

    file_header: list[str] = []
    cur_hunk: list[str] | None = None
    hunk_count = 0
    keep_cur_hunk = False
    header_emitted = False

    def flush_hunk():
        nonlocal cur_hunk, keep_cur_hunk
        if cur_hunk is not None and keep_cur_hunk:
            out.extend(cur_hunk)
        cur_hunk = None
        keep_cur_hunk = False

    for ln in lines:
        if ln.startswith("diff --git "):
            # New file: flush pending hunk, reset state
            flush_hunk()
            file_header = [ln]
            hunk_count = 0
            header_emitted = False
        elif ln.startswith("@@"):
            flush_hunk()
            hunk_count += 1
            cur_hunk = [ln]
            keep_cur_hunk = hunk_count in wanted
            if keep_cur_hunk and not header_emitted:
                out.extend(file_header)
                header_emitted = True
        elif cur_hunk is not None:
            cur_hunk.append(ln)
        else:
            # In file-header territory (before the first hunk of this file)
            file_header.append(ln)

    flush_hunk()
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="extract hunks from a unified diff (stdlib-only)"
    )
    ap.add_argument("spec", help="hunk indices, e.g. '1,3' or '1-3,5'")
    ap.add_argument("--input", help="file to read (default: stdin)")
    args = ap.parse_args()

    wanted = parse_spec(args.spec)
    if not wanted:
        print("error: no hunks specified (got empty spec)", file=sys.stderr)
        return 2

    if args.input:
        try:
            with open(args.input) as f:
                text = f.read()
        except OSError as e:
            print(f"error: cannot read {args.input}: {e}", file=sys.stderr)
            return 2
    else:
        text = sys.stdin.read()

    sys.stdout.write(extract(text, wanted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
