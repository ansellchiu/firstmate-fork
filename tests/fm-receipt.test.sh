#!/usr/bin/env bash
# fm-receipt.v1 behavior: schema round-trip and validation refusals, the
# structural writers (fm-pr-check.sh landing, fm_merge_outcome_report's proved
# -merge upgrade, fm-merge-local.sh local landing, teardown's scout report
# receipt), the append-only gap-validated index, and the idempotent
# archive/discard teardown sequence.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh disable=SC1091
. "$ROOT/bin/fm-merge-outcome-lib.sh"

RECEIPT="$ROOT/bin/fm-receipt.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-receipt)

# make_home <name>: create a fixture home with a state dir and return its path.
make_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data"
  chmod 700 "$home" "$home/state"
  printf '%s\n' "$home"
}

run_receipt() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RECEIPT" "$@"
}

write_fixture_task() {  # <home> <task-id> [project-basename]
  local home=$1 id=$2 project=${3:-proj}
  mkdir -p "$home/data/$id" "$TMP_ROOT/$id-wt"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$TMP_ROOT/$id-wt" \
    "project=$TMP_ROOT/$project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: started\n' > "$home/state/$id.status"
  printf 'done: shipped the fix\n' >> "$home/state/$id.status"
  printf "# Task\n## Captain's intent\nStop the intake leak.\n\n## Firstmate spec\nDo it.\n" \
    > "$home/data/$id/brief.md"
}

test_schema_round_trip() {
  local home out
  home=$(make_home schema-round-trip)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/9 \
    --head-sha 08d82aa9deadbeef08d82aa9deadbeef08d82aa9 \
    --head-sha-source 'gh pr view --json headRefOid -q .headRefOid' >/dev/null \
    || fail "schema round-trip: write-landing failed"
  out=$(run_receipt "$home" get task-a) || fail "schema round-trip: get failed"
  [ "$(printf '%s' "$out" | jq -r .schema)" = "fm-receipt.v1" ] \
    || fail "schema round-trip: schema field is $(printf '%s' "$out" | jq -r .schema)"
  [ "$(printf '%s' "$out" | jq -r .id)" = "task-a#1" ] \
    || fail "schema round-trip: id is $(printf '%s' "$out" | jq -r .id)"
  [ "$(printf '%s' "$out" | jq -r .kind)" = "landing" ] \
    || fail "schema round-trip: kind is $(printf '%s' "$out" | jq -r .kind)"
  [ "$(printf '%s' "$out" | jq -r .verification)" = "unverified" ] \
    || fail "schema round-trip: verification is $(printf '%s' "$out" | jq -r .verification)"
  [ "$(printf '%s' "$out" | jq -r .intent)" = "Stop the intake leak." ] \
    || fail "schema round-trip: intent was not read from the brief"
  [ "$(printf '%s' "$out" | jq -r .action)" = "shipped the fix" ] \
    || fail "schema round-trip: action was not read from the done line"
  [ "$(printf '%s' "$out" | jq -r .project)" = "proj" ] \
    || fail "schema round-trip: project is $(printf '%s' "$out" | jq -r .project)"
  [ "$(printf '%s' "$out" | jq -r '.published | length')" = "0" ] \
    || fail "schema round-trip: published is not empty"
  printf '%s\n' "$out" | jq -e '.tier1 | length == 2' >/dev/null \
    || fail "schema round-trip: tier1 should carry the pr_url and head anchors"
  # The canonical form revalidates through stdin.
  printf '%s\n' "$out" | FM_HOME="$home" "$RECEIPT" validate >/dev/null \
    || fail "schema round-trip: the stored receipt failed revalidation"
  [ "$(file_mode "$home/state/task-a.receipt")" = "600" ] \
    || fail "schema round-trip: the per-task record is not mode 0600"
  pass "a written receipt round-trips through get and validate with derived fields"
}

test_schema_rejects_invalid() {
  local home base out
  home=$(make_home schema-invalid)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/9 >/dev/null
  base=$(run_receipt "$home" get task-a)

  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.kind = "bogus"' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: an unknown kind validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.tier1 = []' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: an empty tier1 validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.tier1[0].source = ""' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: an anchor without a source validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.verification = "green"' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: an unknown verification validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.id = "other-task#1"' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: an id naming another task validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.id = "task-a#01"' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: a zero-padded seq validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.created_at = "2026-09-10 12:00:00"' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: a non-RFC3339 created_at validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.digest = ""' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: an empty digest validated"
  expect_code 1 "$(printf '%s\n' "$base" | jq -c '.tier1[0].kind = "vibe"' | FM_HOME="$home" "$RECEIPT" validate >/dev/null 2>&1; echo $?)" \
    "schema-invalid: an unknown anchor kind validated"
  out=$(printf '%s\n' "$base" | jq -c '.published = {"discord": "2026-09-11T00:00:00Z"}' | FM_HOME="$home" "$RECEIPT" validate 2>/dev/null) \
    || fail "schema-invalid: a populated published map with RFC3339 values was refused"
  [ -n "$out" ] || fail "schema-invalid: validate printed nothing for the published case"
  pass "malformed receipts fail validation on every structural rule"
}

