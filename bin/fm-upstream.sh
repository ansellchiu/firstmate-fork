#!/usr/bin/env bash
# fm-upstream.sh - the one owner of the public-upstream check and of the safe
# reconciliation that precedes a private-origin self-update.
#
# Firstmate here has two remotes with different jobs:
#   origin   - the PRIVATE repo. The only push and pull-request target.
#   upstream - the PUBLIC canonical Firstmate repo. FETCH ONLY, always.
# This script never pushes, never opens a pull request, and never runs a git
# command against `upstream` other than `fetch`. `bin/fm-update.sh` still owns
# the guarded fast-forward of this home and its secondmates from origin; this
# script is what runs BEFORE it, so "origin is current" is never mistaken for
# "we have everything public upstream published".
#
# Commands:
#   check                 bounded upstream fetch, then classify (default command)
#   reconcile             prepare an isolated reconciliation branch, never touching
#                         the active checkout
#   cleanup               remove a reconciliation worktree, keeping its branch
#
# check classifies into exactly three answers, reported separately:
#   current   - upstream has no commit origin lacks
#   contained - every upstream commit origin lacks is already patch-equivalent
#               to something origin carries (`git cherry`), so replaying them
#               would duplicate work
#   diverged  - at least one genuinely new upstream commit; reconciliation is owed
# A comparison that could not run at all is not a fourth answer: it degrades.
#
# reconcile builds the merge in a fresh worktree on a NEW branch based on
# origin/<default>, so every private commit is preserved by construction and the
# running main branch is never moved by unmerged work. A conflict is a stop:
# the merge is aborted, the conflicting paths are reported for a captain
# decision, and the scratch branch and worktree are discarded - or, when that
# teardown cannot complete, reported as kept with the recovery it needs.
# A merge git refuses outright never started, so no semantic judgement is owed
# for it: it is reported as `reconcile: failed:` carrying git's own reason,
# under the same teardown rules. Nothing is ever forced, stashed, reset, or
# rewritten.
#
# The prepared branch then ships through Firstmate's ordinary no-mistakes
# delivery path to a pull request against origin. After that pull request lands,
# `bin/fm-update.sh` performs the ordinary guarded fast-forward.
# `.agents/skills/updatefirstmate/SKILL.md` owns that end-to-end workflow.
#
# bin/fm-private-divergence.sh owns the private-divergence inventory; check and
# reconcile both run it and pass its lines through, so an intentional private
# modification is distinguished from accidental drift instead of being replayed
# or dropped.
#
# Usage:
#   fm-upstream.sh [check]
#   fm-upstream.sh reconcile [--branch <name>] [--worktree <dir>]
#   fm-upstream.sh cleanup --worktree <dir>
#
# Environment:
#   FM_UPSTREAM_REMOTE        remote name to fetch (default: upstream)
#   FM_UPSTREAM_FETCH_TIMEOUT seconds bounding the fetch (default: 60)
#   FM_UPSTREAM_COMMIT_LIMIT  upstream commits listed by check (default: 20)
#
# Public upstream being UNAVAILABLE is not the same as the setup being UNSAFE,
# and the two are answered differently. ANY reason the public comparison cannot
# complete - no `upstream` remote at all, a bounded fetch that failed, or a
# fetch that succeeded onto a public repo with no `<remote>/<default>` ref -
# degrades down ONE path with one meaning: `upstream-check: degraded: <reason>`,
# `upstream-status: not-compared`, `reconcile-required: not-applicable`, and
# exit 0, so the ordinary guarded origin-only fast-forward still runs and the
# public comparison is never claimed to have happened. The concrete reason stays
# on the record. Unsafe - a missing origin, an upstream that is really origin,
# an upstream whose PUSH url would let a push reach the public repo, or an
# unusable inventory - still refuses.
#
# Exit: 0 the command completed (read `upstream-status:`); 1 usage;
#       2 wrong remote topology or a refusal;
#       4 reconciliation needs a semantic judgement (conflict) - stop and escalate;
#       5 the private-divergence inventory is missing or schema-invalid, so the
#         classification that separates intentional divergence from drift is
#         unavailable - a hard refusal;
#       6 a reconciliation invariant did not hold, or a merge git refused
#         outright never started.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
UPSTREAM_REMOTE="${FM_UPSTREAM_REMOTE:-upstream}"
FETCH_TIMEOUT="${FM_UPSTREAM_FETCH_TIMEOUT:-60}"
COMMIT_LIMIT="${FM_UPSTREAM_COMMIT_LIMIT:-20}"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: fm-upstream.sh [check]
       fm-upstream.sh reconcile [--branch <name>] [--worktree <dir>]
       fm-upstream.sh cleanup --worktree <dir>
