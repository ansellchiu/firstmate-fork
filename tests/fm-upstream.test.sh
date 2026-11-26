#!/usr/bin/env bash
# Tests for bin/fm-upstream.sh: the public-upstream check and the isolated
# reconciliation that precedes a private-origin self-update.
#
# The guarantees under test:
#   - Every invocation actually consults public upstream and reports the four
#     answers separately: no new upstream commits (current), upstream commits
#     already patch-equivalent to what origin carries (contained), upstream
#     content landed without its ancestry (ancestry-gap), and genuinely new
#     upstream commits (diverged).
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

test_guard_verbs_require_full_sha() {
  local w out rc rev head
  w=$(new_world full-sha)
  head=$(git -C "$w/main" rev-parse HEAD)
  for rev in refs/guard/head refs/guard/base HEAD "${head:0:12}" \
    "${head}0" "${head}00000000000000000000000" \
    "${head}0000000000000000000000000" \
    zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz ''; do
    out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPSTREAM" pr-guard --repo-url "$(origin_url_of "$w")" \
      --pr-ref refs/heads/main --head "$rev" --base main 2>&1)
    rc=$?
    expect_code 1 "$rc" "pr-guard rejects a non-full SHA: $rev"
    assert_contains "$out" "usage: fm-upstream.sh" "invalid head is usage"
    out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPSTREAM" pr-landed --through "$rev" --base main 2>&1)
    rc=$?
    expect_code 1 "$rc" "pr-landed rejects a non-full SHA: $rev"
    assert_contains "$out" "usage: fm-upstream.sh" "invalid through is usage"
  done
  for rev in 1111111111111111111111111111111111111111 \
    ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789; do
    out=$(run_upstream "$w" pr-guard --repo-url "$(origin_url_of "$w")" \
      --pr-ref refs/heads/main --head "$rev" --base main)
    rc=$?
    expect_code 0 "$rc" "a full hexadecimal head reaches availability checking"
    assert_contains "$out" "upstream-guard: unknown: head $rev" "a missing full head is unknown"
    out=$(run_upstream "$w" pr-landed --through "$rev" --base main)
    rc=$?
    expect_code 0 "$rc" "a full hexadecimal through reaches ancestry checking"
    assert_contains "$out" "upstream-ancestry: unknown: unresolvable $rev" "a missing full through is unknown"
  done
  pass "guard verbs require full hexadecimal SHAs"
}

test_pr_landed_verdicts() {
  local w out rc through real
  w=$(new_world landed)
  through=$(git -C "$w/main" rev-parse HEAD)
  out=$(run_upstream "$w" pr-landed --through "$through" --base main)
  rc=$?
  expect_code 0 "$rc" "landed exits 0"
  assert_equals "upstream-ancestry: landed" "$out" "origin contains the fork point"

  bump_upstream "$w" public.txt "public only"
  git -C "$w/main" fetch -q upstream
  through=$(upstream_tip "$w")
  out=$(run_upstream "$w" pr-landed --through "$through" --base main)
  rc=$?
  expect_code 0 "$rc" "lost exits 0"
  assert_equals "upstream-ancestry: lost" "$out" "origin lacks the locally available public commit"

  through=1111111111111111111111111111111111111111
  out=$(run_upstream "$w" pr-landed --through "$through" --base main)
  rc=$?
  expect_code 0 "$rc" "unresolvable exits 0"
  assert_equals "upstream-ancestry: unknown: unresolvable $through" "$out" "an absent object is not lost"

  real=$(command -v git)
  mkdir -p "$w/shim"
  cat > "$w/shim/git" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"merge-base --is-ancestor"*) exit 128 ;;
esac
exec "$real" "\$@"
SHIM
  chmod +x "$w/shim/git"
  through=$(git -C "$w/main" rev-parse HEAD)
  out=$(PATH="$w/shim:$PATH" run_upstream "$w" pr-landed --through "$through" --base main)
  rc=$?
  expect_code 0 "$rc" "fatal ancestry check exits 0"
  assert_equals "upstream-ancestry: unknown: unresolvable $through" "$out" "fatal errors never assert lost"

  git -C "$w/main" remote set-url origin "$w/does-not-exist.git"
  out=$(run_upstream "$w" pr-landed --through "$through" --base main)
  rc=$?
  expect_code 0 "$rc" "fetch failure exits 0"
  assert_equals "upstream-ancestry: unknown: origin refs unavailable" "$out" "fetch failure remains unknown"
  pass "pr-landed distinguishes landed, lost, unresolvable and fetch failure"
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

