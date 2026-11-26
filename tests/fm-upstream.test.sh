#!/usr/bin/env bash
# Tests for bin/fm-upstream.sh: the public-upstream check and the isolated
# reconciliation that precedes a private-origin self-update.
#
# The guarantees under test:
#   - Every invocation actually consults public upstream and reports the three
#     answers separately: no new upstream commits (current), upstream commits
#     already patch-equivalent to what origin carries (contained), and genuinely
#     new upstream commits (diverged).
#   - Reconciliation is isolated: the merge happens on a NEW branch in its own
#     worktree, every private commit stays reachable, and the active checkout
#     never moves.
#   - A conflict is a stop, not a workaround: the merge is aborted, the
#     conflicting paths are reported, the private commit survives untouched, and
#     the scratch is torn down - or truthfully reported as kept when it cannot
#     be. A merge git refuses outright never started, so it is reported as a
#     failure carrying git's reason rather than as a conflict.
#   - Public upstream is FETCH ONLY: no run advances an upstream ref, and the
#     only pull-request target reported is the private origin.
#   - Unsafe remote topology refuses with its own exit code, while an upstream
#     that is merely UNAVAILABLE - no upstream remote, a failed fetch, or a
#     public repo with no branch matching this home's default - degrades down
#     one path to origin-only updating and says so, and is never mistaken for
#     "nothing new".
#   - A reconciliation that does not reach `reconcile: ready` leaves nothing
#     behind that would block the next attempt, and only ever claims a teardown
#     it actually completed.
#   - A degraded run never answers from a cached upstream ref: the inventory's
#     public comparison is offered only after a fetch that actually succeeded.
#   - A missing or schema-invalid private-divergence inventory is a hard refusal
#     with its own exit code, because the classification that separates
#     intentional divergence from drift is then unavailable.
#   - No decision line is ever printed before the invariants behind it hold.
#   - After a reconciliation lands on origin, the ordinary guarded fast-forward
#     in bin/fm-update.sh advances the home.
#   - pr-guard counts public upstream commits a pull request actually carries,
#     from a fresh fetch into a scratch repository, and never from the cached
#     upstream ref. A pull request that carries none is clear. A repo URL that
#     is not this home's origin is not-applicable and does not fetch. An
#     unreachable public upstream, and a head commit the pull-request ref
#     cannot reach, are unknown. carried on the recorded incident commits
#     reports the 51-commit gap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPSTREAM="$ROOT/bin/fm-upstream.sh"
UPDATE="$ROOT/bin/fm-update.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-upstream-tests)

# Build a fork world: a public bare upstream with one commit, a private bare
# origin forked from it, a working clone of origin carrying both remotes, and a
# firstmate home. Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/upstream.git" "$w/pub" 2>/dev/null
  printf 'v1\n' > "$w/pub/AGENTS.md"
  printf 'core\n' > "$w/pub/core.txt"
  mkdir -p "$w/pub/docs"
  cat > "$w/pub/docs/private-divergence.json" <<'JSON'
{ "version": 1, "entries": [] }
JSON
  git -C "$w/pub" add -A
  git -C "$w/pub" commit -qm fork-point
  git -C "$w/pub" push -q origin main

  git clone -q --bare "$w/upstream.git" "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$w/main" remote add upstream "$w/upstream.git"
  # Public upstream is fetch-only, which is what a home must configure before
  # any upstream work runs.
  git -C "$w/main" remote set-url --push upstream DISABLED
  printf '%s\n' "$w"
}

# Add one commit to the PUBLIC upstream. Args: world file content [message].
bump_upstream() {
  local w=$1 file=$2 content=$3 msg=${4:-public-change}
  git -C "$w/pub" pull -q origin main >/dev/null 2>&1 || true
  printf '%s\n' "$content" > "$w/pub/$file"
  git -C "$w/pub" add -A
  git -C "$w/pub" commit -qm "$msg"
  git -C "$w/pub" push -q origin main
}

# Add one commit to the PRIVATE origin through the working clone.
bump_private() {
  local w=$1 file=$2 content=$3 msg=${4:-private-change}
  printf '%s\n' "$content" > "$w/main/$file"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm "$msg"
  git -C "$w/main" push -q origin main
}

# Re-apply one PUBLIC commit privately as a DIFFERENT commit carrying the same
# patch, which is what a cherry-picked or independently re-applied upstream
# change looks like. The amend guarantees a distinct sha even when the original
# commit's identity and timestamp would otherwise reproduce it exactly.
reapply_privately() {
  local w=$1 sha=$2
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" cherry-pick "$sha" >/dev/null 2>&1 || fail "fixture cherry-pick failed"
  git -C "$w/main" commit -q --amend -m "private re-application of $sha"
  git -C "$w/main" push -q origin main
}

run_upstream() {
  local w=$1
  shift
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPSTREAM" "$@" 2>/dev/null
}

# A `git` that forwards to the real one but refuses whichever subcommand the
# caller names. Failure paths that exist because git itself can refuse - a
# locked worktree, a branch that will not delete - are otherwise unreachable
# from a test, and they are exactly the paths where a false "nothing was left
# behind" would strand the operator.
make_git_shim() {
  local w=$1 real
  real=$(command -v git)
  mkdir -p "$w/shim"
  cat > "$w/shim/git" <<SHIM
#!/usr/bin/env bash
if [ -n "\${FM_TEST_GIT_FAIL:-}" ] && [[ "\$*" == *"\$FM_TEST_GIT_FAIL"* ]]; then
  [ -n "\${FM_TEST_GIT_FAIL_QUIET:-}" ] || echo "fatal: injected failure" >&2
  exit 1
fi
exec "$real" "\$@"
SHIM
  chmod +x "$w/shim/git"
}

# Run fm-upstream.sh with the shim first on PATH. Args: world fail-pattern cmd...
run_upstream_with_failing_git() {
  local w=$1 pattern=$2
  shift 2
  make_git_shim "$w"
  PATH="$w/shim:$PATH" FM_TEST_GIT_FAIL="$pattern" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPSTREAM" "$@" 2>/dev/null
}

