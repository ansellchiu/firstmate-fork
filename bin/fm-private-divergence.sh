#!/usr/bin/env bash
# fm-private-divergence.sh - validate, report, and refresh the private-divergence inventory.
#
# `docs/private-divergence.json` is the single authoritative, machine-readable
# record of every INTENTIONAL firstmate-private modification to public Firstmate
# core. It exists so an upstream reconciliation can tell intentional private
# behavior apart from accidental drift and from an upstream change that has
# already converged on what we carry. `docs/private-divergence.md` is its
# concise human view and points here.
#
# This script is the one owner of that inventory's schema and of the checks that
# keep it from decaying into a hand-maintained list nothing enforces:
#   - schema validation (required fields, kebab-case unique ids, enums) - a hard
#     error, because an unparseable inventory answers nothing;
#   - stale entries - a listed path or glob matching nothing tracked;
#   - unresolved provenance - a recorded commit this repo does not contain;
#   - resurfaced upstream work - upstream changed an entry's paths after the
#     entry's recorded `upstreamReviewedAt`, so its disposition needs a fresh look;
#   - unconfirmed equivalence - an entry claims upstream now carries it while
#     upstream shows no change to its paths. Only when the drift comparison
#     actually ran: a comparison that could not run answers nothing, so it
#     never contradicts the claim;
#   - UNCOVERED DRIFT - a CONTENDED path (changed by both sides since they
#     diverged, and still differing between them) that no entry claims. That set
#     comes from git, not from the file, so a missing entry cannot stay quiet.
# Everything except a missing or schema-invalid inventory is REPORTED, never
# dropped: those findings exit 0 with `inventory: attention` so the caller
# surfaces them.
#
# Usage:
#   fm-private-divergence.sh [--root <repo>] [--inventory <path>]
#                            [--base <rev>] [--head <rev>] [--upstream <rev>]
#   fm-private-divergence.sh --refresh-reviewed <rev> [--entry <id>]... [--root <repo>]
#
# --base/--head/--upstream enable the comparisons: base is the merge base of the
# two sides, head is the private side, upstream is the public side. Omit any of
# them, or pass an unresolvable rev, and the comparison reports
# `inventory-drift: unavailable: <reason>` while every other check still runs.
# Those reasons stay distinct: a caller that withholds a revision because it has
# no trustworthy one to offer is told the comparison was not requested, a caller
# that asked for a comparison it could find no merge base for is told exactly
# that, and only a revision that really failed to resolve says so.
#
# --refresh-reviewed rewrites each entry's `upstreamReviewedAt` to that revision,
# recording that its disposition was reviewed against that upstream tip. Run it
# only in the isolated reconciliation worktree, and only for entries a human or
# agent actually re-examined; with no --entry it refreshes every entry.
#
# Output lines (stable, one fact per line):
#   inventory: ok|attention
#   inventory-entries: <n>
#   inventory-entry: <id> <status>[: <detail>]
#   inventory-drift: compared <base>..<head> vs <base>..<upstream>|unavailable: <reason>
#   inventory-contended: <path>
#   inventory-uncovered: <path>
#   inventory-uncovered-count: <n>
#
# Exit: 0 checks ran (read `inventory:`), 1 usage, missing, or invalid inventory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec python3 - "--default-root" "$DEFAULT_ROOT" "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from fnmatch import fnmatch
from pathlib import Path

ID_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
UPSTREAM_EQUIVALENT = ("none", "present", "unknown")
DISPOSITIONS = ("retain", "superseded", "needs-review")
REQUIRED = ("id", "area", "paths", "intent", "provenance", "upstreamEquivalent", "disposition")


class SchemaError(Exception):
    """One deterministic inventory schema failure."""


def git(root: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, check=False
    )
    return proc.returncode, proc.stdout.strip()


