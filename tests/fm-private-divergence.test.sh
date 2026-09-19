#!/usr/bin/env bash
# Tests for bin/fm-private-divergence.sh: the inventory of intentional
# firstmate-private divergence from public Firstmate core.
#
# The guarantees under test:
#   - A missing or schema-invalid inventory is a hard failure, because an
#     unparseable inventory answers nothing.
#   - Findings are REPORTED, never dropped: a stale path, unresolved provenance,
#     an unreviewed upstream change, an unconfirmed equivalence claim, and a
#     needs-review disposition each surface as their own line with
#     `inventory: attention`, and still exit 0 so a caller can act on them.
#   - Uncovered drift comes from git, not from the file: a path both sides
#     changed since they diverged, that still differs between them, and that no
#     entry claims, is reported - so a missing entry cannot stay quiet.
#   - A path that has converged on both sides is not reported as contended.
#   - A comparison that could not run answers nothing: it never contradicts an
#     entry's equivalence claim.
#   - --refresh-reviewed records a review point, and that recorded point is what
#     silences an entry until upstream moves again.
#   - The inventory this repo actually ships is schema-valid.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIVERGENCE="$ROOT/bin/fm-private-divergence.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-private-divergence-tests)

# A repo that forked from a public upstream: base commit, then a private branch
# and a public branch that each moved. Echoes the repo dir.
new_repo() {
  local name=$1 r
  r="$TMP_ROOT/$name"
  mkdir -p "$r/docs"
  git init -q "$r"
  git -C "$r" symbolic-ref HEAD refs/heads/main
  printf 'core\n' > "$r/core.txt"
  printf 'shared\n' > "$r/shared.txt"
  printf 'converged\n' > "$r/converged.txt"
  git -C "$r" add -A
  git -C "$r" commit -qm base
  git -C "$r" branch public
  printf '%s\n' "$r"
}

write_inventory() {
  local repo=$1
  shift
  {
    printf '{ "version": 1, "entries": ['
    printf '%s' "$*"
    printf '] }\n'
  } > "$repo/docs/private-divergence.json"
}

entry() {
  # entry <id> <paths-json> <commits-json> <upstreamEquivalent> <disposition> [reviewedAt]
  local reviewed=""
  [ -n "${6:-}" ] && reviewed=", \"upstreamReviewedAt\": \"$6\""
  printf '{"id":"%s","area":"a","paths":%s,"intent":"i","provenance":{"commits":%s},"upstreamEquivalent":"%s","disposition":"%s"%s}' \
    "$1" "$2" "$3" "$4" "$5" "$reviewed"
}

run_check() {
  local repo=$1
  shift
  "$DIVERGENCE" --root "$repo" "$@" 2>&1
}

# --- T1: a missing inventory is a hard failure -----------------------------
test_missing_inventory_fails() {
  local repo out rc
  repo=$(new_repo t1)

  out=$(run_check "$repo")
  rc=$?

  expect_code 1 "$rc" "a missing inventory fails hard"
  assert_contains "$out" "inventory: invalid: inventory not found" "the missing file is named"
  pass "T1 a missing inventory is a hard failure"
}

# --- T2: schema errors fail hard, one deterministic reason each -------------
test_schema_errors_fail_hard() {
  local repo out rc
  repo=$(new_repo t2)

  write_inventory "$repo" "$(entry good '["core.txt"]' '["abcdef0"]' none retain)," \
    "$(entry good '["core.txt"]' '["abcdef0"]' none retain)"
  out=$(run_check "$repo")
  rc=$?
  expect_code 1 "$rc" "a duplicate id fails hard"
  assert_contains "$out" "duplicate entry id good" "the duplicate id is named"

  write_inventory "$repo" "$(entry ok-id '["core.txt"]' '["abcdef0"]' maybe retain)"
  out=$(run_check "$repo")
  expect_code 1 "$?" "an unknown upstreamEquivalent fails hard"
  assert_contains "$out" "upstreamEquivalent must be one of" "the enum is named"

  write_inventory "$repo" "$(entry ok-id '[]' '["abcdef0"]' none retain)"
  out=$(run_check "$repo")
  expect_code 1 "$?" "an entry with no paths fails hard"
  assert_contains "$out" "paths must be a non-empty list" "the empty path list is named"

  write_inventory "$repo" "$(entry Bad_Id '["core.txt"]' '["abcdef0"]' none retain)"
  out=$(run_check "$repo")
  expect_code 1 "$?" "a non-kebab id fails hard"
  assert_contains "$out" "id must be kebab-case" "the id format is named"
  pass "T2 schema errors fail hard with a deterministic reason"
}

# --- T3: a clean inventory reports ok --------------------------------------
test_clean_inventory_is_ok() {
  local repo out sha
  repo=$(new_repo t3)
  sha=$(git -C "$repo" rev-parse HEAD)
  write_inventory "$repo" "$(entry core-behavior '["core.txt"]' "[\"$sha\"]" none retain)"

  out=$(run_check "$repo")

  expect_code 0 "$?" "a clean inventory exits 0"
  assert_contains "$out" "inventory: ok" "a clean inventory is ok"
  assert_contains "$out" "inventory-entry: core-behavior ok" "the entry is clean"
  assert_contains "$out" "inventory-entries: 1" "the entry count is reported"
  pass "T3 a clean inventory reports ok"
}