# --- L1-L6: upstream guard refusal ------------------------------------------
# The library refuses a carried or unchecked pull request before the forge
# sees it. These cases call that refusal directly.
GUARD_URL=https://github.com/example/repo/pull/69
GUARD_THROUGH=427056c4181c41074ad24f051f79919330df0fa5
GUARD_SQUASH_REFUSAL='error: refusing to merge https://github.com/example/repo/pull/69: it carries 51 public upstream commits (through 427056c4) and merge method "squash" would discard their ancestry; rerun with: -- --merge'
GUARD_REBASE_REFUSAL='error: refusing to merge https://github.com/example/repo/pull/69: it carries 51 public upstream commits (through 427056c4) and merge method "rebase" would discard their ancestry; rerun with: -- --merge'
GUARD_UNKNOWN_REFUSAL='error: refusing to merge https://github.com/example/repo/pull/69 with merge method "squash": could not prove it carries no public upstream commits (public upstream unreachable); rerun with: -- --merge, which is safe either way'
GUARD_AUTO_REFUSAL='error: refusing to merge https://github.com/example/repo/pull/69: it carries 51 public upstream commits and --auto can hand it to a merge queue that applies its own method; merge it synchronously with: -- --merge'

load_upstream_guard() {
  # shellcheck source=bin/fm-upstream-guard-lib.sh
  . "$ROOT/bin/fm-upstream-guard-lib.sh"
}

guard_set_carries() {
  FM_UPSTREAM_GUARD=carries
  FM_UPSTREAM_GUARD_COUNT=51
  FM_UPSTREAM_GUARD_THROUGH=$GUARD_THROUGH
  FM_UPSTREAM_GUARD_REASON=
}

run_guard_refuse() {
  local err_file=$1
  shift
  GUARD_RC=0
  fm_upstream_guard_refuse "$@" >"$err_file.out" 2>"$err_file" || GUARD_RC=$?
}

test_upstream_guard_refuses_squash_of_carried_commits() {
  local err="$TMP_ROOT/l1.err"
  load_upstream_guard
  guard_set_carries
  run_guard_refuse "$err" "$GUARD_URL" squash false
  expect_code 1 "$GUARD_RC" "L1 squash of carried commits"
  assert_equals "$GUARD_SQUASH_REFUSAL" "$(cat "$err")" "L1 stderr is the squash refusal"
  pass "L1 squash is refused when the pull request carries upstream commits"
}

test_upstream_guard_refuses_rebase_of_carried_commits() {
  local err="$TMP_ROOT/l2.err"
  load_upstream_guard
  guard_set_carries
  run_guard_refuse "$err" "$GUARD_URL" rebase false
  expect_code 1 "$GUARD_RC" "L2 rebase of carried commits"
  assert_equals "$GUARD_REBASE_REFUSAL" "$(cat "$err")" "L2 stderr is the rebase refusal"
  pass "L2 rebase is refused when the pull request carries upstream commits"
}

test_upstream_guard_allows_merge_of_carried_commits() {
  local method err
  load_upstream_guard
  for method in merge MERGE; do
    err="$TMP_ROOT/l3-$method.err"
    guard_set_carries
    run_guard_refuse "$err" "$GUARD_URL" "$method" false
    expect_code 0 "$GUARD_RC" "L3 method $method of carried commits"
    assert_equals "" "$(cat "$err")" "L3 method $method prints nothing"
    assert_equals "" "$(cat "$err.out")" "L3 method $method prints nothing on stdout"
  done
  pass "L3 a merge commit is allowed whether the method is spelled merge or MERGE"
}

test_upstream_guard_refuses_squash_when_check_is_unknown() {
  local err="$TMP_ROOT/l4.err"
  load_upstream_guard
  FM_UPSTREAM_GUARD=unknown
  FM_UPSTREAM_GUARD_COUNT=
  FM_UPSTREAM_GUARD_THROUGH=
  FM_UPSTREAM_GUARD_REASON="public upstream unreachable"
  run_guard_refuse "$err" "$GUARD_URL" squash false
  expect_code 1 "$GUARD_RC" "L4 squash when the guard is unknown"
  assert_equals "$GUARD_UNKNOWN_REFUSAL" "$(cat "$err")" "L4 stderr is the unknown refusal"
  pass "L4 squash is refused when upstream content could not be checked"
}