test_pr_check_writes_landing_receipt() {
  local home dir out id
  home=$(make_home pr-check-landing)
  write_fixture_task "$home" task-a
  dir="$TMP_ROOT/pr-check-fakebin"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) printf '%s\n' "08d82aa9deadbeef08d82aa9deadbeef08d82aa9" ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$dir/gh"
  FM_TEST_GUARD_LOG="$TMP_ROOT/guard.log"
  : > "$FM_TEST_GUARD_LOG"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_GUARD_LOG="$FM_TEST_GUARD_LOG" \
    PATH="$dir:$PATH" "$PR_CHECK" task-a https://github.com/o/r/pull/9 2>/dev/null) \
    || fail "pr-check-landing: fm-pr-check.sh failed"
  case "$out" in
    armed:*) ;;
    *) fail "pr-check-landing: pr-check output changed: $out" ;;
  esac
  id=$(run_receipt "$home" get task-a | jq -r .id) || fail "pr-check-landing: no receipt"
  [ "$id" = "task-a#1" ] || fail "pr-check-landing: id is $id"
  run_receipt "$home" get task-a | jq -e '
    .verification == "unverified"
    and any(.tier1[]; .kind == "pr_url" and .value == "https://github.com/o/r/pull/9")
    and any(.tier1[]; .kind == "pr_head")
    and all(.tier1[]; .kind != "commit_sha")
  ' >/dev/null || fail "pr-check-landing: the landing receipt lacks its anchors"
  # Re-registering the SAME PR keeps the landing's id; a NEW PR takes the next.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_GUARD_LOG="$FM_TEST_GUARD_LOG" \
    PATH="$dir:$PATH" "$PR_CHECK" task-a https://github.com/o/r/pull/9 >/dev/null 2>&1
  [ "$(run_receipt "$home" get task-a | jq -r .id)" = "task-a#1" ] \
    || fail "pr-check-landing: re-registering the same PR changed the receipt id"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_GUARD_LOG="$FM_TEST_GUARD_LOG" \
    PATH="$dir:$PATH" "$PR_CHECK" task-a https://github.com/o/r/pull/10 >/dev/null 2>&1
  [ "$(run_receipt "$home" get task-a | jq -r .id)" = "task-a#2" ] \
    || fail "pr-check-landing: a new PR did not take a new receipt id"
  pass "fm-pr-check.sh writes the landing receipt structurally at registration"
}

test_merge_outcome_upgrades_to_verified() {
  local home out
  home=$(make_home merge-upgrade)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/9 >/dev/null
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  fm_merge_outcome_report "$home" "$home/state" task-a https://github.com/o/r/pull/9 self '' \
    42cd40735933f2b5cdc47ecb9c1aad193e248c96 "gh api graphql pullRequest{mergeCommit{oid}}" \
    >/dev/null 2>&1 \
    || fail "merge-upgrade: fm_merge_outcome_report failed"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = false ] \
    || fail "merge-upgrade: the outcome claimed it was already recorded"
  out=$(run_receipt "$home" get task-a)
  [ "$(printf '%s' "$out" | jq -r .id)" = "task-a#1" ] \
    || fail "merge-upgrade: the upgrade changed the receipt id"
  [ "$(printf '%s' "$out" | jq -r .verification)" = "verified" ] \
    || fail "merge-upgrade: the receipt is not verified"
  printf '%s' "$out" | jq -e 'any(.tier1[]; .kind == "commit_sha" and .value == "42cd40735933f2b5cdc47ecb9c1aad193e248c96")' >/dev/null \
    || fail "merge-upgrade: the commit anchor is missing"
  # Idempotent: a retried report merges the same anchors without duplicating.
  fm_merge_outcome_report "$home" "$home/state" task-a https://github.com/o/r/pull/9 self '' \
    42cd40735933f2b5cdc47ecb9c1aad193e248c96 "gh api graphql pullRequest{mergeCommit{oid}}" \
    >/dev/null 2>&1 || fail "merge-upgrade: the retry failed"
  out=$(run_receipt "$home" get task-a)
  [ "$(printf '%s' "$out" | jq -r '.tier1 | length')" = "2" ] \
    || fail "merge-upgrade: the retry duplicated anchors ($(printf '%s' "$out" | jq -r '.tier1 | length'))"
  pass "the proved-merge path upgrades the landing receipt to verified, idempotently"
}

test_merge_outcome_creates_receipt_when_absent() {
  local home out
  home=$(make_home merge-absent)
  write_fixture_task "$home" task-b
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  fm_merge_outcome_report "$home" "$home/state" task-b https://github.com/o/r/pull/3 poll '' \
    >/dev/null 2>&1 \
    || fail "merge-absent: fm_merge_outcome_report failed without a prior receipt"
  out=$(run_receipt "$home" get task-b)
  [ "$(printf '%s' "$out" | jq -r .verification)" = "verified" ] \
    || fail "merge-absent: the created receipt is not verified"
  printf '%s' "$out" | jq -e 'any(.tier1[]; .kind == "pr_url")' >/dev/null \
    || fail "merge-absent: the created receipt lacks its pr_url anchor"
  pass "a proved merge of a task with no registration receipt still creates one"
}

test_merge_local_writes_verified_landing() {
  local home case_dir rc out default_head
  home=$(make_home merge-local)
  case_dir="$TMP_ROOT/merge-local-proj"
  git init -q -b main "$case_dir"
  git -C "$case_dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  default_head=$(git -C "$case_dir" rev-parse main)
  git -C "$case_dir" checkout -q -b fm/task-x
  git -C "$case_dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  git -C "$case_dir" checkout -q main
  fm_write_meta "$home/state/task-x.meta" \
    "window=firstmate:fm-task-x" \
    "endpoint_task_id=task-x" \
    "worktree=$TMP_ROOT/task-x-wt" \
    "project=$case_dir" \
    "kind=ship" \
    "mode=local-only"
  printf 'done: built it\n' > "$home/state/task-x.status"
  set +e
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$MERGE_LOCAL" task-x >/dev/null 2>"$TMP_ROOT/ml.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-local: fm-merge-local.sh failed: $(cat "$TMP_ROOT/ml.err")"
  out=$(run_receipt "$home" get task-x)
  [ "$(printf '%s' "$out" | jq -r .verification)" = "verified" ] \
    || fail "merge-local: the local landing is not verified"
  printf '%s' "$out" | jq -e --arg head "$default_head" \
    'any(.tier1[]; .kind == "commit_sha" and .value != $head)' >/dev/null \
    || fail "merge-local: the commit anchor does not name the new default head"
  printf '%s' "$out" | jq -e -r '.tier1[] | select(.kind == "commit_sha") | .source' \
    | grep -q 'rev-parse main' \
    || fail "merge-local: the commit anchor source is not the exact command"
  pass "fm-merge-local.sh writes the verified local landing receipt"
}

test_write_report_receipt() {
  local home out
  home=$(make_home write-report)
  write_fixture_task "$home" task-s
  printf 'findings\n' > "$home/data/task-s/report.md"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RECEIPT" write-report \
    --task task-s --report-path "$home/data/task-s/report.md") \
    || fail "write-report: the writer failed"
  [ "$out" = "task-s#1" ] || fail "write-report: id is $out"
  run_receipt "$home" get task-s | jq -e '
    .kind == "report" and .verification == "verified"
    and (.tier1 | length == 1)
    and .tier1[0].kind == "report_path"
    and (.tier1[0].source | startswith("test -s "))
  ' >/dev/null || fail "write-report: the report receipt has the wrong shape"
  # A missing report refuses.
  expect_code 1 "$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RECEIPT" write-report \
    --task task-s --report-path "$home/data/task-s/absent.md" >/dev/null 2>&1; echo $?)" \
    "write-report: a missing report did not refuse"
  pass "teardown's report writer records a verified report receipt with its existence check"
}