break_inventory() {
  local w=$1
  printf '{ "version": 1, "entries": [{"id":"x"}] }\n' > "$w/main/docs/private-divergence.json"
}

upstream_tip() {
  git -C "$1/upstream.git" rev-parse refs/heads/main
}

# Two public commits on a private fork, merged for real onto a reconcile-shaped
# branch and pushed to origin, not squash-merged. Sets RECONCILE_HEAD,
# RECONCILE_UPSTREAM, and RECONCILE_BRANCH. Leaves the working clone on main.
prepare_unmerged_reconcile() {
  local w=$1
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" docs/u1.txt "one" "public-one"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  RECONCILE_UPSTREAM=$(upstream_tip "$w")
  RECONCILE_BRANCH="fm/fm-upstream-reconcile-${RECONCILE_UPSTREAM}-s1"
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" checkout -q -b "$RECONCILE_BRANCH"
  git -C "$w/main" merge -q --no-ff upstream/main -m "reconcile upstream"
  git -C "$w/main" push -q origin "$RECONCILE_BRANCH"
  RECONCILE_HEAD=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" checkout -q main
}

origin_url_of() {
  git -C "$1/main" remote get-url origin
}

# --- T1: no new public commits --------------------------------------------
test_no_new_upstream() {
  local w out
  w=$(new_world t1)
  bump_private "$w" private.txt "private only"

  out=$(run_upstream "$w" check)

  assert_contains "$out" "upstream-topology: ok" "topology is reported"
  assert_contains "$out" "upstream-fetch: ok" "upstream was actually fetched"
  assert_contains "$out" "upstream-status: current" "no new public commits"
  assert_contains "$out" "upstream-new-commits: 0" "new-commit count is zero"
  assert_contains "$out" "reconcile-required: no" "nothing to reconcile"
  pass "T1 public upstream with no new commits reports current"
}

# --- T2: upstream work already represented in origin ----------------------
test_upstream_already_contained() {
  local w out sha
  w=$(new_world t2)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" core.txt "public rewrite"
  sha=$(git -C "$w/pub" rev-parse HEAD)
  reapply_privately "$w" "$sha"

  out=$(run_upstream "$w" check)

  assert_contains "$out" "upstream-status: contained" "patch-equivalent upstream work is contained"
  assert_contains "$out" "upstream-new-commits: 0" "no genuinely new commits"
  assert_contains "$out" "upstream-equivalent-commits: 1" "the duplicate is counted as equivalent"
  assert_contains "$out" "reconcile-required: no" "a duplicate is never replayed"
  pass "T2 patch-equivalent upstream work is reported as already contained"
}

# --- T3: reconcilable divergence, isolated and non-destructive -------------
test_reconcilable_divergence() {
  local w check_out out branch worktree private_sha up_before
  w=$(new_world t3)
  bump_private "$w" private.txt "private only"
  private_sha=$(git -C "$w/main" rev-parse HEAD)
  bump_upstream "$w" public.txt "public only"
  up_before=$(upstream_tip "$w")

  check_out=$(run_upstream "$w" check)
  assert_contains "$check_out" "upstream-status: diverged" "genuinely new public commits diverge"
  assert_contains "$check_out" "reconcile-required: yes" "reconciliation is owed"
  assert_contains "$check_out" "upstream-commit: " "the new public commits are listed"

  out=$(run_upstream "$w" reconcile)

  assert_contains "$out" "reconcile: ready" "a clean reconciliation is ready"
  assert_contains "$out" "private-commits: preserved" "private commits are preserved"
  assert_contains "$out" "active-checkout: unchanged" "the active checkout never moved"
  assert_contains "$out" "pr-target: origin " "the pull request targets the private origin"
  assert_contains "$out" "push-to-upstream: never" "upstream stays fetch-only"

  branch=$(printf '%s\n' "$out" | sed -n 's/^reconcile-branch: //p')
  worktree=$(printf '%s\n' "$out" | sed -n 's/^reconcile-worktree: //p')
  [ -n "$branch" ] && [ -n "$worktree" ] || fail "reconcile did not name its branch and worktree"

  # The reconciliation lives on its own branch in its own worktree; main is
  # untouched and still at the private tip.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$private_sha" ] \
    || fail "the active checkout moved during reconciliation"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = "main" ] \
    || fail "the active checkout left its default branch"
  [ "$worktree" != "$w/main" ] || fail "reconciliation reused the active checkout"
  git -C "$worktree" merge-base --is-ancestor "$private_sha" HEAD \
    || fail "the private commit is not reachable from the reconciliation branch"
  git -C "$worktree" merge-base --is-ancestor upstream/main HEAD \
    || fail "the upstream commits are not reachable from the reconciliation branch"
  # Both files survive the merge: nothing was replayed away.
  [ -f "$worktree/private.txt" ] && [ -f "$worktree/public.txt" ] \
    || fail "reconciliation dropped one side's work"
  # Public upstream was never written to.
  [ "$(upstream_tip "$w")" = "$up_before" ] || fail "the public upstream ref moved"
  pass "T3 divergence reconciles on an isolated branch, preserving both sides"
}

# --- T4: conflicting reconciliation stops for a decision -------------------
test_conflicting_reconciliation_stops() {
  local w out rc private_sha up_before
  w=$(new_world t4)
  bump_private "$w" core.txt "private version of the contended line"
  private_sha=$(git -C "$w/main" rev-parse HEAD)
  bump_upstream "$w" core.txt "public version of the contended line"
  up_before=$(upstream_tip "$w")

  out=$(run_upstream "$w" reconcile)
  rc=$?

  expect_code 4 "$rc" "a conflicting reconciliation exits for a captain decision"
  assert_contains "$out" "reconcile: conflict" "the conflict is reported"
  assert_contains "$out" "reconcile-conflict-path: core.txt" "the conflicting path is named"
  assert_contains "$out" "active-checkout: unchanged" "the active checkout never moved"
  assert_not_contains "$out" "reconcile: ready" "a conflict is never reported as ready"

  # Nothing was left behind and nothing was forced away.
  [ -z "$(git -C "$w/main" branch --list 'fm/upstream-reconcile-*')" ] \
    || fail "the scratch reconciliation branch was left behind"
  [ -z "$(git -C "$w/main" status --porcelain)" ] \
    || fail "the active checkout was left dirty"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$private_sha" ] \
    || fail "the private commit was discarded or moved"
  grep -q 'private version' "$w/main/core.txt" || fail "the private content was overwritten"
  [ "$(upstream_tip "$w")" = "$up_before" ] || fail "the public upstream ref moved"
  pass "T4 a conflicting reconciliation aborts cleanly and stops for a decision"
}