def validate(data: object, source: Path) -> list[dict]:
    if not isinstance(data, dict):
        raise SchemaError("inventory root must be an object")
    if data.get("version") != 1:
        raise SchemaError("inventory version must be 1")
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise SchemaError("inventory entries must be a list")
    seen: set[str] = set()
    for index, entry in enumerate(entries):
        where = f"entry {index}"
        if not isinstance(entry, dict):
            raise SchemaError(f"{where} must be an object")
        for field in REQUIRED:
            if field not in entry:
                raise SchemaError(f"{where} is missing required field {field}")
        entry_id = entry["id"]
        if not isinstance(entry_id, str) or not ID_RE.match(entry_id):
            raise SchemaError(f"{where} id must be kebab-case: {entry_id!r}")
        if entry_id in seen:
            raise SchemaError(f"duplicate entry id {entry_id}")
        seen.add(entry_id)
        for field in ("area", "intent"):
            value = entry[field]
            if not isinstance(value, str) or not value.strip():
                raise SchemaError(f"entry {entry_id} {field} must be a non-empty string")
        paths = entry["paths"]
        if not isinstance(paths, list) or not paths or not all(
            isinstance(p, str) and p.strip() for p in paths
        ):
            raise SchemaError(f"entry {entry_id} paths must be a non-empty list of strings")
        if entry["upstreamEquivalent"] not in UPSTREAM_EQUIVALENT:
            raise SchemaError(
                f"entry {entry_id} upstreamEquivalent must be one of {UPSTREAM_EQUIVALENT}"
            )
        if entry["disposition"] not in DISPOSITIONS:
            raise SchemaError(f"entry {entry_id} disposition must be one of {DISPOSITIONS}")
        provenance = entry["provenance"]
        if not isinstance(provenance, dict):
            raise SchemaError(f"entry {entry_id} provenance must be an object")
        commits = provenance.get("commits")
        if not isinstance(commits, list) or not commits or not all(
            isinstance(c, str) and SHA_RE.match(c) for c in commits
        ):
            raise SchemaError(
                f"entry {entry_id} provenance.commits must be a non-empty list of commit shas"
            )
        reviewed = entry.get("upstreamReviewedAt")
        if reviewed is not None and not (isinstance(reviewed, str) and SHA_RE.match(reviewed)):
            raise SchemaError(f"entry {entry_id} upstreamReviewedAt must be a commit sha")
    del source
    return entries