# The per-task record holds the CURRENT receipt only, so the index is the only
# place a superseded landing event can survive: registering a second, different
# PR for one task must not make the first registration vanish without a trace.
test_a_superseded_landing_is_archived_before_it_is_replaced() {
  local home ids
  home=$(make_home supersede-archive)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/1 >/dev/null \
    || fail "supersede-archive: the first registration failed"
  [ "$(jq -r .id "$home/state/task-a.receipt")" = "task-a#1" ] \
    || fail "supersede-archive: the first receipt did not take seq 1"
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/2 >/dev/null \
    || fail "supersede-archive: the second registration failed"

  [ "$(jq -r .id "$home/state/task-a.receipt")" = "task-a#2" ] \
    || fail "supersede-archive: the record does not hold the newest landing"
  # state/receipts.jsonl is the owned append-only index format (bin/fm-receipt.sh).
  ids=$(jq -r .id "$home/state/receipts.jsonl" | tr '\n' ' ')
  [ "$ids" = "task-a#1 " ] \
    || fail "supersede-archive: the index holds [$ids], not the superseded receipt"
  jq -e 'select(.id == "task-a#1")
    | (.verification == "unverified")
    and any(.tier1[]; .kind == "pr_url" and .value == "https://github.com/o/r/pull/1")' \
    "$home/state/receipts.jsonl" >/dev/null \
    || fail "supersede-archive: the archived row lost the superseded receipt's own evidence"

  # And the surviving record still archives on its own at cleanup.
  [ "$(run_receipt "$home" archive --task task-a)" = "2" ] \
    || fail "supersede-archive: the current receipt did not archive at the next seq"
  pass "a landing receipt superseded by a different outcome is archived before it is replaced"
}

# An append that cannot complete must leave the shared store exactly as it was:
# a partial row would fail every later read and append, and teardown turns an
# archive failure into a refusal, so one bad append would block every later
# cleanup on this home.
test_a_failed_append_leaves_the_index_usable() {
  local home before after rc
  home=$(make_home append-rollback)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/1 >/dev/null
  run_receipt "$home" archive --task task-a >/dev/null \
    || fail "append-rollback: the first archive failed"
  before=$(cksum < "$home/state/receipts.jsonl")

  write_fixture_task "$home" task-b
  run_receipt "$home" write-landing --task task-b \
    --pr-url https://github.com/o/r/pull/2 >/dev/null
  chmod 0400 "$home/state/receipts.jsonl"
  rc=0
  run_receipt "$home" archive --task task-b >/dev/null 2>&1 || rc=$?
  chmod 0600 "$home/state/receipts.jsonl"

  expect_code 1 "$rc" "append-rollback: an append that cannot be written reported success"
  after=$(cksum < "$home/state/receipts.jsonl")
  [ "$before" = "$after" ] \
    || fail "append-rollback: the failed append changed the store"
  [ "$(run_receipt "$home" list --recent 10 | wc -l | tr -d ' ')" = "1" ] \
    || fail "append-rollback: the store no longer reads after a failed append"
  [ "$(run_receipt "$home" archive --task task-b)" = "2" ] \
    || fail "append-rollback: the store no longer accepts the retried append"
  pass "an append that cannot be written leaves the durable index readable and appendable"
}

test_index_is_append_only_and_gap_validated() {
  local home first second
  home=$(make_home index-mechanics)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/1 >/dev/null
  first=$(run_receipt "$home" archive --task task-a) \
    || fail "index-mechanics: the first archive failed"
  [ "$first" = "1" ] || fail "index-mechanics: the first seq is $first"
  [ "$(run_receipt "$home" archive --task task-a)" = "already-indexed" ] \
    || fail "index-mechanics: a second archive of one receipt was not append-once"
  # A second task appends at the next seq.
  write_fixture_task "$home" task-b
  run_receipt "$home" write-landing --task task-b \
    --pr-url https://github.com/o/r/pull/2 >/dev/null
  second=$(run_receipt "$home" archive --task task-b) \
    || fail "index-mechanics: the second archive failed"
  [ "$second" = "2" ] || fail "index-mechanics: the second seq is $second"
  [ "$(run_receipt "$home" list --recent 10 | wc -l | tr -d ' ')" = "2" ] \
    || fail "index-mechanics: list did not print both rows"
  # A corrupted store refuses every mutation and read.
  printf '{"seq":9\n' >> "$home/state/receipts.jsonl"
  expect_code 1 "$(run_receipt "$home" archive --task task-a >/dev/null 2>&1; echo $?)" \
    "index-mechanics: a corrupt index accepted an append"
  expect_code 1 "$(run_receipt "$home" list >/dev/null 2>&1; echo $?)" \
    "index-mechanics: a corrupt index served a read"
  pass "the receipt index is append-only, gap-validated, and refuses corruption"
}

test_discard_and_lifecycle() {
  local home
  home=$(make_home discard)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/5 >/dev/null
  run_receipt "$home" archive --task task-a >/dev/null
  run_receipt "$home" discard --task task-a || fail "discard: discard failed"
  expect_code 1 "$(run_receipt "$home" get task-a >/dev/null 2>&1; echo $?)" \
    "discard: get still served a discarded receipt"
  run_receipt "$home" discard --task task-a || fail "discard: discard is not idempotent"
  pass "discard removes the per-task record idempotently after archive"
}