# --- T5: no upstream remote degrades to origin-only updating ---------------
# Nothing unsafe is configured, there is simply nothing public to compare
# against, so the established guarded fast-forward must still run - while the
# report says plainly that the public comparison did not happen.
test_missing_upstream_remote_degrades() {
  local w out rc landed
  w=$(new_world t5)
  git -C "$w/main" remote remove upstream
  bump_private "$w" private.txt "private only"
  git -C "$w/main" reset -q --hard HEAD~1

  out=$(run_upstream "$w" check)
  rc=$?

  expect_code 0 "$rc" "a missing upstream remote does not block the fleet update"
  assert_contains "$out" "upstream-topology: missing-upstream-remote" "the missing remote is named"
  assert_contains "$out" "upstream-check: degraded: " "the degraded state is reported on its own line"
  assert_contains "$out" "upstream-status: not-compared" "the public comparison is reported as not run"
  assert_contains "$out" "reconcile-required: not-applicable" "there is nothing to reconcile with"
  assert_not_contains "$out" "upstream-status: current" "a missing remote is never read as current"
  assert_contains "$out" "inventory-entries: " "the inventory is still validated"

  # The ordinary origin-only fast-forward still reaches this home.
  landed=$(git -C "$w/origin.git" rev-parse refs/heads/main)
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null)
  assert_contains "$out" "firstmate: updated " "the guarded fast-forward still ran"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$landed" ] \
    || fail "the home was not updated from the private origin"
  pass "T5 a home with no public upstream remote degrades to origin-only updating"
}

# Reconcile has nothing to reconcile with, and says so rather than refusing.
test_missing_upstream_remote_reconcile_is_not_required() {
  local w out rc
  w=$(new_world t5b)
  git -C "$w/main" remote remove upstream

  out=$(run_upstream "$w" reconcile)
  rc=$?

  expect_code 0 "$rc" "reconcile degrades with the rest of the check"
  assert_contains "$out" "reconcile: not-required: " "there is no public upstream to reconcile with"
  assert_not_contains "$out" "reconcile: ready" "nothing was reconciled"
  pass "T5b reconcile with no public upstream remote is not-required, not a refusal"
}

# --- T5c: an upstream that can still be pushed to refuses ------------------
test_pushable_upstream_refuses() {
  local w out rc
  w=$(new_world t5c)
  git -C "$w/main" remote set-url --push upstream "$w/upstream.git"

  out=$(run_upstream "$w" check)
  rc=$?

  expect_code 2 "$rc" "a pushable public upstream is a topology refusal"
  assert_contains "$out" "upstream-topology: upstream-push-enabled" "the unsafe push configuration is named"
  assert_contains "$out" "upstream-push-url: $w/upstream.git" "the push url is on the record"
  assert_contains "$out" "upstream-topology-fix: git remote set-url --push upstream " "the fix is named"
  assert_not_contains "$out" "upstream-status: " "an unsafe topology never classifies"
  pass "T5c an upstream whose push url reaches the public repo refuses"
}

test_upstream_same_repo_as_origin_refuses() {
  local w out rc
  w=$(new_world t6)
  git -C "$w/main" remote set-url upstream "$w/origin.git"

  out=$(run_upstream "$w" check)
  rc=$?

  expect_code 2 "$rc" "upstream pointing at origin is a topology refusal"
  assert_contains "$out" "upstream-topology: same-repo-as-origin" "the collapsed topology is named"
  pass "T6 an upstream that is the private origin refuses"
}

# --- T7: offline / unreachable upstream ------------------------------------
# Unreachable is unavailable, not unsafe: the same degraded path a home with no
# upstream remote takes, so the established origin-only update still runs - with
# the concrete fetch failure kept on the record.
test_unreachable_upstream_degrades() {
  local w out rc landed
  w=$(new_world t7)
  git -C "$w/main" remote set-url upstream "$w/does-not-exist.git"
  bump_private "$w" private.txt "private only"
  git -C "$w/main" reset -q --hard HEAD~1

  out=$(run_upstream "$w" check)
  rc=$?

  expect_code 0 "$rc" "an unreachable upstream does not block the fleet update"
  assert_contains "$out" "upstream-fetch: failed" "the concrete fetch failure stays on the record"
  assert_contains "$out" "upstream-check: degraded: " "it degrades down the one degraded path"
  assert_contains "$out" "upstream-status: not-compared" "the public comparison is reported as not run"
  assert_contains "$out" "reconcile-required: not-applicable" "there is nothing to reconcile against"
  assert_not_contains "$out" "upstream-status: current" "an unreachable upstream is never read as current"

  landed=$(git -C "$w/origin.git" rev-parse refs/heads/main)
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null)
  assert_contains "$out" "firstmate: updated " "the guarded fast-forward still ran"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$landed" ] \
    || fail "the home was not updated from the private origin"
  pass "T7 an unreachable public upstream degrades to origin-only updating"
}

test_unreachable_upstream_reconcile_is_not_required() {
  local w out rc
  w=$(new_world t7b)
  git -C "$w/main" remote set-url upstream "$w/does-not-exist.git"

  out=$(run_upstream "$w" reconcile)
  rc=$?

  expect_code 0 "$rc" "reconcile degrades with the rest of the check"
  assert_contains "$out" "upstream-check: degraded: " "the same degraded vocabulary is used"
  assert_contains "$out" "reconcile: not-required: " "nothing can be reconciled against an unreachable upstream"
  assert_not_contains "$out" "reconcile: ready" "nothing was reconciled"
  pass "T7b reconcile against an unreachable public upstream is not-required"
}