def load(path: Path) -> tuple[dict, list[dict]]:
    if not path.is_file():
        raise SchemaError(f"inventory not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SchemaError(f"inventory is not valid JSON: {exc}") from exc
    return data, validate(data, path)


def path_matches(pattern: str, path: str) -> bool:
    """One inventory pattern against one repo-relative path.

    A pattern is an exact path, a directory prefix, or an fnmatch glob.
    """
    pattern = pattern.rstrip("/")
    return path == pattern or path.startswith(pattern + "/") or fnmatch(path, pattern)


def claims(entry: dict, path: str) -> bool:
    return any(path_matches(pattern, path) for pattern in entry["paths"])


def changed_paths(root: Path, base: str, head: str) -> list[str]:
    code, out = git(root, "diff", "--name-only", f"{base}..{head}")
    return [line for line in out.splitlines() if line] if code == 0 else []


def resolve(root: Path, rev: str | None) -> str | None:
    if not rev:
        return None
    code, out = git(root, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}")
    return out if code == 0 and out else None


def drift_unavailable_reason(is_repo: bool, args: argparse.Namespace) -> str:
    """Why the private-vs-upstream comparison did not run.

    A revision the caller never offered is not a revision that failed to
    resolve, and a caller that deliberately withheld one - because it has no
    fresh upstream to offer - must not be told something did not resolve.
    A caller that offered both sides but no base asked for a comparison whose
    merge base could not be computed, which is neither of those two.
    """
    if not is_repo:
        return "not a git repo"
    if not args.head or not args.upstream:
        missing = [
            name for name in ("base", "head", "upstream") if not getattr(args, name)
        ]
        return f"comparison not requested: no {', '.join(missing)} revision given"
    if not args.base:
        return f"merge base could not be computed for {args.head} and {args.upstream}"
    return "base, head, or upstream revision unresolvable"


def refresh_reviewed(path: Path, data: dict, entries: list[dict], rev: str, ids: list[str]) -> int:
    wanted = set(ids)
    unknown = wanted - {e["id"] for e in entries}
    if unknown:
        print(f"inventory: invalid: no such entry: {','.join(sorted(unknown))}", file=sys.stderr)
        return 1
    touched = []
    for entry in entries:
        if wanted and entry["id"] not in wanted:
            continue
        entry["upstreamReviewedAt"] = rev
        touched.append(entry["id"])
    data["entries"] = entries
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"inventory-refreshed: {rev} {','.join(touched) if touched else 'none'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--default-root", required=True)
    parser.add_argument("--root")
    parser.add_argument("--inventory")
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--upstream")
    parser.add_argument("--refresh-reviewed")
    parser.add_argument("--entry", action="append", default=[])
    args = parser.parse_args()

    root = Path(args.root or args.default_root).resolve()
    inventory = Path(args.inventory) if args.inventory else root / "docs/private-divergence.json"

    try:
        data, entries = load(inventory)
    except SchemaError as exc:
        print(f"inventory: invalid: {exc}", file=sys.stderr)
        return 1

    is_repo = git(root, "rev-parse", "--is-inside-work-tree")[0] == 0

    if args.refresh_reviewed:
        rev = resolve(root, args.refresh_reviewed) or args.refresh_reviewed
        if not SHA_RE.match(rev):
            print(f"inventory: invalid: unresolvable revision {args.refresh_reviewed}", file=sys.stderr)
            return 1
        return refresh_reviewed(inventory, data, entries, rev, args.entry)

    base = resolve(root, args.base) if is_repo else None
    head = resolve(root, args.head) if is_repo else None
    upstream = resolve(root, args.upstream) if is_repo else None

    lines: list[str] = [f"inventory-entries: {len(entries)}"]
    attention = False

    if base and head and upstream:
        private_changed = set(changed_paths(root, base, head))
        upstream_changed = set(changed_paths(root, base, upstream))
        # A path both sides changed but that now holds identical content has
        # already converged: upstream carries what we carry, so reconciliation
        # has nothing to decide about it.
        contended = sorted(
            p
            for p in private_changed & upstream_changed
            if git(root, "diff", "--quiet", head, upstream, "--", p)[0] != 0
        )
        compared = True
        drift = f"inventory-drift: compared {args.base}..{args.head} vs {args.base}..{args.upstream}"
    else:
        contended = []
        upstream_changed = set()
        compared = False
        reason = drift_unavailable_reason(is_repo, args)
        drift = f"inventory-drift: unavailable: {reason}"

    for entry in entries:
        entry_id = entry["id"]
        statuses: list[str] = []
        if is_repo:
            stale = [p for p in entry["paths"] if not git(root, "ls-files", "--", p)[1]]
            if stale:
                statuses.append("stale-paths: " + ",".join(stale))
            missing = [
                c
                for c in entry["provenance"]["commits"]
                if git(root, "cat-file", "-e", f"{c}^{{commit}}")[0] != 0
            ]
            if missing:
                statuses.append("unresolved-provenance: " + ",".join(missing))
        if upstream:
            # Upstream work an entry has NOT been reviewed against: everything
            # since its recorded review point, or since the divergence base when
            # it has never been reviewed.
            since = resolve(root, entry.get("upstreamReviewedAt")) or base
            unreviewed = set(changed_paths(root, since, upstream)) if since else set()
            touched = sorted(p for p in unreviewed if claims(entry, p))
            if touched:
                statuses.append("upstream-unreviewed-change: " + ",".join(touched[:5]))
            if compared and entry["upstreamEquivalent"] == "present" and not any(
                claims(entry, p) for p in upstream_changed
            ):
                statuses.append("upstream-equivalent-unconfirmed")
        if entry["disposition"] == "superseded":
            statuses.append("superseded: retire this entry once upstream lands")
        elif entry["disposition"] == "needs-review":
            statuses.append("needs-review")
        if statuses:
            attention = True
            lines.extend(f"inventory-entry: {entry_id} {status}" for status in statuses)
        else:
            lines.append(f"inventory-entry: {entry_id} ok")

    lines.append(drift)
    uncovered = [p for p in contended if not any(claims(e, p) for e in entries)]
    lines.extend(f"inventory-contended: {p}" for p in contended)
    lines.extend(f"inventory-uncovered: {p}" for p in uncovered)
    lines.append(f"inventory-uncovered-count: {len(uncovered)}")
    if uncovered:
        attention = True

    print("inventory: attention" if attention else "inventory: ok")
    for line in lines:
        print(line)
    return 0


sys.exit(main())
PY