USAGE
}

git_root() { git -C "$FM_ROOT" "$@"; }

remote_url() { git_root remote get-url "$1" 2>/dev/null || true; }

remote_push_url() { git_root remote get-url --push "$1" 2>/dev/null || true; }

# The first line of a captured command output, whitespace squeezed, or the given
# fallback when there is nothing to report. A reported reason is never blank.
first_line() {
  local line
  line=$(printf '%s\n' "$1" | sed -n '1p' | tr -s '[:space:]' ' ')
  line=${line# }
  line=${line% }
  printf '%s\n' "${line:-$2}"
}

# Report the remote layout this repo must have for any upstream work to be safe.
# A wrong layout is never worked around: an upstream that is the same repo as
# origin, or one that can still be pushed to, would break the fetch-only rule,
# so both refuse. A remote that is simply absent is different in kind - nothing
# unsafe is configured, there is just nothing public to compare against - so it
# degrades instead, and is still never treated as "nothing new".
DEFAULT_BRANCH=""
ORIGIN_URL=""
UPSTREAM_URL=""
UPSTREAM_PUSH_URL=""
TOPOLOGY_DEGRADED=10
check_topology() {
  ORIGIN_URL=$(remote_url origin)
  UPSTREAM_URL=$(remote_url "$UPSTREAM_REMOTE")
  echo "origin-remote: ${ORIGIN_URL:-none}"
  echo "upstream-remote: ${UPSTREAM_URL:-none}"
  if ! git_root rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "upstream-topology: not-a-git-repo"
    return 1
  fi
  if [ -z "$ORIGIN_URL" ]; then
    echo "upstream-topology: missing-origin-remote"
    return 1
  fi
  DEFAULT_BRANCH=$(fm_default_branch "$FM_ROOT") || {
    echo "upstream-topology: no-default-branch"
    return 1
  }
  echo "default-branch: $DEFAULT_BRANCH"
  if [ -z "$UPSTREAM_URL" ]; then
    echo "upstream-topology: missing-upstream-remote"
    return "$TOPOLOGY_DEGRADED"
  fi
  if [ "$(normalize_url "$ORIGIN_URL")" = "$(normalize_url "$UPSTREAM_URL")" ]; then
    echo "upstream-topology: same-repo-as-origin"
    return 1
  fi
  # Public upstream is fetch-only. Git gives a remote the fetch url as its push
  # url unless one is set, so the default configuration is exactly the one that
  # lets an accidental `git push upstream` reach the public repo. Refuse until
  # pushing there is disabled.
  UPSTREAM_PUSH_URL=$(remote_push_url "$UPSTREAM_REMOTE")
  echo "upstream-push-url: ${UPSTREAM_PUSH_URL:-none}"
  if [ -n "$UPSTREAM_PUSH_URL" ] \
    && [ "$(normalize_url "$UPSTREAM_PUSH_URL")" = "$(normalize_url "$UPSTREAM_URL")" ]; then
    echo "upstream-topology: upstream-push-enabled"
    echo "upstream-topology-fix: git remote set-url --push $UPSTREAM_REMOTE DISABLED"
    return 1
  fi
  echo "upstream-topology: ok"
  return 0
}

normalize_url() {
  # Compare remotes by identity, not by spelling: trailing slash, .git suffix,
  # and scp-style vs https form all name the same repository.
  printf '%s\n' "$1" \
    | sed -e 's#/*$##' -e 's#\.git$##' -e 's#^git@\([^:]*\):#https://\1/#' -e 's#^ssh://git@#https://#'
}

# The one way an unavailable public upstream is reported, whatever made it
# unavailable. It is never "current" and never "nothing new"; the caller is
# expected to carry on with the ordinary origin-only update and say plainly that
# the public comparison did not run.
report_degraded() {
  echo "upstream-check: degraded: $1, public comparison did not run"
  echo "upstream-status: not-compared"
  echo "reconcile-required: not-applicable"
}

fetch_upstream() {
  local out rc
  [ "$FETCH_TIMEOUT" -gt 0 ] 2>/dev/null || FETCH_TIMEOUT=60
  set +e
  out=$(fm_run_timed "$FETCH_TIMEOUT" git -C "$FM_ROOT" fetch "$UPSTREAM_REMOTE" --prune 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 124 ]; then
    echo "upstream-fetch: failed: timed out after ${FETCH_TIMEOUT}s"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "upstream-fetch: failed: $(first_line "$out" "git fetch exited with status $rc")"
    return 1
  fi
  echo "upstream-fetch: ok"
  return 0
}

# Classify origin against upstream and set UPSTREAM_STATUS.
UPSTREAM_STATUS=""
NEW_COMMITS=0
UNAVAILABLE_REASON=""
classify() {
  local origin_ref="origin/$DEFAULT_BRANCH" upstream_ref="$UPSTREAM_REMOTE/$DEFAULT_BRANCH"
  local cherry equivalent sha
  if ! git_root rev-parse --verify --quiet "$origin_ref^{commit}" >/dev/null; then
    UNAVAILABLE_REASON="$origin_ref does not exist"
    return 1
  fi
  if ! git_root rev-parse --verify --quiet "$upstream_ref^{commit}" >/dev/null; then
    UNAVAILABLE_REASON="$upstream_ref does not exist"
    return 1
  fi
  echo "upstream-ref: $upstream_ref $(git_root rev-parse --short "$upstream_ref")"
  echo "origin-ref: $origin_ref $(git_root rev-parse --short "$origin_ref")"
  cherry=$(git_root cherry "$origin_ref" "$upstream_ref" 2>/dev/null || true)
  NEW_COMMITS=$(printf '%s\n' "$cherry" | grep -c '^+ ' || true)
  equivalent=$(printf '%s\n' "$cherry" | grep -c '^- ' || true)
  echo "upstream-new-commits: $NEW_COMMITS"
  echo "upstream-equivalent-commits: $equivalent"
  if [ -z "$cherry" ]; then
    UPSTREAM_STATUS=current
  elif [ "$NEW_COMMITS" -eq 0 ]; then
    UPSTREAM_STATUS=contained
  else
    UPSTREAM_STATUS=diverged
  fi
  echo "upstream-status: $UPSTREAM_STATUS"
  printf '%s\n' "$cherry" | grep '^+ ' | head -"$COMMIT_LIMIT" | while read -r _ sha; do
    [ -n "$sha" ] || continue
    echo "upstream-commit: $(git_root rev-parse --short "$sha") $(git_root log -1 --format=%s "$sha")"
  done
  if [ "$NEW_COMMITS" -gt "$COMMIT_LIMIT" ]; then
    echo "upstream-commit-list-truncated: $COMMIT_LIMIT of $NEW_COMMITS"
  fi
  return 0
}

# Every condition that can stop the public comparison from completing, gathered
# in one place. Each one sets UNAVAILABLE_REASON and returns non-zero, and both
# commands answer that the same way, so a further way for the comparison to be
# unavailable joins this path rather than growing a branch of its own.
# UPSTREAM_COMPARED is the single signal that a comparison against public
# upstream actually happened on THIS run.
UPSTREAM_COMPARED=0
attempt_comparison() {
  local topology_rc=$1
  UNAVAILABLE_REASON=""
  if [ "$topology_rc" -eq "$TOPOLOGY_DEGRADED" ]; then
    UNAVAILABLE_REASON="no $UPSTREAM_REMOTE remote"
    return 1
  fi
  fetch_upstream || {
    UNAVAILABLE_REASON="public upstream unreachable"
    return 1
  }
  classify || return 1
  UPSTREAM_COMPARED=1
  return 0
}

# Run the inventory owner and pass its lines straight through. A missing or
# schema-invalid inventory is a hard refusal, not a note: without it, nothing
# here can tell intentional private divergence from accidental drift, so the
# caller must stop rather than reconcile as if the inventory had answered.
# The upstream side of the comparison is offered ONLY when this run actually
# compared against public upstream. A cached ref from an earlier run says what
# public upstream looked like then, and answering with it on a degraded run
# would contradict the same run's "the public comparison did not run".
report_inventory() {
  local root=$1 head=$2 base upstream_arg out rc
  base=""
  upstream_arg=""
  if [ "$UPSTREAM_COMPARED" -eq 1 ]; then
    upstream_arg="$UPSTREAM_REMOTE/$DEFAULT_BRANCH"
    base=$(git -C "$root" merge-base "origin/$DEFAULT_BRANCH" "$upstream_arg" 2>/dev/null || true)
  fi
  set +e
  out=$("$SCRIPT_DIR/fm-private-divergence.sh" --root "$root" \
    ${base:+--base "$base"} --head "$head" \
    ${upstream_arg:+--upstream "$upstream_arg"} 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || return 5
  return 0
}

cmd_check() {
  local rc=0
  check_topology || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq "$TOPOLOGY_DEGRADED" ] || return 2
  if ! attempt_comparison "$rc"; then
    report_degraded "$UNAVAILABLE_REASON"
    report_inventory "$FM_ROOT" "origin/$DEFAULT_BRANCH" || return 5
    return 0
  fi
  if [ "$UPSTREAM_STATUS" = diverged ]; then
    echo "reconcile-required: yes"
  else
    echo "reconcile-required: no"
  fi
  report_inventory "$FM_ROOT" "origin/$DEFAULT_BRANCH" || return 5
  return 0
}

cmd_reconcile() {
  local branch="" worktree="" upstream_ref origin_ref before_head merge_out merge_rc conflicts out rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch) branch=${2:-}; shift 2 || return 1 ;;
      --worktree) worktree=${2:-}; shift 2 || return 1 ;;
      *) usage; return 1 ;;
    esac
  done
  rc=0
  check_topology || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq "$TOPOLOGY_DEGRADED" ] || return 2
  if ! attempt_comparison "$rc"; then
    report_degraded "$UNAVAILABLE_REASON"
    echo "reconcile: not-required: no public upstream comparison was possible"
    return 0
  fi
  if [ "$UPSTREAM_STATUS" != diverged ]; then
    echo "reconcile: not-required: upstream is $UPSTREAM_STATUS"
    return 0
  fi

  origin_ref="origin/$DEFAULT_BRANCH"
  upstream_ref="$UPSTREAM_REMOTE/$DEFAULT_BRANCH"
  # The pull request this prepares can only ever target origin. Say so on the
  # record, so a reader never has to infer that upstream is fetch-only.
  echo "pr-target: origin $ORIGIN_URL"
  echo "push-to-upstream: never"

  branch=${branch:-"fm/upstream-reconcile-$(git_root rev-parse --short "$upstream_ref")"}
  worktree=${worktree:-"$STATE/upstream-reconcile/$(printf '%s' "$branch" | tr '/' '-')"}
  if git_root show-ref --verify --quiet "refs/heads/$branch"; then
    echo "reconcile: skipped: branch $branch already exists"
    echo "reconcile-recovery: inspect $branch and delete it once its work has landed or is not wanted, then rerun; or rerun with --branch <name>"
    return 2
  fi
  if [ -e "$worktree" ]; then
    echo "reconcile: skipped: worktree path $worktree already exists"
    echo "reconcile-recovery: fm-upstream.sh cleanup --worktree $worktree, then rerun; or rerun with --worktree <dir>"
    return 2
  fi

  before_head=$(git_root rev-parse HEAD)
  mkdir -p "$(dirname "$worktree")"
  if ! out=$(git_root worktree add -q -b "$branch" "$worktree" "$origin_ref" 2>&1); then
    echo "reconcile: skipped: cannot create isolated worktree: $(printf '%s\n' "$out" | head -1)"
    return 2
  fi
  echo "reconcile-worktree: $worktree"
  echo "reconcile-branch: $branch"

  set +e
  merge_out=$(git -C "$worktree" merge --no-ff --no-edit "$upstream_ref" 2>&1)
  merge_rc=$?
  set -e
  if [ "$merge_rc" -ne 0 ]; then
    conflicts=$(git -C "$worktree" diff --name-only --diff-filter=U 2>/dev/null || true)
    git -C "$worktree" merge --abort >/dev/null 2>&1 || true
    discard_scratch "$worktree" "$branch"
    assert_active_checkout "$before_head" || return 6
    # A merge git refused outright never started, so there is nothing for a
    # captain to judge; only unmerged paths mean a real semantic conflict.
    if [ -z "$conflicts" ]; then
      echo "reconcile: failed: the merge could not start: $(first_line "$merge_out" "git merge exited with status $merge_rc")"
      return 6
    fi
    echo "reconcile: conflict"
    printf '%s\n' "$conflicts" | sed 's|^|reconcile-conflict-path: |'
    echo "reconcile-next: captain decision required, nothing was changed"
    return 4
  fi

  # A merge onto origin/<default> keeps every private commit reachable by
  # construction; assert it rather than assume it.
  if ! git -C "$worktree" merge-base --is-ancestor "$origin_ref" HEAD; then
    discard_scratch "$worktree" "$branch"
    echo "reconcile: failed: private commits are not preserved on $branch"
    return 6
  fi
  echo "private-commits: preserved"
  if ! assert_active_checkout "$before_head"; then
    discard_scratch "$worktree" "$branch"
    return 6
  fi
  echo "reconcile-merged-commits: $(git_root rev-list --count "$origin_ref..$upstream_ref")"
  if ! report_inventory "$worktree" HEAD; then
    discard_scratch "$worktree" "$branch"
    return 5
  fi
  echo "reconcile: ready"
  return 0
}