# --- T8: the post-merge update path ----------------------------------------
test_landed_reconciliation_updates_the_home() {
  local w out worktree merged
  w=$(new_world t8)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" public.txt "public only"

  out=$(run_upstream "$w" reconcile)
  assert_contains "$out" "reconcile: ready" "reconciliation is ready to ship"
  worktree=$(printf '%s\n' "$out" | sed -n 's/^reconcile-worktree: //p')

  # Stand in for the private pull request landing on origin.
  git -C "$worktree" push -q origin HEAD:main
  merged=$(git -C "$worktree" rev-parse HEAD)

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null)

  assert_contains "$out" "firstmate: updated " "the guarded fast-forward advanced the home"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$merged" ] \
    || fail "the home did not land on the reconciled commit"
  [ -f "$w/main/public.txt" ] && [ -f "$w/main/private.txt" ] \
    || fail "the landed home is missing one side's work"
  pass "T8 a landed reconciliation reaches the home through the guarded fast-forward"
}

# --- T9: cleanup keeps the branch ------------------------------------------
test_cleanup_removes_worktree_keeps_branch() {
  local w out branch worktree
  w=$(new_world t9)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" public.txt "public only"
  out=$(run_upstream "$w" reconcile)
  branch=$(printf '%s\n' "$out" | sed -n 's/^reconcile-branch: //p')
  worktree=$(printf '%s\n' "$out" | sed -n 's/^reconcile-worktree: //p')

  out=$(run_upstream "$w" cleanup --worktree "$worktree")

  assert_contains "$out" "cleanup: removed " "the scratch worktree is removed"
  assert_absent "$worktree" "the worktree directory survived cleanup"
  git -C "$w/main" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "cleanup deleted the reconciliation branch and its work"
  pass "T9 cleanup removes the scratch worktree and keeps the branch"
}

test_cleanup_refuses_uncommitted_work() {
  local w out rc branch worktree
  w=$(new_world t10)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" public.txt "public only"
  out=$(run_upstream "$w" reconcile)
  branch=$(printf '%s\n' "$out" | sed -n 's/^reconcile-branch: //p')
  worktree=$(printf '%s\n' "$out" | sed -n 's/^reconcile-worktree: //p')
  printf 'work in progress\n' >> "$worktree/private.txt"

  out=$(run_upstream "$w" cleanup --worktree "$worktree")
  rc=$?

  expect_code 2 "$rc" "cleanup refuses over uncommitted work"
  assert_contains "$out" "cleanup: skipped: " "the refusal is reported"
  grep -q 'work in progress' "$worktree/private.txt" || fail "uncommitted work was discarded"
  git -C "$w/main" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "the reconciliation branch was deleted"
  pass "T10 cleanup refuses to discard uncommitted reconciliation work"
}

# --- T11: an unusable inventory is a hard refusal ---------------------------
# Without the inventory nothing can tell intentional private divergence from
# accidental drift, so the caller must stop rather than proceed as if it had
# answered.
test_invalid_inventory_refuses() {
  local w out rc
  w=$(new_world t11)

  rm "$w/main/docs/private-divergence.json"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 5 "$rc" "a missing inventory is its own hard refusal"
  assert_contains "$out" "inventory: invalid: inventory not found" "the reason is passed through"

  printf '{ "version": 1, "entries": [{"id":"x"}] }\n' > "$w/main/docs/private-divergence.json"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 5 "$rc" "a schema-invalid inventory is its own hard refusal"
  assert_contains "$out" "inventory: invalid: " "the schema reason is passed through"
  assert_not_contains "$out" "see stderr" "the reason is reported, not deferred"
  pass "T11 a missing or schema-invalid inventory refuses with its own exit code"
}

test_invalid_inventory_refuses_reconciliation() {
  local w out rc worktree
  w=$(new_world t12)
  printf '{ "version": 1, "entries": [{"id":"x"}] }\n' > "$w/main/docs/private-divergence.json"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm break-inventory
  git -C "$w/main" push -q origin main
  bump_upstream "$w" public.txt "public only"

  out=$(run_upstream "$w" reconcile)
  rc=$?

  expect_code 5 "$rc" "reconciliation refuses on an unusable inventory"
  assert_contains "$out" "inventory: invalid: " "the reason is passed through"
  assert_not_contains "$out" "reconcile: ready" "an unusable inventory never yields a ready decision"

  # The scratch carried no work of its own, so nothing is left behind to refuse
  # the next attempt - the branch name is deterministic.
  assert_contains "$out" "reconcile-scratch: discarded" "the scratch is reported as discarded"
  [ -z "$(git -C "$w/main" branch --list 'fm/upstream-reconcile-*')" ] \
    || fail "a failed reconciliation left its scratch branch behind"
  worktree=$(printf '%s\n' "$out" | sed -n 's/^reconcile-worktree: //p')
  assert_absent "$worktree" "a failed reconciliation left its scratch worktree behind"

  # Land the fix the operator would make, then retry: it must now succeed.
  cat > "$w/main/docs/private-divergence.json" <<'JSON'
{ "version": 1, "entries": [] }
JSON
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm fix-inventory
  git -C "$w/main" push -q origin main

  out=$(run_upstream "$w" reconcile)
  rc=$?
  expect_code 0 "$rc" "the retry after the fix succeeds"
  assert_contains "$out" "reconcile: ready" "the retry is not refused by a leftover branch"
  assert_not_contains "$out" "reconcile: skipped: branch " "no leftover branch blocked the retry"
  pass "T12 a refused reconciliation leaves nothing behind and a retry succeeds"
}

