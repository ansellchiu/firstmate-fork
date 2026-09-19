# Private divergence from public Firstmate

This home tracks two remotes: `origin` is the private repo and the only push and pull-request target, while `upstream` is the public canonical Firstmate repo and is fetch-only.
Reconciling new public work therefore has to answer one question repeatedly: is this difference an intentional private behavior we must keep, or accidental drift?

[`private-divergence.json`](private-divergence.json) is the authoritative, machine-readable answer.
This page is its human view; it deliberately restates no entry, because a second copy of the list would drift the moment only one was edited.

## What an entry records

Each entry carries the affected core area and its paths, the private intent or invariant it protects, provenance sufficient to trace the introducing change, whether upstream now carries an equivalent, and its reconciliation disposition (`retain`, `superseded`, or `needs-review`).
`bin/fm-private-divergence.sh` owns that schema and the checks that keep it honest; read its header for the exact fields, output lines, and exit codes.

## Why it cannot quietly rot

A hand-maintained list drifts as soon as nobody is forced to look at it, so the checks derive their questions from git rather than from the file:

- **Uncovered drift** is computed by comparing both sides against their divergence point: a path both sides changed, that still differs between them, and that no entry claims, is reported.
  A missing entry surfaces on the next check instead of staying quiet.
- **Stale entries** are entries whose paths no longer match anything tracked, and **unresolved provenance** is a recorded commit this repo does not contain.
- **Resurfaced upstream work** is upstream activity on an entry's paths since that entry's recorded `upstreamReviewedAt`, so a disposition decided against an older public tip is re-examined rather than assumed.

None of these are failures.
They exit 0 with `inventory: attention` so `/updatefirstmate` can surface them as reconciliation input; only a missing or schema-invalid inventory is a hard error.

## When it is consulted and refreshed

`bin/fm-upstream.sh` runs this check on every `/updatefirstmate` upstream check and again on the prepared reconciliation branch.
The [`updatefirstmate` skill](../.agents/skills/updatefirstmate/SKILL.md) owns the workflow that acts on the reported lines, including recording a review with `--refresh-reviewed`.
Refresh an entry only in the isolated reconciliation worktree, and only for entries actually re-examined; refreshing everything by reflex is how a review record stops meaning anything.
