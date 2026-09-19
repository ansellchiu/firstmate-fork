#!/usr/bin/env bash
# push-route-b.sh - perform the Route B public rewrite of ansellchiu/firstmate-fork.
#
# This is the ONLY step of the migration that touches the public repository, and
# it is deliberately a separate, reviewable artifact rather than something the
# reconciliation worker could run by accident: the default mode is --dry-run,
# push mode requires BOTH an explicit --push and a typed confirmation phrase,
# and the script refuses outright unless every precondition below holds.
#
# Route B's mechanism is owned by data/fm-fork-migration-scout-s1/report.md
# section 3.1; RECONCILIATION-INVENTORY.md records what this branch carries.
#
# What push mode does, exactly one ref change:
#
#   ansellchiu/firstmate-fork  refs/heads/main  <published tip> -> <this branch>
#
# It force-pushes with --force-with-lease against the exact remote SHA read in
# the same run, so a public main that moved since that read is refused rather
# than overwritten. Nothing else is pushed: no tags, no other branches, and no
# other remote.
#
# Usage:
#   ./push-route-b.sh                 # dry run (default): print every ref it would change
#   ./push-route-b.sh --dry-run       # same, explicit
#   ./push-route-b.sh --push          # perform the rewrite; prompts for the confirmation phrase
#   ./push-route-b.sh --push --yes    # non-interactive; requires FM_ROUTE_B_CONFIRM to carry the phrase
#
# Options:
#   --remote-url <url>   public target (default: https://github.com/ansellchiu/firstmate-fork.git)
#   --branch <name>      local branch to publish (default: the current branch)
#   --upstream <ref>     upstream tip the seed must be rooted on (default: upstream/main)
#
# Preconditions, all enforced in BOTH modes; any failure stops before the push:
#   1. The working tree is clean.
#   2. The branch to publish exists and resolves.
#   3. The upstream ref resolves and is a real ancestor of the branch, so the
#      published history is upstream's own history and not a stamped tree.
#   4. Every file upstream added since the divergence base is present in the
#      branch - the exact check the published fork fails (10 of 73).
#   5. The public remote is readable and its current main is recorded, so the
#      lease can be taken against a value this run actually observed.
#
# Exit: 0 dry run completed or push succeeded, 1 a precondition failed or the
# push was refused, 2 usage.
set -eu

REMOTE_URL=https://github.com/ansellchiu/firstmate-fork.git
BRANCH=
UPSTREAM_REF=upstream/main
MODE=dry-run
ASSUME_YES=0
CONFIRM_PHRASE='rewrite firstmate-fork main'