# --- T14: the merged-commit count is truthful ------------------------------
# The merge brings in every upstream commit origin lacks, including ones origin
# already carries patch-equivalently. The reported count must be that real
# number, not just the genuinely-new subset.
test_merged_commit_count_is_truthful() {
  local w out sha expected
  w=$(new_world t14)
  bump_upstream "$w" core.txt "public rewrite"
  sha=$(git -C "$w/pub" rev-parse HEAD)
  # origin carries that patch under a different sha, so it is equivalent.
  reapply_privately "$w" "$sha"
  # ...and upstream then adds two genuinely new commits on top.
  bump_upstream "$w" public-a.txt "public a"
  bump_upstream "$w" public-b.txt "public b"

  git -C "$w/main" fetch -q upstream
  expected=$(git -C "$w/main" rev-list --count origin/main..upstream/main)
  [ "$expected" = 3 ] || fail "fixture did not produce three unmerged upstream commits"

  out=$(run_upstream "$w" reconcile)

  assert_contains "$out" "reconcile: ready" "the reconciliation is ready"
  assert_contains "$out" "upstream-new-commits: 2" "only two commits are genuinely new"
  assert_contains "$out" "reconcile-merged-commits: 3" "the merged count counts every commit the merge brings in"
  pass "T14 the reported merged-commit count matches what the merge actually brings in"
}

# --- T13: a decision line never precedes the invariants behind it -----------
# `reconcile:` is the whole decision the skill acts on, so it must never be
# printed before the invariants that justify it have been proven.
test_invariants_precede_the_decision_line() {
  local w out ready_at preserved_at checkout_at conflict_at
  w=$(new_world t13)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" public.txt "public only"

  out=$(run_upstream "$w" reconcile)
  preserved_at=$(printf '%s\n' "$out" | grep -n '^private-commits: preserved$' | cut -d: -f1)
  checkout_at=$(printf '%s\n' "$out" | grep -n '^active-checkout: unchanged$' | cut -d: -f1)
  ready_at=$(printf '%s\n' "$out" | grep -n '^reconcile: ready$' | cut -d: -f1)
  [ -n "$preserved_at" ] && [ -n "$checkout_at" ] && [ -n "$ready_at" ] \
    || fail "the ready decision did not report both invariants"
  [ "$preserved_at" -lt "$ready_at" ] \
    || fail "reconcile: ready was printed before private commits were proven preserved"
  [ "$checkout_at" -lt "$ready_at" ] \
    || fail "reconcile: ready was printed before the active checkout was proven unchanged"

  w=$(new_world t13b)
  bump_private "$w" core.txt "private version of the contended line"
  bump_upstream "$w" core.txt "public version of the contended line"
  out=$(run_upstream "$w" reconcile)
  checkout_at=$(printf '%s\n' "$out" | grep -n '^active-checkout: unchanged$' | cut -d: -f1)
  conflict_at=$(printf '%s\n' "$out" | grep -n '^reconcile: conflict$' | cut -d: -f1)
  [ -n "$checkout_at" ] && [ -n "$conflict_at" ] \
    || fail "the conflict decision did not report the checkout invariant"
  [ "$checkout_at" -lt "$conflict_at" ] \
    || fail "reconcile: conflict was printed before the active checkout was proven unchanged"
  pass "T13 no reconcile decision is printed before its invariants are proven"
}

# --- T15: a teardown that could not complete is never reported as done -------
# The branch name is deterministic, so a scratch the script failed to remove
# blocks every retry. Claiming it was discarded would send the operator away
# believing there is nothing to clean up.
test_incomplete_discard_is_reported() {
  local w out rc branch
  w=$(new_world t15)
  break_inventory "$w"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm break-inventory
  git -C "$w/main" push -q origin main
  bump_upstream "$w" public.txt "public only"

  out=$(run_upstream_with_failing_git "$w" "worktree remove" reconcile)
  rc=$?

  expect_code 5 "$rc" "the inventory refusal still decides the exit code"
  assert_contains "$out" "reconcile-scratch: kept " "the scratch is reported as kept"
  assert_contains "$out" "reconcile-recovery: " "a recovery step is named"
  assert_not_contains "$out" "nothing was left behind" "an incomplete teardown never claims success"

  # The report must match reality: the branch really is still there.
  branch=$(printf '%s\n' "$out" | sed -n 's/^reconcile-branch: //p')
  [ -n "$branch" ] || fail "reconcile did not name its branch"
  assert_contains "$out" "$branch" "the branch left behind is named"
  git -C "$w/main" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "the report said the scratch was kept but the branch is gone"
  pass "T15 a teardown that could not complete says so and names what was left"
}

# --- T16: a degraded run never answers from a cached upstream ref ------------
# A home that fetched upstream successfully last week and is now offline still
# has upstream/<default> in its object store. Comparing against it would
# contradict the same run's "the public comparison did not run".
test_degraded_check_does_not_use_the_cached_upstream_ref() {
  local w out rc
  w=$(new_world t16)
  bump_upstream "$w" public.txt "public only"
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" rev-parse --verify --quiet upstream/main >/dev/null \
    || fail "fixture did not leave a cached upstream ref"
  git -C "$w/main" remote set-url upstream "$w/does-not-exist.git"

  out=$(run_upstream "$w" check)
  rc=$?

  expect_code 0 "$rc" "the degraded path still completes"
  assert_contains "$out" "upstream-status: not-compared" "the public comparison is reported as not run"
  assert_contains "$out" "inventory-drift: unavailable: " "the inventory reports its own unavailable reason"
  assert_not_contains "$out" "inventory-drift: compared " "nothing is compared against the stale cached ref"
  # The file-local checks still run, and an unusable inventory still refuses.
  assert_contains "$out" "inventory-entries: " "the inventory is still validated"

  break_inventory "$w"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 5 "$rc" "an unusable inventory still refuses on the degraded path"
  assert_contains "$out" "inventory: invalid: " "the reason is passed through"
  pass "T16 a degraded check never compares against the cached upstream ref"
}