# The forge-upgrade path: the registration head and the merge commit are two
# different answers, so "which commit landed" must resolve from anchor kind
# alone, with no parsing of the free-text source.
test_pr_head_and_landed_commit_are_distinct_kinds() {
  local home out landed
  home=$(make_home anchor-kinds)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/9 \
    --head-sha 1111111111111111111111111111111111111111 \
    --head-sha-source 'gh pr view --json headRefOid -q .headRefOid' >/dev/null \
    || fail "anchor-kinds: write-landing failed"
  fm_merge_outcome_report "$home" "$home/state" task-a https://github.com/o/r/pull/9 self '' \
    2222222222222222222222222222222222222222 "gh api graphql pullRequest{mergeCommit{oid}}" \
    >/dev/null 2>&1 || fail "anchor-kinds: the proved-merge upgrade failed"
  out=$(run_receipt "$home" get task-a)
  printf '%s' "$out" | jq -e '
    ([.tier1[] | select(.kind == "pr_head")] | length == 1)
    and ([.tier1[] | select(.kind == "commit_sha")] | length == 1)
    and (.tier1[] | select(.kind == "pr_head") | .value
      == "1111111111111111111111111111111111111111")
  ' >/dev/null || fail "anchor-kinds: the head and the merge commit did not take distinct kinds"
  # The landed-commit query: kind alone, no source parsing.
  landed=$(printf '%s' "$out" | jq -r '[.tier1[] | select(.kind == "commit_sha")] | last | .value')
  [ "$landed" = "2222222222222222222222222222222222222222" ] \
    || fail "anchor-kinds: the landed-commit query answered $landed"
  pass "the PR head and the landed commit take distinct anchor kinds through the upgrade path"
}

# A GitLab merge can only prove the source-branch head, which is not the
# commit on the target branch under any strategy but fast-forward.
test_gitlab_verified_head_is_a_pr_head_anchor() {
  local home out
  home=$(make_home gitlab-head-anchor)
  write_fixture_task "$home" task-g
  run_receipt "$home" write-landing --task task-g \
    --pr-url https://gitlab.com/o/r/-/merge_requests/4 >/dev/null \
    || fail "gitlab-head-anchor: write-landing failed"
  fm_merge_outcome_report "$home" "$home/state" task-g \
    https://gitlab.com/o/r/-/merge_requests/4 self '' '' '' \
    3333333333333333333333333333333333333333 \
    "glab mr merge --sha 3333333333333333333333333333333333333333" \
    >/dev/null 2>&1 || fail "gitlab-head-anchor: the proved-merge upgrade failed"
  out=$(run_receipt "$home" get task-g)
  printf '%s' "$out" | jq -e '
    (.verification == "verified")
    and any(.tier1[]; .kind == "pr_head"
      and .value == "3333333333333333333333333333333333333333")
    and all(.tier1[]; .kind != "commit_sha")
  ' >/dev/null \
    || fail "gitlab-head-anchor: the verified source head was not recorded as pr_head"
  pass "a merge that only proves the source head records it as pr_head, never as the landed commit"
}

# Every tier-1 anchor source must name an exact command or API field, never a
# firstmate script or shell function.
test_anchor_sources_name_a_command_or_api_field() {
  local home out
  home=$(make_home anchor-sources)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/9 >/dev/null \
    || fail "anchor-sources: write-landing failed"
  fm_merge_outcome_report "$home" "$home/state" task-a https://github.com/o/r/pull/9 self '' \
    >/dev/null 2>&1 || fail "anchor-sources: the upgrade failed"
  out=$(run_receipt "$home" get task-a)
  printf '%s' "$out" | jq -e '
    all(.tier1[]; (.source | test("fm-[a-z-]+\\.sh") | not)
      and (.source | test("^fm_[a-z_]+$") | not))
  ' >/dev/null \
    || fail "anchor-sources: an anchor source names a firstmate script or shell function: $(printf '%s' "$out" | jq -rc '[.tier1[].source]')"
  # The pr_url anchor's source is a command that reads back the same value.
  printf '%s' "$out" | jq -r '.tier1[] | select(.kind == "pr_url") | .source' \
    | grep -q "^grep '\^pr=' " \
    || fail "anchor-sources: the pr_url source is not the exact read command"
  pass "every tier-1 anchor source names an exact command, not firstmate's own code"
}

# A captain intent whose first line begins with '#' (an issue number) is text,
# not the next markdown heading.
test_brief_intent_survives_a_hash_prefixed_first_line() {
  local home out
  home=$(make_home hash-intent)
  write_fixture_task "$home" task-h
  printf "# Task\n## Captain's intent\n#412: the poller drops events under backpressure\n\n## Firstmate spec\nDo it.\n" \
    > "$home/data/task-h/brief.md"
  run_receipt "$home" write-landing --task task-h \
    --pr-url https://github.com/o/r/pull/7 >/dev/null \
    || fail "hash-intent: write-landing failed"
  out=$(run_receipt "$home" get task-h | jq -r .intent)
  [ "$out" = "#412: the poller drops events under backpressure" ] \
    || fail "hash-intent: the intent was read as '$out'"
  # A real heading still ends the section: an empty intent section falls back.
  printf "# Task\n## Captain's intent\n\n## Firstmate spec\nDo it.\n" \
    > "$home/data/task-h/brief.md"
  rm -f "$home/state/task-h.receipt"
  run_receipt "$home" write-landing --task task-h \
    --pr-url https://github.com/o/r/pull/7 >/dev/null
  run_receipt "$home" get task-h | jq -e '.intent | startswith("(intent unavailable")' \
    >/dev/null || fail "hash-intent: a real heading no longer ends the intent section"
  pass "a hash-prefixed intent line is read as text while real headings still end the section"
}

# Re-running the report writer over the same report must not mint a second id,
# because the id is what makes the durable index append-once.
test_report_retry_keeps_one_id_and_one_index_row() {
  local home first second rows
  home=$(make_home report-retry)
  write_fixture_task "$home" task-s
  printf 'findings\n' > "$home/data/task-s/report.md"
  first=$(run_receipt "$home" write-report --task task-s \
    --report-path "$home/data/task-s/report.md") || fail "report-retry: the first write failed"
  run_receipt "$home" archive --task task-s >/dev/null || fail "report-retry: the first archive failed"
  # The teardown retry: the same report, written again over the kept record.
  second=$(run_receipt "$home" write-report --task task-s \
    --report-path "$home/data/task-s/report.md") || fail "report-retry: the retry failed"
  [ "$first" = "$second" ] \
    || fail "report-retry: the retry minted a new id ($first then $second)"
  run_receipt "$home" archive --task task-s >/dev/null
  rows=$(grep -c '"task":"task-s"' "$home/state/receipts.jsonl" | tr -d ' ')
  [ "$rows" = "1" ] || fail "report-retry: one report was indexed $rows times"
  pass "a retried report receipt keeps its id so the index records one outcome once"
}