die() { printf 'push-route-b: %s\n' "$1" >&2; exit "${2:-1}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --push) MODE=push ;;
    --yes) ASSUME_YES=1 ;;
    --remote-url) [ "$#" -ge 2 ] || die "--remote-url needs a value" 2; REMOTE_URL=$2; shift ;;
    --remote-url=*) REMOTE_URL=${1#--remote-url=} ;;
    --branch) [ "$#" -ge 2 ] || die "--branch needs a value" 2; BRANCH=$2; shift ;;
    --branch=*) BRANCH=${1#--branch=} ;;
    --upstream) [ "$#" -ge 2 ] || die "--upstream needs a value" 2; UPSTREAM_REF=$2; shift ;;
    --upstream=*) UPSTREAM_REF=${1#--upstream=} ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
  shift
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not a git repository"
cd "$ROOT"

# 1. clean tree
[ -z "$(git status --porcelain)" ] \
  || die "working tree is not clean; commit or set aside local changes first"

# 2. branch resolves
[ -n "$BRANCH" ] || BRANCH=$(git symbolic-ref --quiet --short HEAD) \
  || die "detached HEAD and no --branch given"
BRANCH_SHA=$(git rev-parse --verify "refs/heads/$BRANCH^{commit}" 2>/dev/null) \
  || die "no such local branch: $BRANCH"

# 3. upstream ancestry
UPSTREAM_SHA=$(git rev-parse --verify "$UPSTREAM_REF^{commit}" 2>/dev/null) \
  || die "cannot resolve upstream ref: $UPSTREAM_REF (fetch it first)"
git merge-base --is-ancestor "$UPSTREAM_SHA" "$BRANCH_SHA" \
  || die "$UPSTREAM_REF ($UPSTREAM_SHA) is not an ancestor of $BRANCH; this is not a Route B seed"
MERGE_BASE=$(git merge-base "$BRANCH_SHA" "$UPSTREAM_SHA")
[ "$MERGE_BASE" = "$UPSTREAM_SHA" ] \
  || die "merge base with $UPSTREAM_REF is $MERGE_BASE, not the upstream tip $UPSTREAM_SHA"

# 4. every upstream-added file is present (the check the published fork fails)
ORIGIN_SHA=$(git rev-parse --verify origin/main^{commit} 2>/dev/null || true)
UPSTREAM_ADDS_MISSING=0
UPSTREAM_ADDS_TOTAL=0
if [ -n "$ORIGIN_SHA" ]; then
  DIVERGENCE_BASE=$(git merge-base "$ORIGIN_SHA" "$UPSTREAM_SHA")
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    UPSTREAM_ADDS_TOTAL=$((UPSTREAM_ADDS_TOTAL + 1))
    git cat-file -e "$BRANCH_SHA:$path" 2>/dev/null || {
      printf 'push-route-b: upstream file missing from %s: %s\n' "$BRANCH" "$path" >&2
      UPSTREAM_ADDS_MISSING=$((UPSTREAM_ADDS_MISSING + 1))
    }
  done <<EOF
$(git diff --name-only --diff-filter=A "$DIVERGENCE_BASE" "$UPSTREAM_SHA")
EOF
  [ "$UPSTREAM_ADDS_MISSING" -eq 0 ] \
    || die "$UPSTREAM_ADDS_MISSING upstream file(s) missing; refusing to publish a tree that drops upstream work"
else
  printf 'push-route-b: note: origin/main is unavailable, so the upstream-added-file census was skipped\n' >&2
fi

# 5. read the public remote's current main, and take the lease against exactly that
REMOTE_LINE=$(git ls-remote "$REMOTE_URL" refs/heads/main 2>/dev/null) \
  || die "cannot read $REMOTE_URL (network or credentials)"
REMOTE_SHA=${REMOTE_LINE%%[!0-9a-f]*}
[ -n "$REMOTE_SHA" ] || REMOTE_SHA=

cat <<EOF

Route B public rewrite plan
---------------------------
  public remote   $REMOTE_URL
  local branch    $BRANCH
  local tip       $BRANCH_SHA  $(git log -1 --format=%s "$BRANCH_SHA")
  seed / upstream $UPSTREAM_SHA  $(git log -1 --format=%s "$UPSTREAM_SHA")
  reconciliations $(git rev-list --count "$UPSTREAM_SHA..$BRANCH_SHA") commit(s) on top of the seed
  upstream files  ${UPSTREAM_ADDS_TOTAL:-0} added since the divergence base, all present

Refs this run would change (exactly one):

  refs/heads/main   ${REMOTE_SHA:-(absent)} -> $BRANCH_SHA   FORCED (--force-with-lease)

Refs this run would NOT touch: every other branch, every tag, every other remote.
EOF

if [ "$MODE" = dry-run ]; then
  printf '\nDry run only. Nothing was pushed. Re-run with --push to perform the rewrite.\n'
  exit 0
fi

printf '\nThis REWRITES the public branch above. It is not reversible from here.\n'
if [ "$ASSUME_YES" -eq 1 ]; then
  [ "${FM_ROUTE_B_CONFIRM:-}" = "$CONFIRM_PHRASE" ] \
    || die "--yes requires FM_ROUTE_B_CONFIRM to be exactly: $CONFIRM_PHRASE"
else
  printf 'Type the phrase to continue (%s): ' "$CONFIRM_PHRASE"
  IFS= read -r typed || typed=
  [ "$typed" = "$CONFIRM_PHRASE" ] || die "confirmation phrase did not match; nothing was pushed"
fi

if [ -n "$REMOTE_SHA" ]; then
  git push --force-with-lease="refs/heads/main:$REMOTE_SHA" "$REMOTE_URL" "$BRANCH_SHA:refs/heads/main"
else
  git push "$REMOTE_URL" "$BRANCH_SHA:refs/heads/main"
fi

printf '\npush-route-b: refs/heads/main on %s is now %s\n' "$REMOTE_URL" "$BRANCH_SHA"
