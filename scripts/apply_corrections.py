#!/usr/bin/env python3
"""Apply transcription corrections to entries already in ~/.briefings/decisions.jsonl.

Corrections live in `corrections.json` beside the ledger, e.g. {"nova": "nomad"} when the
transcript keeps mis-hearing a product name. `briefings_mcp.ledger.append` applies them to
new entries; this script fixes the ones written before the correction was added.

Usage:
  python3 scripts/apply_corrections.py          # dry-run: list entries that would change
  python3 scripts/apply_corrections.py --apply  # rewrite the ledger with corrections applied

The --apply path writes atomically (tmp file + os.replace); unchanged lines are kept
byte-for-byte. The SQLite index rebuilds on its own because the ledger's mtime changes.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp import ledger  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="Actually rewrite the ledger (default is dry-run)")
    parser.add_argument("--path", default=str(ledger.LEDGER_PATH), help="Override ledger path (default: ~/.briefings/decisions.jsonl)")
    args = parser.parse_args()

    path = Path(args.path).expanduser()
    if not path.exists():
        print(f"Ledger not found at {path}. Nothing to do.")
        return 0

    corrections = ledger.load_corrections(path.parent)
    if not corrections:
        print(f"No corrections in {path.parent / 'corrections.json'}. Nothing to do.")
        return 0

    lines_out: list[str] = []
    changed = 0
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            stripped = raw.strip()
            if not stripped:
                lines_out.append(raw)
                continue
            entry = json.loads(stripped)
            fixed = ledger.apply_corrections(entry, corrections)
            if fixed == entry:
                lines_out.append(raw if raw.endswith("\n") else raw + "\n")
                continue
            changed += 1
            print(f"{entry.get('id', '?')[:8]} {entry.get('created_at', '')[:10]} topics {entry.get('topics')} -> {fixed.get('topics')}")
            lines_out.append(json.dumps(fixed, ensure_ascii=False, separators=(",", ":")) + "\n")

    if not changed:
        print("No entries need correcting.")
        return 0
    if not args.apply:
        print(f"Dry-run: re-run with --apply to correct {changed} entries.")
        return 0

    tmp_path = path.with_suffix(".jsonl.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(lines_out)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, path)
    print(f"Done. Corrected {changed} entries.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