test_upstream_guard_allows_any_method_when_clear_or_not_applicable() {
  local verdict method err
  load_upstream_guard
  for verdict in clear not-applicable; do
    for method in squash rebase merge MERGE; do
      err="$TMP_ROOT/l5-$verdict-$method.err"
      FM_UPSTREAM_GUARD=$verdict
      FM_UPSTREAM_GUARD_COUNT=
      FM_UPSTREAM_GUARD_THROUGH=
      FM_UPSTREAM_GUARD_REASON=
      run_guard_refuse "$err" "$GUARD_URL" "$method" false
      expect_code 0 "$GUARD_RC" "L5 $verdict method $method"
      assert_equals "" "$(cat "$err")" "L5 $verdict method $method prints nothing"
      assert_equals "" "$(cat "$err.out")" "L5 $verdict method $method prints nothing on stdout"
    done
  done
  pass "L5 a clear or not-applicable pull request is merged by any method"
}

test_upstream_guard_refuses_auto_even_for_a_merge_commit() {
  local err="$TMP_ROOT/l6.err"
  load_upstream_guard
  guard_set_carries
  run_guard_refuse "$err" "$GUARD_URL" merge true
  expect_code 1 "$GUARD_RC" "L6 auto merge of carried commits"
  assert_equals "$GUARD_AUTO_REFUSAL" "$(cat "$err")" "L6 stderr is the auto refusal"
  pass "L6 --auto is refused when the pull request carries upstream commits"
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
test_guard_verbs_require_full_sha
test_pr_landed_verdicts
test_carried_reports_the_recorded_incident
test_upstream_guard_refuses_squash_of_carried_commits
test_upstream_guard_refuses_rebase_of_carried_commits
test_upstream_guard_allows_merge_of_carried_commits
test_upstream_guard_refuses_squash_when_check_is_unknown
test_upstream_guard_allows_any_method_when_clear_or_not_applicable
test_upstream_guard_refuses_auto_even_for_a_merge_commit

# --- Ancestry gap: verdict, reconcile refusal, repair ----------------------
# One contiguous block. A private commit always lands before the upstream
# change it is paired with, and a squash is a real merge on a reconcile-shaped
# branch followed by `git merge --squash` onto origin main.

# Merge upstream into a reconcile-shaped branch, push that branch, and squash
# it onto origin main. A conflict is resolved by taking upstream's side.
# Sets SQUASH_BRANCH and SQUASH_COMMIT. Leaves the reconcile branch in place.
squash_upstream_onto_origin() {
  local w=$1 path
  git -C "$w/main" fetch -q upstream
  SQUASH_BRANCH="fm/fm-upstream-reconcile-$(upstream_tip "$w")-s1"
  git -C "$w/main" checkout -q -b "$SQUASH_BRANCH"
  if ! git -C "$w/main" merge -q --no-ff upstream/main -m "reconcile upstream" >/dev/null 2>&1; then
    git -C "$w/main" diff --name-only --diff-filter=U | while IFS= read -r path; do
      [ -n "$path" ] || continue
      git -C "$w/main" checkout --theirs -- "$path" 2>/dev/null \
        || git -C "$w/main" rm -q -- "$path"
      git -C "$w/main" add -- "$path"
    done
    git -C "$w/main" add -A
    git -C "$w/main" commit -qm "reconcile upstream" \
      || fail "fixture could not commit the conflict resolution"
  fi
  git -C "$w/main" push -q origin "$SQUASH_BRANCH"
  git -C "$w/main" checkout -q main
  git -C "$w/main" merge -q --squash "$SQUASH_BRANCH" >/dev/null 2>&1 \
    || fail "fixture squash did not apply"
  git -C "$w/main" commit -qm "squash upstream reconciliation" \
    || fail "fixture squash commit failed"
  git -C "$w/main" push -q origin main
  SQUASH_COMMIT=$(git -C "$w/main" rev-parse HEAD)
}

# The private commit every gap fixture needs before upstream moves.
private_first() {
  bump_private "$1" private.txt "private only"
}

# Two public commits, so a later squash is not patch-equivalent to one of them.
two_upstream_commits() {
  local w=$1
  bump_upstream "$w" docs/u1.txt "one" "public-one"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
}

assert_no_gap_lines() {
  local out=$1 why=$2
  assert_not_contains "$out" "upstream-ancestry-gap-" "$why"
}

# reconcile and repair must not have created their own branch or worktree.
# The fixture's fm/fm-upstream-reconcile-* branch is not one of those names.
assert_no_repair_scratch() {
  local w=$1
  [ -z "$(git -C "$w/main" branch --list 'fm/upstream-reconcile-*' 'fm/upstream-ancestry-repair-*')" ] \
    || fail "a reconcile or repair branch was created in $w"
  [ ! -d "$w/home/state/upstream-reconcile" ] \
    || fail "a reconcile or repair worktree was created in $w"
}

test_ancestry_v0_squash_after_conflict_is_a_gap() {
  local w out rc
  w=$(new_world v0)
  bump_private "$w" core.txt "private version of the contended line"
  bump_upstream "$w" core.txt "public version of the contended line" "public-contended"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  squash_upstream_onto_origin "$w"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V0 check exits 0"
  assert_contains "$out" "upstream-status: ancestry-gap" "a resolved squash is an ancestry gap"
  assert_contains "$out" "upstream-ancestry-gap-proof: tip" "the squash still matches the tip"
  assert_contains "$out" "upstream-new-commits: 0" "nothing upstream is new after the squashed tip"
  assert_contains "$out" "reconcile-required: no" "a pure gap does not ask for reconcile"
  assert_contains "$out" "ancestry-repair: bin/fm-upstream.sh repair-ancestry" "the repair command is named"
  pass "V0 a squash after conflict resolution is an ancestry gap with nothing new"
}

test_ancestry_v1_genuine_divergence_is_not_a_gap() {
  local w out rc
  w=$(new_world v1)
  private_first "$w"
  bump_upstream "$w" core.txt "public edit only" "public-edit"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V1 check exits 0"
  assert_contains "$out" "upstream-status: diverged" "an unlanded upstream edit diverges"
  assert_no_gap_lines "$out" "genuine divergence is not reported as a gap"
  assert_contains "$out" "reconcile-required: yes" "genuine divergence still asks for reconcile"
  pass "V1 genuine divergence is diverged, not an ancestry gap"
}

test_ancestry_v1b_upstream_deletion_is_not_a_gap() {
  local w out rc
  w=$(new_world v1b)
  private_first "$w"
  git -C "$w/pub" pull -q origin main
  git -C "$w/pub" rm -q core.txt
  git -C "$w/pub" commit -qm "public deletes core"
  git -C "$w/pub" push -q origin main
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V1b check exits 0"
  assert_contains "$out" "upstream-status: diverged" "an unlanded upstream deletion diverges"
  assert_no_gap_lines "$out" "an upstream deletion is not reported as a gap"
  assert_contains "$out" "reconcile-required: yes" "the deletion still asks for reconcile"
  pass "V1b an upstream deletion is diverged, not an ancestry gap"
}

test_ancestry_v2_partial_squash_counts_only_what_is_new() {
  local w out rc
  w=$(new_world v2)
  private_first "$w"
  bump_upstream "$w" docs/u1.txt "one" "public-one"
  squash_upstream_onto_origin "$w"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V2 check exits 0"
  assert_contains "$out" "upstream-status: ancestry-gap" "the squashed half is a gap"
  assert_contains "$out" "upstream-ancestry-gap-commits: 1" "only the squashed commit is the gap"
  assert_contains "$out" "upstream-new-commits: 1" "the later upstream commit is still new"
  assert_contains "$out" "reconcile-required: after-ancestry-repair" \
    "new commits after a gap wait for the repair"
  pass "V2 a partial squash reports the gap and the one commit after it"
}

test_ancestry_v3_private_deletion_then_squash_is_a_gap() {
  local w out rc
  w=$(new_world v3)
  git -C "$w/main" rm -q core.txt
  git -C "$w/main" commit -qm "private deletion"
  git -C "$w/main" push -q origin main
  two_upstream_commits "$w"
  squash_upstream_onto_origin "$w"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V3 check exits 0"
  assert_contains "$out" "upstream-status: ancestry-gap" "a squash after a private deletion is a gap"
  pass "V3 a private deletion followed by a two-commit squash is an ancestry gap"
}

test_ancestry_v3b_deletion_of_an_upstream_edit_is_a_gap() {
  local w out rc
  w=$(new_world v3b)
  git -C "$w/main" rm -q core.txt
  git -C "$w/main" commit -qm "private deletion of core"
  git -C "$w/main" push -q origin main
  bump_upstream "$w" core.txt "public rewrote core" "public-rewrote-core"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  squash_upstream_onto_origin "$w"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V3b check exits 0"
  assert_contains "$out" "upstream-status: ancestry-gap" \
    "squashing a resolved deletion of an upstream edit is a gap"
  pass "V3b deleting a file upstream edited, then squashing, is an ancestry gap"
}

test_ancestry_v4_cherry_pick_stays_contained() {
  local w out rc sha
  w=$(new_world v4)
  private_first "$w"
  bump_upstream "$w" public.txt "public only" "public-only"
  sha=$(upstream_tip "$w")
  reapply_privately "$w" "$sha"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V4 check exits 0"
  assert_contains "$out" "upstream-status: contained" "a cherry-pick is contained"
  assert_no_gap_lines "$out" "contained keeps precedence over a gap"
  pass "V4 cherry-picked upstream commits stay contained"
}

test_ancestry_v4b_rebase_onto_upstream_is_current() {
  local w out rc
  w=$(new_world v4b)
  private_first "$w"
  bump_upstream "$w" public.txt "public only" "public-only"
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" rebase -q upstream/main
  git -C "$w/main" push -q --force origin main
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V4b check exits 0"
  assert_contains "$out" "upstream-status: current" "a rebase onto upstream is current"
  pass "V4b a fork rebased onto upstream is current"
}

test_ancestry_v5_real_merge_is_current() {
  local w out rc
  w=$(new_world v5)
  private_first "$w"
  bump_upstream "$w" public.txt "public only" "public-only"
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" merge -q --no-ff upstream/main -m "merge upstream"
  git -C "$w/main" push -q origin main
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V5 check exits 0"
  assert_contains "$out" "upstream-status: current" "a real merge commit is current"
  pass "V5 a real merge commit is current"
}

test_ancestry_v6_private_revert_is_a_squash_proof() {
  local w out rc
  w=$(new_world v6)
  private_first "$w"
  git -C "$w/pub" pull -q origin main
  printf 'keep\nupstream-hunk\n' > "$w/pub/other.txt"
  git -C "$w/pub" add other.txt
  git -C "$w/pub" commit -qm "public other"
  git -C "$w/pub" push -q origin main
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  squash_upstream_onto_origin "$w"
  printf 'keep\nprivate-revert\n' > "$w/main/other.txt"
  git -C "$w/main" add other.txt
  git -C "$w/main" commit -qm "revert the upstream hunk"
  git -C "$w/main" push -q origin main
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V6 check exits 0"
  assert_contains "$out" "upstream-status: ancestry-gap" "a reverted hunk is still a gap"
  assert_contains "$out" "upstream-ancestry-gap-proof: squash" "the proof is the squash anchor"
  pass "V6 a private revert after a squash is an ancestry gap proved at the squash"
}

test_ancestry_v7_later_edit_anchors_on_the_squash() {
  local w out rc
  w=$(new_world v7)
  private_first "$w"
  two_upstream_commits "$w"
  squash_upstream_onto_origin "$w"
  printf 'edited after the squash\n' > "$w/main/docs/u1.txt"
  git -C "$w/main" add docs/u1.txt
  git -C "$w/main" commit -qm "edit an upstream-added file"
  git -C "$w/main" push -q origin main
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V7 check exits 0"
  assert_contains "$out" "upstream-status: ancestry-gap" "a later edit does not hide the gap"
  assert_contains "$out" "upstream-ancestry-gap-proof: squash $SQUASH_COMMIT" \
    "the anchor is the squash commit"
  pass "V7 a later edit of an upstream-added file anchors the proof on the squash"
}

test_ancestry_v8_unmerged_reconcile_branch_is_diverged() {
  local w out rc
  w=$(new_world v8)
  prepare_unmerged_reconcile "$w"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V8 check exits 0"
  assert_contains "$out" "upstream-status: diverged" "an unmerged reconcile branch is not a gap"
  assert_contains "$out" "reconcile-required: yes" "the unmerged upstream commits are still owed"
  assert_no_gap_lines "$out" "a branch that was not landed does not prove a gap"
  pass "V8 a reconcile branch that was not merged stays diverged"
}

test_ancestry_v9_contribution_branch_is_diverged() {
  local w out rc
  w=$(new_world v9)
  private_first "$w"
  two_upstream_commits "$w"
  git -C "$w/main" fetch -q upstream
  git -C "$w/main" checkout -q -b contrib upstream/main
  printf 'contribution\n' > "$w/main/contrib.txt"
  git -C "$w/main" add contrib.txt
  git -C "$w/main" commit -qm "contribution from upstream"
  git -C "$w/main" push -q origin contrib
  git -C "$w/main" checkout -q main
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V9 check exits 0"
  assert_contains "$out" "upstream-status: diverged" "a contribution branch is not a gap"
  assert_no_gap_lines "$out" "a branch forked from upstream does not prove a gap"
  pass "V9 an upstream-based contribution branch stays diverged"
}

test_ancestry_v10_deleted_candidate_is_diverged() {
  local w out rc
  w=$(new_world v10)
  private_first "$w"
  two_upstream_commits "$w"
  squash_upstream_onto_origin "$w"
  git -C "$w/main" push -q origin --delete "$SQUASH_BRANCH"
  git -C "$w/main" branch -D "$SQUASH_BRANCH" >/dev/null
  git -C "$w/main" update-ref -d "refs/remotes/origin/$SQUASH_BRANCH"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V10 check exits 0"
  assert_contains "$out" "upstream-status: diverged" "a squash with no surviving candidate stays diverged"
  assert_no_gap_lines "$out" "no candidate means no gap"
  pass "V10 deleting the squashed branch leaves an honest divergence"
}

test_ancestry_v11_candidate_fetch_failure_uses_local_refs() {
  local w out rc
  w=$(new_world v11)
  private_first "$w"
  two_upstream_commits "$w"
  squash_upstream_onto_origin "$w"
  git -C "$w/main" remote set-url origin "$w/does-not-exist.git"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V11 check exits 0"
  assert_contains "$out" "upstream-ancestry-candidates: local-only:" \
    "a failed candidate fetch is reported and is not fatal"
  assert_contains "$out" "upstream-status: ancestry-gap" "the local branch still proves the gap"
  pass "V11 a failed candidate fetch still proves the gap from local refs"
}

test_ancestry_v12_zero_scan_limit_hides_the_squash_proof() {
  local w out rc
  w=$(new_world v12)
  private_first "$w"
  two_upstream_commits "$w"
  squash_upstream_onto_origin "$w"
  printf 'edited after the squash\n' > "$w/main/docs/u1.txt"
  git -C "$w/main" add docs/u1.txt
  git -C "$w/main" commit -qm "edit an upstream-added file"
  git -C "$w/main" push -q origin main
  out=$(FM_UPSTREAM_GAP_SCAN_LIMIT=0 run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "V12 check exits 0"
  assert_contains "$out" "upstream-status: diverged" "a zero scan limit cannot prove the squash"
  assert_no_gap_lines "$out" "the scan limit is honoured"
  pass "V12 a zero scan limit leaves the post-squash edit diverged"
}

test_ancestry_r1_reconcile_refuses_a_pure_gap() {
  local w out rc
  w=$(new_world r1)
  bump_private "$w" core.txt "private version of the contended line"
  bump_upstream "$w" core.txt "public version of the contended line" "public-contended"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  squash_upstream_onto_origin "$w"
  out=$(run_upstream "$w" reconcile)
  rc=$?
  expect_code 7 "$rc" "R1 reconcile refuses an ancestry gap"
  assert_contains "$out" "reconcile: refused: ancestry-gap through" "the refusal names the gap"
  assert_no_repair_scratch "$w"
  pass "R1 reconcile refuses a pure ancestry gap and creates nothing"
}

test_ancestry_r2_reconcile_refuses_a_partial_gap() {
  local w out rc
  w=$(new_world r2)
  private_first "$w"
  bump_upstream "$w" docs/u1.txt "one" "public-one"
  squash_upstream_onto_origin "$w"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  out=$(run_upstream "$w" reconcile)
  rc=$?
  expect_code 7 "$rc" "R2 reconcile refuses when commits remain after the gap"
  assert_contains "$out" "reconcile: refused: ancestry-gap through" "the partial gap is still a refusal"
  pass "R2 reconcile refuses a gap that still has new upstream commits"
}

test_ancestry_r3_real_divergence_requires_a_merge_commit() {
  local w out rc ready_at tip_at method_at tip
  w=$(new_world r3)
  private_first "$w"
  bump_upstream "$w" core.txt "public edit only" "public-edit"
  tip=$(upstream_tip "$w")
  out=$(run_upstream "$w" reconcile)
  rc=$?
  expect_code 0 "$rc" "R3 reconcile of a real divergence exits 0"
  assert_contains "$out" "reconcile: ready" "the reconciliation is ready"
  assert_contains "$out" "merge-method-required: merge" "the ready branch must land as a merge"
  assert_contains "$out" "reconcile-upstream-tip: $tip" "the upstream tip being merged is named"
  ready_at=$(printf '%s\n' "$out" | grep -n '^reconcile: ready$' | cut -d: -f1)
  tip_at=$(printf '%s\n' "$out" | grep -n '^reconcile-upstream-tip: ' | cut -d: -f1)
  method_at=$(printf '%s\n' "$out" | grep -n '^merge-method-required: merge$' | cut -d: -f1)
  [ -n "$ready_at" ] && [ -n "$tip_at" ] && [ -n "$method_at" ] \
    || fail "R3 did not print the ready line and both predecessors"
  [ "$tip_at" -eq $((ready_at - 2)) ] && [ "$method_at" -eq $((ready_at - 1)) ] \
    || fail "R3 did not print the upstream tip and merge method immediately before ready"
  pass "R3 a real divergence is ready only as a merge commit"
}

test_ancestry_r4_repair_is_not_required_when_diverged() {
  local w out rc
  w=$(new_world r4)
  private_first "$w"
  bump_upstream "$w" core.txt "public edit only" "public-edit"
  out=$(run_upstream "$w" repair-ancestry)
  rc=$?
  expect_code 0 "$rc" "R4 repair of a real divergence exits 0"
  assert_contains "$out" "repair: not-required: upstream is diverged" \
    "repair declines when the comparison is a real divergence"
  assert_no_repair_scratch "$w"
  pass "R4 repair-ancestry is not required for a real divergence"
}

test_ancestry_p1_dry_run_creates_nothing() {
  local w out rc
  w=$(new_world p1)
  bump_private "$w" core.txt "private version of the contended line"
  bump_upstream "$w" core.txt "public version of the contended line" "public-contended"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  squash_upstream_onto_origin "$w"
  out=$(run_upstream "$w" repair-ancestry --dry-run)
  rc=$?
  expect_code 0 "$rc" "P1 dry-run exits 0"
  assert_contains "$out" "repair: dry-run" "dry-run stops before creating a branch"
  assert_no_repair_scratch "$w"
  pass "P1 repair-ancestry --dry-run reports the gap and creates nothing"
}

test_ancestry_p2_repair_records_ancestry_without_changing_the_tree() {
  local w out rc before branch origin_tree repair_tree parents upstream
  w=$(new_world p2)
  bump_private "$w" core.txt "private version of the contended line"
  bump_upstream "$w" core.txt "public version of the contended line" "public-contended"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  squash_upstream_onto_origin "$w"
  before=$(git -C "$w/main" rev-parse HEAD)
  upstream=$(upstream_tip "$w")
  out=$(run_upstream "$w" repair-ancestry)
  rc=$?
  expect_code 0 "$rc" "P2 repair exits 0"
  assert_contains "$out" "repair: ready" "the repair is ready"
  assert_contains "$out" "repair-tree: unchanged" "the repair claims an unchanged tree"
  assert_contains "$out" "active-checkout: unchanged" "the active checkout was proved unchanged"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "P2 moved the active checkout"
  branch=$(printf '%s\n' "$out" | sed -n 's/^repair-branch: //p' | head -n 1)
  [ -n "$branch" ] || fail "P2 did not name the repair branch"
  origin_tree=$(git -C "$w/main" rev-parse 'origin/main^{tree}')
  repair_tree=$(git -C "$w/main" rev-parse "$branch^{tree}")
  [ "$repair_tree" = "$origin_tree" ] || fail "P2 repair tree differs from origin/main"
  parents=$(git -C "$w/main" rev-parse "$branch^@")
  [ "$(printf '%s\n' "$parents" | grep -c .)" -eq 2 ] \
    || fail "P2 repair commit does not have two parents"
  git -C "$w/main" merge-base --is-ancestor "$upstream" "$branch" \
    || fail "P2 upstream tip is not an ancestor of the repair"
  pass "P2 repair records the upstream parent and leaves the tree unchanged"
}

test_ancestry_p3_repair_keeps_a_private_revert_and_becomes_current() {
  local w out rc branch line
  w=$(new_world p3)
  private_first "$w"
  git -C "$w/pub" pull -q origin main
  printf 'keep\nupstream-hunk\n' > "$w/pub/other.txt"
  git -C "$w/pub" add other.txt
  git -C "$w/pub" commit -qm "public other"
  git -C "$w/pub" push -q origin main
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  squash_upstream_onto_origin "$w"
  printf 'keep\nprivate-revert\n' > "$w/main/other.txt"
  git -C "$w/main" add other.txt
  git -C "$w/main" commit -qm "revert the upstream hunk"
  git -C "$w/main" push -q origin main
  out=$(run_upstream "$w" repair-ancestry)
  rc=$?
  expect_code 0 "$rc" "P3 repair exits 0"
  assert_contains "$out" "repair: ready" "the revert fixture repairs"
  branch=$(printf '%s\n' "$out" | sed -n 's/^repair-branch: //p' | head -n 1)
  git -C "$w/main" push -q origin "$branch:main"
  git -C "$w/main" fetch -q origin main
  line=$(git -C "$w/main" show 'origin/main:other.txt')
  assert_contains "$line" "private-revert" "the private revert survives the repair"
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "P3 check after landing exits 0"
  assert_contains "$out" "upstream-status: current" "landing the repair makes upstream current"
  pass "P3 a landed repair keeps the private revert and reports current"
}

test_ancestry_p4_landed_partial_repair_leaves_the_new_commit() {
  local w out rc branch
  w=$(new_world p4)
  private_first "$w"
  bump_upstream "$w" docs/u1.txt "one" "public-one"
  squash_upstream_onto_origin "$w"
  bump_upstream "$w" docs/u2.txt "two" "public-two"
  out=$(run_upstream "$w" repair-ancestry)
  rc=$?
  expect_code 0 "$rc" "P4 repair exits 0"
  assert_contains "$out" "repair: ready" "the partial gap repairs"
  branch=$(printf '%s\n' "$out" | sed -n 's/^repair-branch: //p' | head -n 1)
  git -C "$w/main" push -q origin "$branch:main"
  git -C "$w/main" fetch -q origin main
  out=$(run_upstream "$w" check)
  rc=$?
  expect_code 0 "$rc" "P4 check after landing exits 0"
  assert_contains "$out" "upstream-status: diverged" "the commit after the gap is still divergence"
  assert_contains "$out" "upstream-new-commits: 1" "exactly one upstream commit remains new"
  assert_no_gap_lines "$out" "landing the repair clears the gap"
  pass "P4 landing a partial repair leaves the one genuinely new commit"
}

test_ancestry_v0_squash_after_conflict_is_a_gap
test_ancestry_v1_genuine_divergence_is_not_a_gap
test_ancestry_v1b_upstream_deletion_is_not_a_gap
test_ancestry_v2_partial_squash_counts_only_what_is_new
test_ancestry_v3_private_deletion_then_squash_is_a_gap
test_ancestry_v3b_deletion_of_an_upstream_edit_is_a_gap
test_ancestry_v4_cherry_pick_stays_contained
test_ancestry_v4b_rebase_onto_upstream_is_current
test_ancestry_v5_real_merge_is_current
test_ancestry_v6_private_revert_is_a_squash_proof
test_ancestry_v7_later_edit_anchors_on_the_squash
test_ancestry_v8_unmerged_reconcile_branch_is_diverged
test_ancestry_v9_contribution_branch_is_diverged
test_ancestry_v10_deleted_candidate_is_diverged
test_ancestry_v11_candidate_fetch_failure_uses_local_refs
test_ancestry_v12_zero_scan_limit_hides_the_squash_proof
test_ancestry_r1_reconcile_refuses_a_pure_gap
test_ancestry_r2_reconcile_refuses_a_partial_gap
test_ancestry_r3_real_divergence_requires_a_merge_commit
test_ancestry_r4_repair_is_not_required_when_diverged
test_ancestry_p1_dry_run_creates_nothing
test_ancestry_p2_repair_records_ancestry_without_changing_the_tree
test_ancestry_p3_repair_keeps_a_private_revert_and_becomes_current
test_ancestry_p4_landed_partial_repair_leaves_the_new_commit

# The proving commit exists only as refs/pull/*/head on origin. It is not a
# local branch and not an origin-tracking ref, and the clone has been pruned
# so the object is absent until repair copies it out of the scratch fetch.
test_ancestry_repair_imports_a_pull_request_candidate() {
  local w out rc cand parents
  w=$(new_world pull-only)
  private_first "$w"
  two_upstream_commits "$w"
  squash_upstream_onto_origin "$w"
  cand=$(git -C "$w/main" rev-parse "$SQUASH_BRANCH")
  git -C "$w/origin.git" update-ref refs/pull/7/head "$cand"
  git -C "$w/main" push -q origin --delete "$SQUASH_BRANCH"
  git -C "$w/main" branch -D "$SQUASH_BRANCH" >/dev/null
  git -C "$w/main" update-ref -d "refs/remotes/origin/$SQUASH_BRANCH"
  git -C "$w/main" reflog expire --expire=now --all
  git -C "$w/main" gc --prune=now >/dev/null 2>&1
  if git -C "$w/main" cat-file -e "${cand}^{commit}" >/dev/null 2>&1; then
    fail "the pull-request candidate was still in the clone"
  fi
  git -C "$w/origin.git" cat-file -e "${cand}^{commit}" >/dev/null 2>&1 \
    || fail "origin lost the pull-request head"
  out=$(run_upstream "$w" repair-ancestry)
  rc=$?
  expect_code 0 "$rc" "repair of a pull-request-only candidate exits 0"
  assert_contains "$out" "repair: ready" "a candidate that existed only on a pull ref still repairs"
  assert_contains "$out" "repair-parents: $(git -C "$w/main" rev-parse 'origin/main') $cand" \
    "the imported commit is the repair's second parent"
  parents=$(git -C "$w/main" rev-parse "$(printf '%s\n' "$out" | sed -n 's/^repair-branch: //p' | head -n 1)^@")
  assert_contains "$parents" "$cand" "the repair commit records the pull-request candidate"
  pass "repair imports a candidate that exists only as a pull-request head"
}

test_ancestry_repair_imports_a_pull_request_candidate

echo "# all fm-upstream tests passed"