# --- T4: stale paths and unresolved provenance are reported, not dropped ----
test_stale_and_unresolved_are_reported() {
  local repo out rc
  repo=$(new_repo t4)
  write_inventory "$repo" "$(entry gone '["no-such-file.txt"]' '["0000000"]' none retain)"

  out=$(run_check "$repo")
  rc=$?

  expect_code 0 "$rc" "findings are reported, not raised as failures"
  assert_contains "$out" "inventory: attention" "findings raise attention"
  assert_contains "$out" "inventory-entry: gone stale-paths: no-such-file.txt" "the stale path is named"
  assert_contains "$out" "inventory-entry: gone unresolved-provenance: 0000000" "the missing commit is named"
  pass "T4 stale paths and unresolved provenance are reported"
}

# --- T5: dispositions that need a human are surfaced -----------------------
test_dispositions_are_surfaced() {
  local repo out sha
  repo=$(new_repo t5)
  sha=$(git -C "$repo" rev-parse HEAD)
  write_inventory "$repo" \
    "$(entry needs-a-look '["core.txt"]' "[\"$sha\"]" unknown needs-review)," \
    "$(entry on-its-way-out '["shared.txt"]' "[\"$sha\"]" present superseded)"

  out=$(run_check "$repo")

  assert_contains "$out" "inventory: attention" "open dispositions raise attention"
  assert_contains "$out" "inventory-entry: needs-a-look needs-review" "needs-review is surfaced"
  assert_contains "$out" "inventory-entry: on-its-way-out superseded: " "superseded is surfaced with its instruction"
  pass "T5 dispositions that need a human decision are surfaced"
}

# --- T6: uncovered drift is computed from git ------------------------------
# Both sides change shared.txt and converged.txt; only converged.txt ends up
# identical on both sides. An entry claims core.txt but nothing claims
# shared.txt, so shared.txt - and only shared.txt - is uncovered.
test_uncovered_drift_comes_from_git() {
  local repo out base sha
  repo=$(new_repo t6)
  base=$(git -C "$repo" rev-parse HEAD)

  git -C "$repo" checkout -q public
  printf 'public shared\n' > "$repo/shared.txt"
  printf 'both agree\n' > "$repo/converged.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm public-change

  git -C "$repo" checkout -q main
  printf 'private core\n' > "$repo/core.txt"
  printf 'private shared\n' > "$repo/shared.txt"
  printf 'both agree\n' > "$repo/converged.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm private-change
  sha=$(git -C "$repo" rev-parse HEAD)
  write_inventory "$repo" "$(entry core-behavior '["core.txt"]' "[\"$sha\"]" none retain)"

  out=$(run_check "$repo" --base "$base" --head main --upstream public)

  assert_contains "$out" "inventory: attention" "uncovered drift raises attention"
  assert_contains "$out" "inventory-contended: shared.txt" "the contended path is reported"
  assert_contains "$out" "inventory-uncovered: shared.txt" "the unclaimed contended path is uncovered"
  assert_contains "$out" "inventory-uncovered-count: 1" "exactly one path is uncovered"
  assert_not_contains "$out" "inventory-uncovered: core.txt" "a claimed path is not uncovered"
  assert_not_contains "$out" "converged.txt" "a path both sides converged on is not contended"
  pass "T6 uncovered drift is computed from git, not from the file"
}

# --- T7: unreviewed upstream work resurfaces until reviewed ----------------
test_upstream_review_point_gates_resurfacing() {
  local repo out base public_sha sha
  repo=$(new_repo t7)
  base=$(git -C "$repo" rev-parse HEAD)

  git -C "$repo" checkout -q public
  printf 'public core\n' > "$repo/core.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm public-change
  public_sha=$(git -C "$repo" rev-parse HEAD)

  git -C "$repo" checkout -q main
  printf 'private core\n' > "$repo/core.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm private-change
  sha=$(git -C "$repo" rev-parse HEAD)
  write_inventory "$repo" "$(entry core-behavior '["core.txt"]' "[\"$sha\"]" none retain)"

  out=$(run_check "$repo" --base "$base" --head main --upstream public)
  assert_contains "$out" "inventory-entry: core-behavior upstream-unreviewed-change: core.txt" \
    "unreviewed upstream work on a claimed path resurfaces"

  out=$("$DIVERGENCE" --root "$repo" --refresh-reviewed "$public_sha" --entry core-behavior 2>&1)
  expect_code 0 "$?" "recording a review succeeds"
  assert_contains "$out" "inventory-refreshed: " "the review point is recorded"

  out=$(run_check "$repo" --base "$base" --head main --upstream public)
  assert_contains "$out" "inventory-entry: core-behavior ok" "a reviewed entry stops resurfacing"

  # Upstream moves again on the same path: the entry resurfaces.
  git -C "$repo" checkout -q public
  printf 'public core again\n' > "$repo/core.txt"
  git -C "$repo" add core.txt
  git -C "$repo" commit -qm public-change-2
  git -C "$repo" checkout -q main

  out=$(run_check "$repo" --base "$base" --head main --upstream public)
  assert_contains "$out" "inventory-entry: core-behavior upstream-unreviewed-change: core.txt" \
    "new upstream work after the review point resurfaces the entry"
  pass "T7 the recorded review point gates when an entry resurfaces"
}

