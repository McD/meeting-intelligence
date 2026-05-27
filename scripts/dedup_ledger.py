#!/usr/bin/env python3
"""One-time cleanup for duplicate commitment entries in ~/.briefings/decisions.jsonl.

Phase 1 to Phase 3 of meeting-intelligence accumulated duplicate commitment entries when
/follow-up --force re-extracted the same meeting. Phase 4's `briefings_mcp.ledger.append`
gained a dedup-on-write guard for future writes; this script cleans up the duplicates
already on disk.

A "duplicate cluster" is a set of commitment entries with the same `source_meeting` whose
`summary` strings match exactly or share a 60-character prefix. Within each cluster, the
SURVIVOR is the entry the script keeps; the rest are removed.

Survivor selection (per cluster):
  1. State preference: `done` > `dropped` > `in-flight` > `open` (more "recent" state wins).
  2. Tiebreak by earliest `created_at` (the entry that landed first wins).

Usage:
  python3 scripts/dedup_ledger.py          # dry-run: report clusters, change nothing
  python3 scripts/dedup_ledger.py --apply  # rewrite the ledger, removing non-survivors
  python3 scripts/dedup_ledger.py --help

The --apply path writes atomically (tmp file + os.replace) and invalidates the SQLite index
cache so the next MCP read rebuilds against the cleaned ledger.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from briefings_mcp import ledger  # noqa: E402

_PREFIX_LEN = 60
_STATE_RANK = {"done": 3, "dropped": 2, "in-flight": 1, "open": 0}


def cluster_key(entry: dict) -> tuple[str, str] | None:
    """Return (source_meeting, summary-prefix) for a commitment that's eligible for dedup."""
    if entry.get("type") != "commitment":
        return None
    source_meeting = entry.get("source_meeting") or ""
    summary = entry.get("summary") or ""
    if not source_meeting or not summary:
        return None
    return (source_meeting, summary[:_PREFIX_LEN])


def pick_survivor(cluster: list[dict]) -> dict:
    """Pick the entry to keep: state-rank descending, then created_at ascending."""

    def sort_key(entry: dict) -> tuple[int, str]:
        state = entry.get("state") or "open"
        # Negate state rank so higher rank sorts FIRST in ascending order.
        return (-_STATE_RANK.get(state, 0), entry.get("created_at") or "")

    return sorted(cluster, key=sort_key)[0]


def load_entries(path: Path) -> list[dict]:
    if not path.exists():
        return []
    entries: list[dict] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if not stripped:
                continue
            entries.append(json.loads(stripped))
    return entries


def build_clusters(entries: list[dict]) -> dict[tuple[str, str], list[dict]]:
    clusters: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for entry in entries:
        key = cluster_key(entry)
        if key is None:
            continue
        clusters[key].append(entry)
    return clusters


def report(clusters: dict[tuple[str, str], list[dict]]) -> tuple[int, int]:
    """Print a per-cluster summary. Return (cluster_count_with_dupes, total_to_remove)."""
    dupe_clusters = {k: v for k, v in clusters.items() if len(v) > 1}
    total_remove = sum(len(v) - 1 for v in dupe_clusters.values())

    if not dupe_clusters:
        print("No duplicate commitment clusters found.")
        return (0, 0)

    print(f"Found {len(dupe_clusters)} duplicate cluster(s); {total_remove} entries to remove.\n")
    for (source_meeting, prefix), cluster in dupe_clusters.items():
        survivor = pick_survivor(cluster)
        summary_short = (cluster[0].get("summary") or "")[:80].replace("\n", " ")
        print(f"  Cluster: {source_meeting}  /  '{summary_short}'")
        for entry in cluster:
            tag = "KEEP" if entry["id"] == survivor["id"] else "REMOVE"
            state = entry.get("state") or "open"
            created = entry.get("created_at") or "?"
            print(f"    [{tag:6}] {entry['id'][:8]} state={state:9} created_at={created}")
        print()

    return (len(dupe_clusters), total_remove)


def apply_dedup(path: Path, clusters: dict[tuple[str, str], list[dict]]) -> int:
    """Rewrite the ledger atomically, keeping only the survivor in each cluster.

    Non-commitment entries pass through untouched. Returns the count of removed entries.
    """
    survivors_by_key = {key: pick_survivor(cluster)["id"] for key, cluster in clusters.items()}

    kept_lines: list[str] = []
    removed = 0
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            stripped = raw.strip()
            if not stripped:
                kept_lines.append(raw)
                continue
            entry = json.loads(stripped)
            key = cluster_key(entry)
            if key is None or len(clusters[key]) == 1:
                # Either not a commitment, or a cluster of one — keep verbatim.
                kept_lines.append(raw if raw.endswith("\n") else raw + "\n")
                continue
            # Commitment in a dupe cluster: keep only the survivor.
            if entry["id"] == survivors_by_key[key]:
                kept_lines.append(raw if raw.endswith("\n") else raw + "\n")
            else:
                removed += 1

    tmp_path = path.with_suffix(".jsonl.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(kept_lines)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, path)
    return removed


def invalidate_index() -> None:
    """Best-effort cache invalidation so the next MCP read rebuilds against the cleaned ledger."""
    try:
        from briefings_mcp import index as index_module

        index_module.reset_cache()
    except Exception as exc:
        print(f"WARN: couldn't reset MCP index cache: {exc}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--apply", action="store_true", help="Actually rewrite the ledger (default is dry-run)")
    parser.add_argument("--path", default=str(ledger.LEDGER_PATH), help="Override ledger path (default: ~/.briefings/decisions.jsonl)")
    args = parser.parse_args()

    path = Path(args.path).expanduser()
    if not path.exists():
        print(f"Ledger not found at {path}. Nothing to do.")
        return 0

    entries = load_entries(path)
    clusters = build_clusters(entries)
    cluster_count, total_remove = report(clusters)

    if cluster_count == 0:
        return 0

    if not args.apply:
        print(f"Dry-run: re-run with --apply to remove {total_remove} duplicate entries.")
        return 0

    print(f"Applying: rewriting {path} ...")
    removed = apply_dedup(path, clusters)
    invalidate_index()
    print(f"Done. Removed {removed} entries. Ledger is now deduped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