# A reconciliation that does not reach `reconcile: ready` leaves nothing behind
# to block the next attempt: the branch name is deterministic, so a kept scratch
# branch would refuse every retry. The scratch carries no work of its own - it is
# origin/<default> plus a merge reproducible from the two refs - so removing it
# discards nothing. Work that is NOT reproducible is never removed: an
# uncommitted change means the scratch is kept and its recovery is spelled out.
discard_scratch() {
  local worktree=$1 branch=$2 out
  if [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null | head -1)" ]; then
    echo "reconcile-scratch: kept $worktree on $branch, it has uncommitted work"
    echo "reconcile-recovery: inspect that worktree, then fm-upstream.sh cleanup --worktree $worktree and delete $branch before rerunning"
    return 0
  fi
  if ! out=$(git_root worktree remove --force "$worktree" 2>&1); then
    echo "reconcile-scratch: kept $worktree on $branch, the worktree could not be removed: $(first_line "$out" "git worktree remove failed")"
    echo "reconcile-recovery: remove that worktree by hand, then delete $branch before rerunning; or rerun with --branch <name> and --worktree <dir>"
    return 0
  fi
  if ! out=$(git_root branch -D "$branch" 2>&1); then
    echo "reconcile-scratch: kept branch $branch, it could not be deleted: $(first_line "$out" "git branch -D failed")"
    echo "reconcile-recovery: delete $branch by hand before rerunning; or rerun with --branch <name>"
    return 0
  fi
  echo "reconcile-scratch: discarded, nothing was left behind"
}