# --- T8: an unconfirmed equivalence claim is challenged --------------------
test_unconfirmed_equivalence_is_challenged() {
  local repo out base sha
  repo=$(new_repo t8)
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q public
  printf 'public elsewhere\n' > "$repo/shared.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm public-change
  git -C "$repo" checkout -q main
  printf 'private core\n' > "$repo/core.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm private-change
  sha=$(git -C "$repo" rev-parse HEAD)
  # Claims upstream now carries this, while upstream never touched core.txt.
  write_inventory "$repo" "$(entry claimed '["core.txt"]' "[\"$sha\"]" present retain "$sha")"

  out=$(run_check "$repo" --base "$base" --head main --upstream public)

  assert_contains "$out" "inventory-entry: claimed upstream-equivalent-unconfirmed" \
    "an unsupported equivalence claim is challenged"
  pass "T8 an unconfirmed upstream-equivalence claim is challenged"
}

# --- T9: drift comparison degrades to a reported reason --------------------
test_missing_revisions_report_unavailable() {
  local repo out sha
  repo=$(new_repo t9)
  sha=$(git -C "$repo" rev-parse HEAD)
  write_inventory "$repo" "$(entry core-behavior '["core.txt"]' "[\"$sha\"]" none retain)"

  out=$(run_check "$repo" --base "$sha" --head main --upstream no-such-ref)

  expect_code 0 "$?" "an unresolvable revision still completes the other checks"
  assert_contains "$out" "inventory-drift: unavailable: " "the reason is reported"
  assert_contains "$out" "inventory-entry: core-behavior ok" "the other checks still ran"
  pass "T9 an unresolvable revision reports why, and the other checks still run"
}

# --- T10: the shipped inventory is valid -----------------------------------
test_shipped_inventory_is_valid() {
  local out
  out=$("$DIVERGENCE" 2>&1)
  expect_code 0 "$?" "the shipped inventory parses and validates"
  assert_contains "$out" "inventory-entries: " "the shipped inventory reports its entries"
  assert_not_contains "$out" "inventory: invalid" "the shipped inventory is not invalid"
  pass "T10 the inventory this repo ships is schema-valid"
}

# --- T11: an uncomputable comparison never answers negatively ---------------
# With no base, the private-vs-upstream comparison cannot run at all. An entry
# claiming upstream carries its work must not be challenged by a check that
# never looked.
test_uncomputable_comparison_does_not_challenge_equivalence() {
  local repo out sha
  repo=$(new_repo t11)
  # Upstream never touches the claimed path, so a comparison that DOES run has
  # grounds to challenge the claim - and one that cannot run has none.
  git -C "$repo" checkout -q public
  printf 'public elsewhere\n' > "$repo/shared.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm public-change
  git -C "$repo" checkout -q main
  printf 'private core\n' > "$repo/core.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm private-change
  sha=$(git -C "$repo" rev-parse HEAD)
  write_inventory "$repo" "$(entry claimed '["core.txt"]' "[\"$sha\"]" present retain "$sha")"

  # No --base at all: the drift comparison has nothing to compare from.
  out=$(run_check "$repo" --head main --upstream public)
  expect_code 0 "$?" "the other checks still run"
  assert_contains "$out" "inventory-drift: unavailable: " "the comparison reports that it could not run"
  assert_not_contains "$out" "upstream-equivalent-unconfirmed" \
    "a comparison that did not run never challenges the claim"

  # An unresolvable base is the same situation.
  out=$(run_check "$repo" --base no-such-ref --head main --upstream public)
  assert_not_contains "$out" "upstream-equivalent-unconfirmed" \
    "an unresolvable base never challenges the claim"

  # And when the comparison DOES run and upstream really did not touch the
  # claimed path, the claim is still challenged.
  out=$(run_check "$repo" --base "$(git -C "$repo" merge-base main public)" --head main --upstream public)
  assert_contains "$out" "inventory-entry: claimed upstream-equivalent-unconfirmed" \
    "a comparison that did run still challenges an unsupported claim"
  pass "T11 an uncomputable comparison never reports a false unconfirmed equivalence"
}

test_missing_inventory_fails
test_schema_errors_fail_hard
test_clean_inventory_is_ok
test_stale_and_unresolved_are_reported
test_dispositions_are_surfaced
test_uncovered_drift_comes_from_git
test_upstream_review_point_gates_resurfacing
test_unconfirmed_equivalence_is_challenged
test_missing_revisions_report_unavailable
test_shipped_inventory_is_valid
test_uncomputable_comparison_does_not_challenge_equivalence

echo "# all fm-private-divergence tests passed"