# One invalid receipt must never brick the store every task shares.
test_archive_refuses_an_invalid_receipt() {
  local home
  home=$(make_home archive-validates)
  write_fixture_task "$home" task-a
  write_fixture_task "$home" task-b
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/1 >/dev/null
  # A receipt that no longer satisfies the schema (what an older or broken
  # writer, or a --force path that skips the get gate, can leave behind).
  jq -c 'del(.digest)' "$home/state/task-a.receipt" > "$home/state/task-a.receipt.tmp"
  mv "$home/state/task-a.receipt.tmp" "$home/state/task-a.receipt"
  expect_code 1 "$(run_receipt "$home" archive --task task-a >/dev/null 2>&1; echo $?)" \
    "archive-validates: an invalid receipt was archived"
  # The store is still usable for every other task.
  run_receipt "$home" write-landing --task task-b \
    --pr-url https://github.com/o/r/pull/2 >/dev/null
  [ "$(run_receipt "$home" archive --task task-b)" = "1" ] \
    || fail "archive-validates: the refused append left the shared index unusable"
  run_receipt "$home" list >/dev/null \
    || fail "archive-validates: the refused append left the shared index unreadable"
  pass "archive validates a receipt before appending it, so one bad record cannot brick the index"
}

# The index must not keep answering "unverified" after the merge is proved.
test_archive_supersedes_an_unverified_row_once_verified() {
  local home rows last
  home=$(make_home archive-supersede)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/9 >/dev/null
  [ "$(run_receipt "$home" archive --task task-a)" = "1" ] \
    || fail "archive-supersede: the unverified archive failed"
  # The proved merge upgrades the kept per-task record in place.
  fm_merge_outcome_report "$home" "$home/state" task-a https://github.com/o/r/pull/9 self '' \
    42cd40735933f2b5cdc47ecb9c1aad193e248c96 "gh api graphql pullRequest{mergeCommit{oid}}" \
    >/dev/null 2>&1 || fail "archive-supersede: the proved-merge upgrade failed"
  [ "$(run_receipt "$home" archive --task task-a)" = "2" ] \
    || fail "archive-supersede: the verified receipt did not earn a superseding row"
  rows=$(wc -l < "$home/state/receipts.jsonl" | tr -d ' ')
  [ "$rows" = "2" ] || fail "archive-supersede: the index holds $rows rows"
  last=$(jq -rs '[.[] | select(.id == "task-a#1")] | last | .verification' \
    "$home/state/receipts.jsonl")
  [ "$last" = "verified" ] \
    || fail "archive-supersede: the newest indexed row still answers $last"
  # And it settles: a third archive of the same verified receipt adds nothing.
  [ "$(run_receipt "$home" archive --task task-a)" = "already-indexed" ] \
    || fail "archive-supersede: the superseding row is not itself append-once"
  pass "a receipt verified after it was indexed earns exactly one superseding row"
}

# A host without jq cannot read or write typed receipts at all; that is a
# different answer from "this task has no receipt", and it exits 3.
test_missing_jq_is_a_distinct_unavailable_exit() {
  local home dir rc err
  home=$(make_home no-jq)
  write_fixture_task "$home" task-a
  dir="$TMP_ROOT/no-jq-bin"
  mkdir -p "$dir"
  for tool in bash sh env cat date mkdir rm mv grep sed printf basename chmod mktemp tr uname wc tail; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -sf "$(command -v "$tool")" "$dir/$tool" 2>/dev/null || true
    fi
  done
  set +e
  err=$(PATH="$dir" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RECEIPT" get task-a 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "no-jq: a host without jq did not exit 3"
  case "$err" in
    *jq*) ;;
    *) fail "no-jq: the error does not name jq: $err" ;;
  esac
  pass "a host without jq reports receipts unavailable with a distinct exit code"
}

# Re-registering an already-proved landing is the repair bin/fm-teardown.sh
# names for a missing receipt, so it must never rewind one: the verification
# and the landed commit an upgrade established have to survive it.
test_reregistration_never_downgrades_a_proved_landing() {
  local home out
  home=$(make_home reregistration-repair)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/7 \
    --head-sha 1111111111111111111111111111111111111111 \
    --head-sha-source 'gh pr view --json headRefOid -q .headRefOid' >/dev/null \
    || fail "reregistration-repair: the registration write failed"
  fm_merge_outcome_report "$home" "$home/state" task-a https://github.com/o/r/pull/7 self '' \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "gh api graphql pullRequest{mergeCommit{oid}}" \
    >/dev/null 2>&1 || fail "reregistration-repair: the proved-merge upgrade failed"
  # The proved landing no longer reads as merely ready.
  out=$(run_receipt "$home" get task-a)
  [ "$(printf '%s' "$out" | jq -r .digest)" = "Merged: https://github.com/o/r/pull/7" ] \
    || fail "reregistration-repair: the upgraded digest is $(printf '%s' "$out" | jq -r .digest)"

  # The repair: exactly what bin/fm-pr-check.sh re-runs, same URL.
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/7 \
    --head-sha 1111111111111111111111111111111111111111 \
    --head-sha-source 'gh pr view --json headRefOid -q .headRefOid' >/dev/null \
    || fail "reregistration-repair: the repeated registration failed"
  out=$(run_receipt "$home" get task-a)
  [ "$(printf '%s' "$out" | jq -r .id)" = "task-a#1" ] \
    || fail "reregistration-repair: the repair minted a new id"
  [ "$(printf '%s' "$out" | jq -r .verification)" = "verified" ] \
    || fail "reregistration-repair: the repair downgraded the receipt to $(printf '%s' "$out" | jq -r .verification)"
  printf '%s' "$out" | jq -e 'any(.tier1[]; .kind == "commit_sha" and .value == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")' >/dev/null \
    || fail "reregistration-repair: the repair dropped the landed commit anchor"
  [ "$(printf '%s' "$out" | jq -r .digest)" = "Merged: https://github.com/o/r/pull/7" ] \
    || fail "reregistration-repair: the repair rewound the digest"

  # An explicit verification still overrides, so a real re-registration of a
  # different state is still expressible.
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/7 --verification unverified >/dev/null \
    || fail "reregistration-repair: an explicit verification was refused"
  [ "$(run_receipt "$home" get task-a | jq -r .verification)" = "unverified" ] \
    || fail "reregistration-repair: an explicit --verification was ignored"
  pass "re-registering the same landing merges into it instead of rewinding it"
}