# --- T17: a broken invariant is distinguishable from a refusal ---------------
test_broken_invariant_has_its_own_exit_code() {
  local w out rc
  w=$(new_world t17)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" public.txt "public only"

  out=$(run_upstream_with_failing_git "$w" "merge-base --is-ancestor" reconcile)
  rc=$?

  expect_code 6 "$rc" "a broken invariant is not an ordinary topology refusal"
  assert_contains "$out" "reconcile: failed: private commits are not preserved" "the invariant failure is named"
  assert_not_contains "$out" "reconcile: ready" "a broken invariant never yields a ready decision"
  [ -z "$(git -C "$w/main" branch --list 'fm/upstream-reconcile-*')" ] \
    || fail "the scratch branch was left behind"
  pass "T17 a broken reconciliation invariant returns the dedicated invariant code"
}

# --- T18: a fetch failure always carries a reason ----------------------------
test_silent_fetch_failure_still_reports_a_reason() {
  local w out line
  w=$(new_world t18)

  make_git_shim "$w"
  out=$(PATH="$w/shim:$PATH" FM_TEST_GIT_FAIL="fetch upstream" FM_TEST_GIT_FAIL_QUIET=1 \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPSTREAM" check 2>/dev/null)

  assert_contains "$out" "upstream-fetch: failed: " "the failure is reported"
  line=$(printf '%s\n' "$out" | sed -n 's/^upstream-fetch: failed: //p')
  [ -n "$line" ] || fail "the fetch failure line carried no reason"
  assert_contains "$out" "upstream-status: not-compared" "a silent failure still degrades, not guesses"
  pass "T18 a fetch that fails without output still reports a concrete reason"
}

# --- T19: the conflict path reports a kept scratch just as the failure path does
# Both paths share one teardown helper, so the conflict decision must carry the
# same qualification: a teardown that could not complete is never reported as
# though nothing was left behind.
test_conflict_reports_a_kept_scratch() {
  local w out rc branch private_sha
  w=$(new_world t19)
  bump_private "$w" core.txt "private version of the contended line"
  private_sha=$(git -C "$w/main" rev-parse HEAD)
  bump_upstream "$w" core.txt "public version of the contended line"

  out=$(run_upstream_with_failing_git "$w" "worktree remove" reconcile)
  rc=$?

  expect_code 4 "$rc" "the conflict still decides the exit code"
  assert_contains "$out" "reconcile: conflict" "the conflict is still reported"
  assert_contains "$out" "reconcile-scratch: kept " "the scratch that survived is reported"
  assert_contains "$out" "reconcile-recovery: " "a recovery step is named"
  assert_not_contains "$out" "nothing was left behind" "an incomplete teardown never claims success"

  branch=$(printf '%s\n' "$out" | sed -n 's/^reconcile-branch: //p')
  [ -n "$branch" ] || fail "reconcile did not name its branch"
  git -C "$w/main" show-ref --verify --quiet "refs/heads/$branch" \
    || fail "the report said the scratch was kept but the branch is gone"

  # The conflict guarantee itself still holds: the merge was aborted and the
  # private work is untouched.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$private_sha" ] \
    || fail "the private commit was discarded or moved"
  grep -q 'private version' "$w/main/core.txt" || fail "the private content was overwritten"
  pass "T19 a conflict whose teardown cannot complete reports the kept scratch"
}

# --- T20: the degraded path says the comparison was not requested ------------
# Nothing failed to resolve there: the upstream side was deliberately withheld
# because no fetch succeeded, and the operator must not be told otherwise.
test_degraded_reports_a_distinct_unavailable_reason() {
  local w out unresolvable
  w=$(new_world t20)
  git -C "$w/main" remote remove upstream

  out=$(run_upstream "$w" check)

  assert_contains "$out" "inventory-drift: unavailable: comparison not requested" \
    "the degraded reason says the comparison was never offered"
  assert_not_contains "$out" "unresolvable" "nothing is claimed to have failed to resolve"

  # A revision that genuinely does not resolve still reports the other reason,
  # so the two stay distinguishable.
  unresolvable=$("$ROOT/bin/fm-private-divergence.sh" --root "$w/main" \
    --base HEAD --head main --upstream no-such-ref 2>&1)
  assert_contains "$unresolvable" "inventory-drift: unavailable: base, head, or upstream revision unresolvable" \
    "a real resolution failure keeps its own reason"
  pass "T20 a withheld comparison and an unresolvable revision report different reasons"
}

# --- T21: a missing public default branch degrades like any other unavailable
# public upstream. The fetch succeeded, so nothing is unsafe; there is simply no
# public branch to compare this home's default against.
test_missing_upstream_default_branch_degrades() {
  local w out rc landed
  w=$(new_world t21)
  git -C "$w/upstream.git" branch -m main master
  bump_private "$w" private.txt "private only"
  git -C "$w/main" reset -q --hard HEAD~1

  out=$(run_upstream "$w" check)
  rc=$?

  expect_code 0 "$rc" "a missing public default branch does not block the fleet update"
  assert_contains "$out" "upstream-topology: ok" "nothing about the setup is unsafe"
  assert_contains "$out" "upstream-fetch: ok" "the bounded fetch itself succeeded"
  assert_contains "$out" "upstream-check: degraded: upstream/main does not exist" \
    "the ref that does not exist is named on the record"
  assert_contains "$out" "upstream-status: not-compared" "the public comparison is reported as not run"
  assert_not_contains "$out" "upstream-status: current" "it is never read as current"
  assert_not_contains "$out" "upstream-status: unknown" "the retired unknown vocabulary is gone"

  landed=$(git -C "$w/origin.git" rev-parse refs/heads/main)
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null)
  assert_contains "$out" "firstmate: updated " "the guarded fast-forward still ran"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$landed" ] \
    || fail "the home was not updated from the private origin"
  pass "T21 a public repo with no matching default branch degrades to origin-only updating"
}