# The active checkout is never moved by unmerged reconciliation work. Prove it
# rather than trusting that no command touched it. Both invariants are asserted
# BEFORE any `reconcile:` decision line is printed, so a failed assertion can
# never be read as a decision.
assert_active_checkout() {
  local before=$1 now
  now=$(git_root rev-parse HEAD)
  if [ "$now" = "$before" ]; then
    echo "active-checkout: unchanged"
  else
    echo "reconcile: failed: the active checkout moved during reconciliation"
    echo "active-checkout: MOVED $before..$now" >&2
    return 1
  fi
}

cmd_cleanup() {
  local worktree="" out
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) worktree=${2:-}; shift 2 || return 1 ;;
      *) usage; return 1 ;;
    esac
  done
  [ -n "$worktree" ] || { usage; return 1; }
  if [ ! -d "$worktree" ]; then
    echo "cleanup: skipped: $worktree is not a directory"
    return 2
  fi
  if [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null | head -1)" ]; then
    echo "cleanup: skipped: $worktree has uncommitted work"
    return 2
  fi
  if ! out=$(git_root worktree remove "$worktree" 2>&1); then
    echo "cleanup: skipped: $(printf '%s\n' "$out" | head -1)"
    return 2
  fi
  echo "cleanup: removed $worktree (branch kept)"
  return 0
}

"$SCRIPT_DIR/fm-guard.sh" || true

case "${1:-check}" in
  --help|-h) usage; exit 0 ;;
  check) shift || true; [ $# -eq 0 ] || { usage; exit 1; }; cmd_check ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  *) usage; exit 1 ;;
esac