# Teardown discards the per-task record, so the record alone cannot say which
# ids the append-only index already holds. A reused task id must not re-mint
# one, or the archive's append-once rule silently drops the second outcome.
test_reused_task_id_does_not_reuse_an_indexed_id() {
  local home out rows
  home=$(make_home reused-task-id)
  write_fixture_task "$home" task-a
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/1 >/dev/null \
    || fail "reused-task-id: the first landing failed"
  [ "$(run_receipt "$home" archive --task task-a)" = "1" ] \
    || fail "reused-task-id: the first archive failed"
  run_receipt "$home" discard --task task-a \
    || fail "reused-task-id: the discard failed"

  # A later task reusing the id records a genuinely different outcome.
  run_receipt "$home" write-landing --task task-a \
    --pr-url https://github.com/o/r/pull/2 --verification verified \
    --digest 'second landing' >/dev/null \
    || fail "reused-task-id: the second landing failed"
  out=$(run_receipt "$home" get task-a)
  [ "$(printf '%s' "$out" | jq -r .id)" = "task-a#2" ] \
    || fail "reused-task-id: the reused task restarted at $(printf '%s' "$out" | jq -r .id)"
  [ "$(run_receipt "$home" archive --task task-a)" = "2" ] \
    || fail "reused-task-id: the second outcome was not indexed"
  rows=$(wc -l < "$home/state/receipts.jsonl" | tr -d ' ')
  [ "$rows" = "2" ] || fail "reused-task-id: the index holds $rows rows"
  jq -e 'select(.id == "task-a#2") | .digest == "second landing"' \
    "$home/state/receipts.jsonl" >/dev/null \
    || fail "reused-task-id: the second outcome is missing from the index"
  pass "a task id reused after teardown takes the next seq the index has not used"
}