# --- T22: a merge git refuses outright is not a conflict ---------------------
# Nothing was merged and nothing conflicted, so no captain semantic judgement is
# owed; the report must carry git's own reason and the invariant exit code.
test_non_conflicting_merge_failure_is_not_a_conflict() {
  local w out rc
  w=$(new_world t22)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" public.txt "public only"

  out=$(run_upstream_with_failing_git "$w" "merge --no-ff" reconcile)
  rc=$?

  expect_code 6 "$rc" "a merge that never started does not use the conflict exit code"
  assert_contains "$out" "reconcile: failed: the merge could not start: " "it is reported as its own state"
  assert_contains "$out" "injected failure" "git's concrete reason stays on the record"
  assert_not_contains "$out" "reconcile: conflict" "no conflict is claimed"
  assert_not_contains "$out" "captain decision required" "no semantic judgement is demanded"
  [ -z "$(git -C "$w/main" branch --list 'fm/upstream-reconcile-*')" ] \
    || fail "the scratch branch was left behind"
  pass "T22 a merge git refuses outright reports a failure, not a conflict"
}

# --- T23: a comparison that was requested but has no merge base says so -------
# After the public repo is re-seeded with an unrelated history the two sides
# share no merge base. The comparison WAS requested, so reporting it as never
# requested would be untrue.
test_uncomputable_merge_base_reports_itself() {
  local w out
  w=$(new_world t23)
  git -C "$w/pub" checkout -q --orphan reseed
  printf 'reseeded\n' > "$w/pub/core.txt"
  git -C "$w/pub" add -A
  git -C "$w/pub" commit -qm public-reseed
  git -C "$w/pub" push -qf origin reseed:main

  out=$(run_upstream "$w" check)

  assert_contains "$out" "upstream-fetch: ok" "the comparison really was attempted"
  assert_contains "$out" "inventory-drift: unavailable: merge base could not be computed" \
    "the uncomputable merge base is reported as itself"
  assert_not_contains "$out" "comparison not requested" "the comparison was requested"
  assert_not_contains "$out" "unresolvable" "both revisions resolved fine"
  pass "T23 a requested comparison with no merge base says the merge base could not be computed"
}

# --- G1: a real merge of two upstream commits carries both ----------------
test_pr_guard_carries_two_upstream_commits() {
  local w out rc before
  w=$(new_world g1)
  prepare_unmerged_reconcile "$w"
  before=$(git -C "$w/main" rev-parse HEAD)
  out=$(run_upstream "$w" pr-guard \
    --repo-url "$(origin_url_of "$w")" \
    --pr-ref "refs/heads/$RECONCILE_BRANCH" \
    --head "$RECONCILE_HEAD" \
    --base main)
  rc=$?
  expect_code 0 "$rc" "a carrying pull request exits 0"
  assert_contains "$out" "upstream-guard: carries" "the guard sees the upstream commits"
  assert_contains "$out" "upstream-carried-commits: 2" "both public commits are carried"
  assert_contains "$out" "upstream-carried-through: $RECONCILE_UPSTREAM" \
    "the carried tip is the upstream commit itself"
  assert_not_contains "$out" "upstream-topology:" "the guard does not run the topology check"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "pr-guard moved the working clone"
  pass "G1 pr-guard reports two carried upstream commits before the squash"
}

# --- G2: an ordinary feature branch carries nothing -----------------------
test_pr_guard_ordinary_feature_is_clear() {
  local w out rc head
  w=$(new_world g2)
  bump_private "$w" private.txt "private only"
  bump_upstream "$w" docs/u1.txt "one" "public-one"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  git -C "$w/main" checkout -q -b fm/ordinary-feature
  printf 'feature\n' > "$w/main/feature.txt"
  git -C "$w/main" add feature.txt
  git -C "$w/main" commit -qm "ordinary feature"
  git -C "$w/main" push -q origin fm/ordinary-feature
  head=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" checkout -q main
  out=$(run_upstream "$w" pr-guard \
    --repo-url "$(origin_url_of "$w")" \
    --pr-ref refs/heads/fm/ordinary-feature \
    --head "$head" \
    --base main)
  rc=$?
  expect_code 0 "$rc" "a clear pull request exits 0"
  assert_contains "$out" "upstream-guard: clear" "a private feature carries no upstream commit"
  assert_not_contains "$out" "upstream-guard: carries" "clear is not reported as carries"
  assert_not_contains "$out" "upstream-carried-commits:" "a clear result has no carried count"
  pass "G2 an ordinary feature branch is clear"
}

# --- G3: a foreign repo URL never fetches ---------------------------------
test_pr_guard_foreign_repo_does_not_fetch() {
  local w out rc real head
  w=$(new_world g3)
  bump_private "$w" private.txt "private only"
  head=$(git -C "$w/main" rev-parse HEAD)
  real=$(command -v git)
  mkdir -p "$w/shim"
  cat > "$w/shim/git" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$w/git.log"
case " \$* " in
  *" fetch "*) echo "fatal: injected fetch failure" >&2; exit 1 ;;
esac
exec "$real" "\$@"
SHIM
  chmod +x "$w/shim/git"
  out=$(PATH="$w/shim:$PATH" FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPSTREAM" pr-guard \
    --repo-url https://example.invalid/other/repo \
    --pr-ref refs/heads/main \
    --head "$head" \
    --base main 2>/dev/null)
  rc=$?
  expect_code 0 "$rc" "a foreign repo URL is not an error"
  assert_contains "$out" "upstream-guard: not-applicable: https://example.invalid/other/repo is not this home's origin" \
    "the foreign URL is named in the not-applicable result"
  assert_not_contains "$out" "upstream-guard: unknown:" "the guard did not go on to fetch"
  if grep -F " fetch " "$w/git.log" >/dev/null 2>&1; then
    fail "pr-guard fetched for a repo URL that is not this home's origin"
  fi
  pass "G3 a foreign repo URL is not-applicable and does not fetch"
}

# --- G4: public upstream cannot be fetched --------------------------------
test_pr_guard_unreachable_upstream_is_unknown() {
  local w out rc head
  w=$(new_world g4)
  bump_private "$w" private.txt "private only"
  head=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" remote set-url upstream "$w/does-not-exist.git"
  out=$(run_upstream "$w" pr-guard \
    --repo-url "$(origin_url_of "$w")" \
    --pr-ref refs/heads/main \
    --head "$head" \
    --base main)
  rc=$?
  expect_code 0 "$rc" "an unreachable public upstream exits 0"
  assert_contains "$out" "upstream-guard: unknown: public upstream unreachable" \
    "the guard says the public upstream could not be fetched"
  assert_not_contains "$out" "upstream-guard: clear" "unreachable is not clear"
  assert_not_contains "$out" "upstream-guard: carries" "unreachable is not carries"
  pass "G4 an unreachable public upstream is unknown"
}

# --- G5: a rewound cached upstream ref is never consulted -----------------
test_pr_guard_ignores_rewound_cached_upstream() {
  local w out rc fork
  w=$(new_world g5)
  prepare_unmerged_reconcile "$w"
  fork=$(git -C "$w/main" rev-parse 'origin/main^')
  git -C "$w/main" update-ref refs/remotes/upstream/main "$fork"
  [ "$(git -C "$w/main" rev-parse refs/remotes/upstream/main)" = "$fork" ] \
    || fail "the cached upstream ref was not rewound"
  [ "$(git -C "$w/upstream.git" rev-parse refs/heads/main)" = "$RECONCILE_UPSTREAM" ] \
    || fail "the public upstream itself moved"
  out=$(run_upstream "$w" pr-guard \
    --repo-url "$(origin_url_of "$w")" \
    --pr-ref "refs/heads/$RECONCILE_BRANCH" \
    --head "$RECONCILE_HEAD" \
    --base main)
  rc=$?
  expect_code 0 "$rc" "a stale cached ref does not change the exit"
  assert_contains "$out" "upstream-guard: carries" "the fresh fetch still sees the upstream commits"
  assert_contains "$out" "upstream-carried-commits: 2" "the cached ref was not the comparison"
  pass "G5 pr-guard ignores a rewound cached upstream ref"
}

# --- G6: a head the pull-request ref cannot reach -------------------------
test_pr_guard_head_not_on_pr_ref_is_unknown() {
  local w out rc head side
  w=$(new_world g6)
  bump_private "$w" private.txt "private only"
  git -C "$w/main" checkout -q -b fm/ordinary-feature
  printf 'feature\n' > "$w/main/feature.txt"
  git -C "$w/main" add feature.txt
  git -C "$w/main" commit -qm "ordinary feature"
  git -C "$w/main" push -q origin fm/ordinary-feature
  git -C "$w/main" checkout -q main
  printf 'side\n' > "$w/main/side.txt"
  git -C "$w/main" add side.txt
  git -C "$w/main" commit -qm "not on the pull request"
  side=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" reset -q --hard HEAD~1
  head=$side
  out=$(run_upstream "$w" pr-guard \
    --repo-url "$(origin_url_of "$w")" \
    --pr-ref refs/heads/fm/ordinary-feature \
    --head "$head" \
    --base main)
  rc=$?
  expect_code 0 "$rc" "an unavailable head exits 0"
  assert_contains "$out" "upstream-guard: unknown: head $head is not available from refs/heads/fm/ordinary-feature" \
    "a commit the pull-request ref does not contain is unknown"
  assert_not_contains "$out" "upstream-guard: clear" "the unrelated commit is not judged clear"
  assert_not_contains "$out" "upstream-guard: carries" "the unrelated commit is not judged as the pull request"
  pass "G6 a head the pull-request ref does not contain is unknown"
}

# --- H1: the recorded 51-commit incident ----------------------------------
test_carried_reports_the_recorded_incident() {
  local head=43f0b705195989a748d70b94cce1c5aa84394ead
  local base=ad4c924551b0dc2f46292fbf8e4e61ae2ece66ab
  local upstream=427056c4181c41074ad24f051f79919330df0fa5
  local sha out rc home
  for sha in "$head" "$base" "$upstream"; do
    if ! git -C "$ROOT" cat-file -e "${sha}^{commit}" >/dev/null 2>&1; then
      printf 'skip: H1 incident commits are not in this clone\n'
      pass "H1 skipped: incident commits are not in this clone"
      return 0
    fi
  done
  home=$(mktemp -d "$TMP_ROOT/h1-home.XXXXXX")
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" "$UPSTREAM" carried "$head" "$base" "$upstream" 2>/dev/null)
  rc=$?
  expect_code 0 "$rc" "carried on the incident commits exits 0"
  assert_contains "$out" "upstream-carried-commits: 51" "the incident carried 51 upstream commits"
  assert_contains "$out" "upstream-carried-through: $upstream" "the carried tip is the upstream commit"
  pass "H1 carried reports the 51 commits of the recorded incident"
}

test_no_new_upstream
test_upstream_already_contained
test_reconcilable_divergence
test_conflicting_reconciliation_stops
test_missing_upstream_remote_degrades
test_missing_upstream_remote_reconcile_is_not_required
test_pushable_upstream_refuses
test_upstream_same_repo_as_origin_refuses
test_unreachable_upstream_degrades
test_unreachable_upstream_reconcile_is_not_required
test_landed_reconciliation_updates_the_home
test_cleanup_removes_worktree_keeps_branch
test_cleanup_refuses_uncommitted_work
test_invalid_inventory_refuses
test_invalid_inventory_refuses_reconciliation
test_invariants_precede_the_decision_line
test_merged_commit_count_is_truthful
test_incomplete_discard_is_reported
test_degraded_check_does_not_use_the_cached_upstream_ref
test_broken_invariant_has_its_own_exit_code
test_silent_fetch_failure_still_reports_a_reason
test_conflict_reports_a_kept_scratch
test_degraded_reports_a_distinct_unavailable_reason
test_missing_upstream_default_branch_degrades
test_non_conflicting_merge_failure_is_not_a_conflict
test_uncomputable_merge_base_reports_itself
test_pr_guard_carries_two_upstream_commits
test_pr_guard_ordinary_feature_is_clear
test_pr_guard_foreign_repo_does_not_fetch
test_pr_guard_unreachable_upstream_is_unknown
test_pr_guard_ignores_rewound_cached_upstream
test_pr_guard_head_not_on_pr_ref_is_unknown
test_carried_reports_the_recorded_incident

echo "# all fm-upstream tests passed"