# A landed merge must be delivered even where receipts cannot be written at
# all: the receipt is evidence, never the gate on delivery, so a jq-less host
# reports the gap and still marks the merge notified (which retires the poll).
# shellcheck disable=SC2120  # the `set --` below gives this function its own
# positional parameters; it never takes arguments from its caller.
test_merge_delivery_survives_an_unavailable_receipt() {
  local home dir err rc saved_path entry name part repair out
  home=$(make_home merge-delivery-no-jq)
  write_fixture_task "$home" task-a
  dir="$TMP_ROOT/merge-delivery-no-jq-bin"
  mkdir -p "$dir"
  saved_path=$PATH
  IFS=: read -r -a FM_TEST_PATH_PARTS <<< "$PATH"
  for part in "${FM_TEST_PATH_PARTS[@]}"; do
    [ -d "$part" ] || continue
    for entry in "$part"/*; do
      [ -x "$entry" ] || continue
      name=$(basename "$entry")
      if [ "$name" = jq ]; then
        continue
      fi
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null || true
    done
  done
  PATH="$dir"
  command -v jq >/dev/null 2>&1 && { PATH=$saved_path; fail "merge-delivery-no-jq: the fixture path still resolves jq"; }
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  err=$(fm_merge_outcome_report "$home" "$home/state" task-a \
    https://github.com/o/r/pull/4 self '' \
    cccccccccccccccccccccccccccccccccccccccc "gh api graphql pullRequest{mergeCommit{oid}}" \
    2>&1 >/dev/null)
  rc=$?
  PATH=$saved_path

  expect_code 0 "$rc" "merge-delivery-no-jq: a landed merge was not delivered without jq"
  case "$err" in
    *actionable:*jq*) ;;
    *) fail "merge-delivery-no-jq: the missing receipt was not disclosed as actionable naming jq: $err" ;;
  esac
  [ ! -e "$home/state/task-a.receipt" ] \
    || fail "merge-delivery-no-jq: a receipt was fabricated without jq"
  # The merge was marked notified, so the poll retires instead of re-reporting
  # the same merge on every cycle.
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  fm_merge_outcome_report "$home" "$home/state" task-a \
    https://github.com/o/r/pull/4 poll >/dev/null 2>&1 \
    || fail "merge-delivery-no-jq: the second report failed"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ] \
    || fail "merge-delivery-no-jq: the merge was never marked notified, so the poll would never retire"

  # The marker has committed, so this path never runs again for this PR: the
  # repair the actionable line printed is the only thing that can still record
  # the landing, and following it verbatim must record the LANDING, not a
  # fresh unverified "PR ready" receipt.
  repair=$(printf '%s\n' "$err" | grep -o 'bin/fm-receipt\.sh upgrade-landing.*') \
    || fail "merge-delivery-no-jq: the actionable line printed no repair command: $err"
  eval "set -- ${repair#bin/fm-receipt.sh }"
  run_receipt "$home" "$@" >/dev/null \
    || fail "merge-delivery-no-jq: the printed repair failed: $repair"
  out=$(run_receipt "$home" get task-a) \
    || fail "merge-delivery-no-jq: the repair wrote no readable receipt"
  [ "$(printf '%s' "$out" | jq -r .verification)" = "verified" ] \
    || fail "merge-delivery-no-jq: the printed repair recorded $(printf '%s' "$out" | jq -r .verification), not a proved landing"
  printf '%s' "$out" | jq -e 'any(.tier1[]; .kind == "commit_sha" and .value == "cccccccccccccccccccccccccccccccccccccccc")' >/dev/null \
    || fail "merge-delivery-no-jq: the printed repair lost the landed commit anchor"
  [ "$(printf '%s' "$out" | jq -r .digest)" = "Merged: https://github.com/o/r/pull/4" ] \
    || fail "merge-delivery-no-jq: the printed repair left the digest at $(printf '%s' "$out" | jq -r .digest)"
  pass "a landed merge is delivered without receipts, and the repair it prints records the proved landing"
}

# A receipt failure that is NOT permanent unavailability must keep the merge
# outcome eligible for retry instead of spending its one delivery: the marker
# stays uncommitted for a bounded number of attempts, and the outcome degrades
# to the disclosed-gap path only once that bound is spent.
test_transient_receipt_failure_retries_before_it_degrades() {
  local home err rc n out
  home=$(make_home receipt-retry-bound)
  write_fixture_task "$home" task-a
  printf '# Report\nfindings\n' > "$home/data/task-a/report.md"
  # A non-landing receipt makes upgrade-landing fail with rc=1 (not the
  # jq-unavailable rc=3), which is the failure class the bound governs.
  run_receipt "$home" write-report --task task-a \
    --report-path "$home/data/task-a/report.md" >/dev/null \
    || fail "receipt-retry-bound: the fixture report receipt failed"

  for n in 1 2; do
    FM_MERGE_OUTCOME_ALREADY_RECORDED=
    set +e
    err=$(fm_merge_outcome_report "$home" "$home/state" task-a \
      https://github.com/o/r/pull/8 poll '' \
      dddddddddddddddddddddddddddddddddddddddd "gh api graphql pullRequest{mergeCommit{oid}}" \
      2>&1 >/dev/null)
    rc=$?
    set -e
    expect_code 1 "$rc" "receipt-retry-bound: attempt $n did not stay eligible for retry"
    [ ! -e "$home/state/task-a.pr-poll-merge-notified" ] \
      || fail "receipt-retry-bound: attempt $n committed the merge-notified marker anyway"
    case "$err" in
      *"attempt $n of 3"*) ;;
      *) fail "receipt-retry-bound: attempt $n did not disclose its bounded retry: $err" ;;
    esac
  done

  # The bound is spent: delivery degrades exactly like the jq-less case.
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  set +e
  err=$(fm_merge_outcome_report "$home" "$home/state" task-a \
    https://github.com/o/r/pull/8 poll '' \
    dddddddddddddddddddddddddddddddddddddddd "gh api graphql pullRequest{mergeCommit{oid}}" \
    2>&1 >/dev/null)
  rc=$?
  set -e
  expect_code 0 "$rc" "receipt-retry-bound: the merge was never delivered after the bound"
  case "$err" in
    *"after 3 attempts"*bin/fm-receipt.sh*upgrade-landing*) ;;
    *) fail "receipt-retry-bound: the exhausted bound printed no manual repair: $err" ;;
  esac
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  fm_merge_outcome_report "$home" "$home/state" task-a \
    https://github.com/o/r/pull/8 poll >/dev/null 2>&1 \
    || fail "receipt-retry-bound: the report after the bound failed"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ] \
    || fail "receipt-retry-bound: the merge was never marked notified, so the poll would never retire"
  [ ! -e "$home/state/task-a.pr-poll-merge-receipt-attempts" ] \
    || fail "receipt-retry-bound: the spent retry ledger was left behind"
  pass "a transient receipt failure holds the merge outcome for a bounded retry, then degrades"
}

# The point of holding the marker back: a receipt failure that clears is
# written by the retry, with no human repair and no unverified record left.
test_retried_receipt_recovers_without_a_manual_repair() {
  local home rc out
  home=$(make_home receipt-retry-recovers)
  write_fixture_task "$home" task-b
  printf '# Report\nfindings\n' > "$home/data/task-b/report.md"
  run_receipt "$home" write-report --task task-b \
    --report-path "$home/data/task-b/report.md" >/dev/null \
    || fail "receipt-retry-recovers: the fixture report receipt failed"
  set +e
  fm_merge_outcome_report "$home" "$home/state" task-b \
    https://github.com/o/r/pull/6 poll '' \
    eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee "gh api graphql pullRequest{mergeCommit{oid}}" \
    >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "receipt-retry-recovers: the failed receipt was treated as delivered"

  # The obstruction clears before the bound is spent.
  rm -f "$home/state/task-b.receipt"
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  fm_merge_outcome_report "$home" "$home/state" task-b \
    https://github.com/o/r/pull/6 poll '' \
    eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee "gh api graphql pullRequest{mergeCommit{oid}}" \
    >/dev/null 2>&1 \
    || fail "receipt-retry-recovers: the retry did not deliver the merge"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = false ] \
    || fail "receipt-retry-recovers: the held-back marker had committed anyway"
  out=$(run_receipt "$home" get task-b) \
    || fail "receipt-retry-recovers: the retry wrote no readable receipt"
  [ "$(printf '%s' "$out" | jq -r .verification)" = "verified" ] \
    || fail "receipt-retry-recovers: the retry recorded $(printf '%s' "$out" | jq -r .verification)"
  printf '%s' "$out" | jq -e 'any(.tier1[]; .kind == "commit_sha" and .value == "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")' >/dev/null \
    || fail "receipt-retry-recovers: the retry lost the landed commit anchor"
  [ ! -e "$home/state/task-b.pr-poll-merge-receipt-attempts" ] \
    || fail "receipt-retry-recovers: the retry ledger outlived the successful write"
  pass "a receipt failure that clears is written by the retry, with no manual repair"
}

# The landed-commit anchor is read from one shared forge reader, so a merge the
# forge performed later (poll-detected) records the same evidence as one this
# home performed. Evidence only: every failure mode costs the anchor and
# nothing else.
test_shared_merge_commit_reader_is_evidence_only() {
  local dir out rc
  dir="$TMP_ROOT/merge-commit-reader"
  mkdir -p "$dir"
  cat > "$dir/gh" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GH_MODE:-ok}" in
  ok) printf '%s\n' 42cd40735933f2b5cdc47ecb9c1aad193e248c96 ;;
  empty) printf '\n' ;;
  garbage) printf '%s\n' 'not-a-sha' ;;
  short) printf '%s\n' 42cd407 ;;
  long) printf '%s\n' "$(printf '4%.0s' $(seq 1 65))" ;;
  hang) sleep 30; printf '%s\n' 42cd40735933f2b5cdc47ecb9c1aad193e248c96 ;;
  fail) exit 1 ;;
esac
SH
  chmod +x "$dir/gh"

  out=$(PATH="$dir:$PATH" fm_pr_github_merge_commit o r 9) \
    || fail "merge-commit-reader: a readable merge commit was not returned"
  [ "$out" = 42cd40735933f2b5cdc47ecb9c1aad193e248c96 ] \
    || fail "merge-commit-reader: returned $out"

  local mode
  for mode in empty garbage short long fail; do
    set +e
    out=$(FM_FAKE_GH_MODE=$mode PATH="$dir:$PATH" fm_pr_github_merge_commit o r 9)
    rc=$?
    set -e
    expect_code 1 "$rc" "merge-commit-reader: mode $mode was reported as a readable commit"
    [ -z "$out" ] || fail "merge-commit-reader: mode $mode emitted $out"
  done

  # An unusable request never reaches the forge at all.
  set +e
  out=$(PATH="$dir:$PATH" fm_pr_github_merge_commit o r not-a-number)
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-commit-reader: a non-numeric PR number was queried anyway"
  # No gh on PATH is the same answer, not a crash.
  mkdir -p "$TMP_ROOT/merge-commit-reader-empty-bin"
  set +e
  out=$(PATH="$TMP_ROOT/merge-commit-reader-empty-bin" fm_pr_github_merge_commit o r 9)
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-commit-reader: a host without gh did not degrade"

  # The read runs in the watcher's main loop, so a forge that accepts the
  # connection and never answers must cost the anchor, not the loop.
  local started elapsed
  started=$(date +%s)
  set +e
  out=$(FM_FAKE_GH_MODE=hang FM_PR_MERGE_COMMIT_TIMEOUT=1 PATH="$dir:$PATH" \
    fm_pr_github_merge_commit o r 9)
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -ne 0 ] || fail "merge-commit-reader: a stalled forge read was reported as a commit"
  [ -z "$out" ] || fail "merge-commit-reader: a stalled forge read emitted $out"
  [ "$elapsed" -lt 15 ] \
    || fail "merge-commit-reader: a stalled forge read was not bounded (${elapsed}s)"
  pass "the shared landed-commit reader answers only on a usable oid, bounded, and degrades otherwise"
}

# A merge the poll detected must end with the same anchor set as one this home
# performed: same kind, same exact API-field source.
test_poll_detected_merge_records_the_landed_commit() {
  local home out
  home=$(make_home poll-landed-commit)
  write_fixture_task "$home" task-p
  run_receipt "$home" write-landing --task task-p \
    --pr-url https://github.com/o/r/pull/12 >/dev/null \
    || fail "poll-landed-commit: the registration write failed"
  FM_MERGE_OUTCOME_ALREADY_RECORDED=
  fm_merge_outcome_report "$home" "$home/state" task-p \
    https://github.com/o/r/pull/12 poll '' \
    42cd40735933f2b5cdc47ecb9c1aad193e248c96 "$FM_PR_MERGE_COMMIT_SOURCE" \
    >/dev/null 2>&1 \
    || fail "poll-landed-commit: the poll-detected outcome failed"
  out=$(run_receipt "$home" get task-p)
  printf '%s' "$out" | jq -e '
    (.verification == "verified")
    and (.tier1[] | select(.kind == "commit_sha")
      | .value == "42cd40735933f2b5cdc47ecb9c1aad193e248c96"
        and (.source | test("mergeCommit")))
  ' >/dev/null \
    || fail "poll-landed-commit: the poll-detected receipt lacks the landed commit anchor"
  pass "a poll-detected merge records the landed commit with its exact API-field source"
}

# The repair path must survive the broken records it exists to repair: a
# landing that no longer carries the fields a merge-in-place would preserve
# has to be rewritten, not silently abort the writer mid-lock.
test_write_landing_rewrites_a_record_missing_its_fields() {
  local home field out rc
  for field in verification digest; do
    home=$(make_home "write-landing-missing-$field")
    write_fixture_task "$home" task-a
    run_receipt "$home" write-landing --task task-a \
      --pr-url https://github.com/o/r/pull/11 >/dev/null \
      || fail "write-landing-missing: the registration write failed"
    jq -c "del(.$field)" "$home/state/task-a.receipt" > "$home/state/task-a.receipt.tmp"
    mv "$home/state/task-a.receipt.tmp" "$home/state/task-a.receipt"

    set +e
    out=$(run_receipt "$home" write-landing --task task-a \
      --pr-url https://github.com/o/r/pull/11 2>/dev/null)
    rc=$?
    set -e
    expect_code 0 "$rc" "write-landing-missing: a record with no .$field aborted the writer"
    [ -n "$out" ] || fail "write-landing-missing: the rewrite reported no receipt id"
    run_receipt "$home" get task-a >/dev/null \
      || fail "write-landing-missing: the rewrite left an unreadable record for .$field"
    [ "$(run_receipt "$home" get task-a | jq -r .digest)" = "PR ready: https://github.com/o/r/pull/11" ] \
      || fail "write-landing-missing: the rewrite did not restore the landing digest for .$field"
    # The writer released its lock, so the store still accepts the next write.
    run_receipt "$home" archive --task task-a >/dev/null \
      || fail "write-landing-missing: the store was left locked after the .$field rewrite"
  done
  pass "a landing record missing a required field is rewritten instead of aborting the writer"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_schema_round_trip
test_schema_rejects_invalid
test_pr_check_writes_landing_receipt
test_merge_outcome_upgrades_to_verified
test_merge_outcome_creates_receipt_when_absent
test_merge_local_writes_verified_landing
test_write_report_receipt
test_index_is_append_only_and_gap_validated
test_a_superseded_landing_is_archived_before_it_is_replaced
test_a_failed_append_leaves_the_index_usable
test_discard_and_lifecycle
test_pr_head_and_landed_commit_are_distinct_kinds
test_gitlab_verified_head_is_a_pr_head_anchor
test_anchor_sources_name_a_command_or_api_field
test_brief_intent_survives_a_hash_prefixed_first_line
test_report_retry_keeps_one_id_and_one_index_row
test_archive_refuses_an_invalid_receipt
test_archive_supersedes_an_unverified_row_once_verified
test_missing_jq_is_a_distinct_unavailable_exit
test_reregistration_never_downgrades_a_proved_landing
test_reused_task_id_does_not_reuse_an_indexed_id
test_merge_delivery_survives_an_unavailable_receipt
test_transient_receipt_failure_retries_before_it_degrades
test_retried_receipt_recovers_without_a_manual_repair
test_shared_merge_commit_reader_is_evidence_only
test_poll_detected_merge_records_the_landed_commit
test_write_landing_rewrites_a_record_missing_its_fields
