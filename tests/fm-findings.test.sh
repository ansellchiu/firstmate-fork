#!/usr/bin/env bash
# tests/fm-findings.test.sh - behavior tests for the per-task incidental-
# findings channel (bin/fm-findings.sh over bin/fm-findings-lib.sh).
#
# The captain's problem: ship workers spot real defects outside their scope,
# mention them once in the pane, and the observation dies with cleanup. The
# channel fixes that with a durable per-task record plus bounded surfacing.
#
# Coverage:
#   - record: happy path writes one stamped pending entry with evidence,
#     disposition, and optional context; a second task gets its own file
#   - record dedup: identical (slug, evidence) is an idempotent no-op; the
#     same slug with different evidence is refused without writing, so a new
#     observation can never hide behind an existing title
#   - record malformed input: missing fields, multiline fields, and a title
#     that slugs to nothing are refused with nothing written
#   - triage: rewrites the pending status line with a note, hides the entry
#     from listing; unknown slug, double triage, and missing note refuse;
#     a backslash-bearing note survives verbatim (no awk -v escape mangling)
#   - malformed files: a garbage file yields no entries and no crash; an
#     unnamed entry surfaces as malformed; an entry with no status line is
#     pending by default (loss protection) and stays triageable
#   - bounding: the fleet listing caps shown entries and discloses the rest
#   - teardown preservation: cleanup keeps data/<id>/findings.md and surfaces
#     pending entries in its output; a task with no findings stays silent
#   - brief scaffolds: ship briefs carry the record section; scout briefs and
#     secondmate charters do not, and the emitted record command lands the
#     entry in the scaffolding home even when the worker's environment names
#     a different one
#   - triaged slugs reopen: a re-observation after a dismissal appends a
#     fresh pending entry instead of reporting success into a closed one
#   - mutual exclusion: record and triage serialize on the task's file, so a
#     triage rewrite cannot replace the inode under a concurrent append
#   - path safety: a task id the one-level pending scan could not reach - not
#     one path component, or dot-leading - is refused by record and triage,
#     and a field carrying the unit separator is refused rather than shifting
#     the surfaced fields
#   - triage inserts a missing status line inside its own block
#   - torn entries: a pending block left incomplete by a crashed record
#     neither blocks the retry nor absorbs it as an identical duplicate
#   - the emitted record command binds the scaffolding home's state dir, so
#     the record's lock never materializes another home's control state
#   - promotion's ship instructions emit the same bound record command, so a
#     scout turned ship worker lands its finding in the promoting home
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

FINDINGS="$ROOT/bin/fm-findings.sh"
FINDINGS_LIB="$ROOT/bin/fm-findings-lib.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-findings-tests)

# run_cli <data-dir> <args...>: the CLI pinned to a fixture data dir.
run_cli() {
  local data=$1
  shift
  FM_DATA_OVERRIDE="$data" "$FINDINGS" "$@"
}

# --- record ------------------------------------------------------------------

test_record_happy_path() {
  local data out
  data="$TMP_ROOT/record"
  mkdir -p "$data"
  out=$(run_cli "$data" record t1 --title "Broken install docs" \
    --evidence "README.md:12" --disposition "fix the pip command" \
    --context "shipping the auth feature") || fail "record happy path failed: $out"
  assert_contains "$out" "recorded: broken-install-docs" "record did not confirm the slug"
  local file="$data/t1/findings.md"
  assert_present "$file" "record did not create the findings file"
  assert_grep "## finding: broken-install-docs" "$file" "entry header missing"
  assert_grep "- status: pending" "$file" "entry did not start pending"
  assert_grep "- evidence: README.md:12" "$file" "evidence line missing"
  assert_grep "- suggested-disposition: fix the pip command" "$file" "disposition line missing"
  assert_grep "- context: shipping the auth feature" "$file" "context line missing"
  assert_grep "- recorded: 2" "$file" "recorded timestamp missing"
  # A second task gets its own file, and fleet listing shows both.
  run_cli "$data" record t2 --title "Flaky test" --evidence "make test" \
    --disposition "quarantine it" >/dev/null || fail "record for a second task failed"
  local list
  list=$(run_cli "$data" list) || fail "list failed: $list"
  assert_contains "$list" "t1/broken-install-docs" "fleet list missed the first task"
  assert_contains "$list" "t2/flaky-test" "fleet list missed the second task"
  local scoped
  scoped=$(run_cli "$data" list t1) || fail "task-scoped list failed: $scoped"
  assert_contains "$scoped" "broken-install-docs" "scoped list missed its entry"
  assert_not_contains "$scoped" "flaky-test" "scoped list leaked another task's entry"
  pass "record writes a stamped pending entry per task"
}

test_record_dedup() {
  local data out rc file
  data="$TMP_ROOT/dedup"
  mkdir -p "$data"
  run_cli "$data" record t1 --title "Broken docs" --evidence "README.md:3" \
    --disposition "fix link" >/dev/null || fail "dedup setup record failed"
  file="$data/t1/findings.md"
  out=$(run_cli "$data" record t1 --title "broken DOCS" --evidence "README.md:3" \
    --disposition "irrelevant on dedup") || fail "identical duplicate refused: $out"
  assert_contains "$out" "already recorded: broken-docs" "dedup did not report the no-op"
  [ "$(grep -c '^## finding: ' "$file")" = 1 ] || fail "identical duplicate appended a second entry"
  # Same slug, different evidence must refuse without writing.
  set +e
  out=$(run_cli "$data" record t1 --title "Broken docs" --evidence "README.md:9" --disposition "x" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "same slug with different evidence must refuse"
  assert_contains "$out" "more specific title" "refusal did not tell the worker what to do"
  [ "$(grep -c '^## finding: ' "$file")" = 1 ] || fail "refused record still wrote an entry"
  pass "record dedups identical evidence and refuses slug collisions"
}

test_record_malformed_input() {
  local data out rc file
  data="$TMP_ROOT/malformed"
  mkdir -p "$data"
  file="$data/t1/findings.md"
  set +e
  out=$(run_cli "$data" record t1 --title "x" --disposition "d" 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing evidence must refuse"
  assert_contains "$out" "--evidence is required" "missing-evidence error unhelpful"
  out=$(run_cli "$data" record t1 --title "x" --evidence "e" 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing disposition must refuse"
  out=$(run_cli "$data" record t1 --title "   " --evidence "e" --disposition "d" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a title that slugs to nothing must refuse"
  out=$(run_cli "$data" record t1 --title "x" --evidence $'line1\nline2' --disposition "d" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a multiline field must refuse"
  out=$(run_cli "$data" record t1 --title "x" --evidence "e" --disposition "d" --context $'a\nb' 2>&1)
  rc=$?
  expect_code 1 "$rc" "a multiline context must refuse"
  set -e
  assert_absent "$file" "malformed records must not create the findings file"
  pass "record refuses malformed input without writing"
}

# --- triage ------------------------------------------------------------------

test_triage_closes_entries() {
  local data out rc
  data="$TMP_ROOT/triage"
  mkdir -p "$data"
  run_cli "$data" record t1 --title "Broken docs" --evidence "README.md:3" \
    --disposition "fix link" >/dev/null
  set +e
  out=$(run_cli "$data" triage t1 broken-docs --note "" 2>&1)
  rc=$?
  expect_code 1 "$rc" "triage without a note must refuse"
  out=$(run_cli "$data" triage t1 no-such-slug --note "x" 2>&1)
  rc=$?
  expect_code 1 "$rc" "triage of an unknown slug must refuse"
  set -e
  out=$(run_cli "$data" triage t1 broken-docs \
    --note 'queued as \n backlog fix-docs-2') || fail "triage failed: $out"
  assert_contains "$out" "triaged: broken-docs" "triage did not confirm"
  local list
  list=$(run_cli "$data" list) || fail "list after triage failed"
  assert_not_contains "$list" "broken-docs" "triaged entry still listed as pending"
  # The backslash-bearing note must survive verbatim (it travels through the
  # environment, never through awk -v escape processing).
  assert_grep 'queued as \n backlog fix-docs-2' "$data/t1/findings.md" \
    "triage note was mangled"
  assert_grep "- status: triaged " "$data/t1/findings.md" "status line not rewritten"
  # Double triage refuses loudly rather than pretending to work.
  set +e
  out=$(run_cli "$data" triage t1 broken-docs --note "again" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "double triage must refuse"
  assert_contains "$out" "already triaged" "double-triage refusal unclear"
  pass "triage closes an entry once, with the note preserved verbatim"
}

# --- malformed files ---------------------------------------------------------

test_malformed_files_degrade_safely() {
  local data out rc
  data="$TMP_ROOT/malformed-files"
  mkdir -p "$data/t3" "$data/t4"
  run_cli "$data" record t1 --title "Real one" --evidence "f:1" --disposition "fix" >/dev/null
  # Pure garbage: no entries, no crash.
  printf 'this is garbage\nno headers at all\n' > "$data/t3/findings.md"
  # Mangled entries: an unnamed header and an entry with no status line.
  printf 'stray text\n\n## finding: \n- evidence: x\n\n## finding: no-status\n- evidence: y\n' \
    > "$data/t4/findings.md"
  out=$(run_cli "$data" list) || fail "list crashed on malformed files: $out"
  assert_contains "$out" "t1/real-one" "a healthy entry was lost beside malformed ones"
  assert_contains "$out" "malformed unnamed entry" "an unnamed mangled entry vanished instead of surfacing"
  assert_contains "$out" "t4/no-status" "an entry with no status line must surface (pending default)"
  # The pending-default entry stays triageable.
  out=$(run_cli "$data" triage t4 no-status --note "dismissed: dup of queued work") \
    || fail "triage of a status-less entry failed: $out"
  out=$(run_cli "$data" list t4) || fail "list after malformed triage failed"
  assert_not_contains "$out" "no-status" "triaged malformed entry still listed"
  pass "malformed files never crash the scan and never hide entries"
}

test_listing_is_bounded() {
  local data out shown
  data="$TMP_ROOT/bounded"
  mkdir -p "$data"
  local i=0
  while [ "$i" -lt 14 ]; do
    run_cli "$data" record "task$i" --title "Finding $i" --evidence "f:$i" \
      --disposition "do $i" >/dev/null
    i=$((i + 1))
  done
  out=$(run_cli "$data" list) || fail "bounded list failed: $out"
  shown=$(printf '%s\n' "$out" | grep -c '^- ')
  [ "$shown" -le 13 ] || fail "fleet listing showed $shown entries, cap is 12 plus a remainder line"
  assert_contains "$out" "and 2 more" "the bounded listing did not disclose its remainder"
  pass "the fleet listing bounds its output and discloses the remainder"
}

# --- teardown preservation ---------------------------------------------------

# Minimal teardown fixture in the shape of tests/fm-teardown.test.sh's
# make_case: fakebin mocks, a bare origin, a project clone, a task worktree
# whose branch is pushed to a fork (local-only ALLOW), and a task meta.
# Echoes the case dir.
make_teardown_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin"/*
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fix the thing"
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
  # Keep the backlog hermetic: the operator closes it by hand.
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=findings-test-task-x1"
  printf '%s\n' "$case_dir"
}

run_teardown_case() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

test_teardown_preserves_and_surfaces_findings() {
  local case_dir out rc
  case_dir=$(make_teardown_case findings-preserve)
  run_cli "$case_dir/data" record task-x1 --title "Adjacent broken test" \
    --evidence "tests/other.test.sh:44" --disposition "file a follow-up fix" \
    --context "while shipping the findings channel" >/dev/null
  set +e
  out=$(run_teardown_case "$case_dir" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown with a findings file must succeed"
  assert_present "$case_dir/data/task-x1/findings.md" \
    "cleanup destroyed the findings file; a finding must survive like a report"
  assert_grep "## finding: adjacent-broken-test" "$case_dir/data/task-x1/findings.md" \
    "the surviving findings file lost its entry"
  assert_contains "$out" "pending incidental findings for task-x1" \
    "teardown did not surface the pending finding"
  assert_contains "$out" "adjacent-broken-test" "the surface line omitted the slug"
  pass "cleanup preserves the findings file and surfaces pending entries"
}

test_teardown_without_findings_stays_silent() {
  local case_dir out rc
  case_dir=$(make_teardown_case findings-silent)
  set +e
  out=$(run_teardown_case "$case_dir" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown without findings must succeed"
  assert_not_contains "$out" "pending incidental findings" \
    "teardown printed a findings surface with no findings file"
  pass "cleanup without findings prints no findings surface"
}

# --- brief scaffolds ---------------------------------------------------------

BRIEF_HOME="$TMP_ROOT/brief-home"
mkdir -p "$BRIEF_HOME/data"

run_brief() { # <args...>
  FM_DATA_OVERRIDE="$BRIEF_HOME/data" "$BRIEF" "$@"
}

test_ship_brief_carries_findings_section() {
  local out brief
  out=$(run_brief fmfind-ship proj-x --mode no-mistakes) || fail "ship scaffold failed: $out"
  brief="$BRIEF_HOME/data/fmfind-ship/brief.md"
  assert_grep "# Incidental findings" "$brief" "ship brief lacks the findings section"
  assert_grep "bin/fm-findings.sh" "$brief" \
    "ship brief does not name the record command"
  assert_grep "record fmfind-ship" "$brief" \
    "ship brief does not tell the worker to record for its own task id"
  assert_grep "findings.md" "$brief" "ship brief does not name the durable file"
  assert_grep "OUTSIDE this task's scope" "$brief" "findings section does not bound the channel to out-of-scope defects"
  pass "ship briefs carry the incidental-findings section"
}

test_scout_and_secondmate_briefs_carry_no_findings_section() {
  local out
  out=$(run_brief fmfind-scout proj-x --scout) || fail "scout scaffold failed: $out"
  assert_absent "$BRIEF_HOME/data/fmfind-scout/findings.md" "scout scaffold wrote a findings file"
  ! grep -q "# Incidental findings" "$BRIEF_HOME/data/fmfind-scout/brief.md" \
    || fail "scout brief must not carry the findings section (its report is the channel)"
  out=$(FM_SECONDMATE_CHARTER="watch the domain" run_brief fmfind-mate proj-x proj-x --secondmate) \
    || fail "secondmate scaffold failed: $out"
  ! grep -q "# Incidental findings" "$BRIEF_HOME/data/fmfind-mate/brief.md" \
    || fail "secondmate charter must not carry the findings section"
  pass "scout and secondmate scaffolds stay findings-free"
}

# --- lib unit seams ----------------------------------------------------------

test_slug_rules() {
  # shellcheck source=bin/fm-findings-lib.sh
  . "$FINDINGS_LIB"
  local s
  s=$(fm_findings_slug "  Fix the -- README! (again)  ")
  [ "$s" = "fix-the-readme-again" ] || fail "slug rules produced '$s'"
  s=$(fm_findings_slug "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  [ ${#s} -le 48 ] || fail "slug cap not applied (length ${#s})"
  [ -z "$(fm_findings_slug "!!!")" ] || fail "a symbol-only title must slug to nothing"
  pass "slug rules normalize, cap, and refuse symbol-only titles"
}

test_brief_record_command_binds_the_scaffold_home() {
  local out brief cmd other
  out=$(run_brief fmfind-bind proj-x --mode no-mistakes) || fail "ship scaffold failed: $out"
  brief="$BRIEF_HOME/data/fmfind-bind/brief.md"
  # The brief is this scaffold's generated interface to the worker; run the
  # command it emits the way a worker pane would - from an environment that
  # names a DIFFERENT firstmate home, as a crewmate daemon's pane does.
  # shellcheck disable=SC2016 # sed, not the shell, expands the capture.
  cmd=$(sed -n 's/^Run: `\(.*\)`$/\1/p' "$brief")
  [ -n "$cmd" ] || fail "ship brief emits no runnable record command"
  local prefix="${cmd%% --title *}"
  [ "$prefix" != "$cmd" ] || fail "the emitted record command has no --title placeholder"
  other="$TMP_ROOT/other-home"
  mkdir -p "$other/data"
  out=$(env -u FM_DATA_OVERRIDE FM_HOME="$other" bash -c \
    "$prefix --title 'Adjacent flaky test' --evidence 'tests/x.sh:4' --disposition 'file a fix task'" 2>&1) \
    || fail "the emitted record command failed: $out"
  assert_present "$BRIEF_HOME/data/fmfind-bind/findings.md" \
    "the emitted command did not write into the scaffolding home"
  assert_absent "$other/data/fmfind-bind/findings.md" \
    "the emitted command wrote the finding into the ambient home instead"
  pass "the brief's record command binds the scaffolding home's data dir"
}

test_empty_status_entry_stays_triageable() {
  local data out
  data="$TMP_ROOT/empty-status"
  mkdir -p "$data/t1"
  printf '## finding: torn-entry\n- status:\n- evidence: a.sh:1\n- suggested-disposition: look\n\n' \
    > "$data/t1/findings.md"
  out=$(run_cli "$data" list t1) || fail "listing an empty-status entry failed: $out"
  assert_contains "$out" "torn-entry" "an empty status value must surface as pending"
  out=$(run_cli "$data" triage t1 torn-entry --note "dismissed: already tracked") \
    || fail "an empty-status entry must stay triageable: $out"
  out=$(run_cli "$data" list t1)
  assert_not_contains "$out" "torn-entry" "the triaged empty-status entry still surfaces"
  pass "an entry whose status value is empty is pending and closable"
}

test_record_after_triage_reopens() {
  local data out
  data="$TMP_ROOT/reopen"
  mkdir -p "$data"
  run_cli "$data" record t1 --title "Adjacent bug" --evidence "a.sh:1" \
    --disposition "file a fix task" >/dev/null || fail "first record failed"
  run_cli "$data" triage t1 adjacent-bug --note "dismissed: intentional" >/dev/null \
    || fail "triage failed"
  out=$(run_cli "$data" record t1 --title "Adjacent bug" --evidence "a.sh:1" \
    --disposition "file a fix task") || fail "re-record after triage failed: $out"
  assert_contains "$out" "recorded: adjacent-bug" \
    "a re-observation after a dismissal must append a fresh entry, not no-op"
  out=$(run_cli "$data" list t1) || fail "the reopened finding did not surface: $out"
  assert_contains "$out" "adjacent-bug" "the reopened finding is not pending"
  pass "recording a dismissed slug again reopens it as a fresh pending entry"
}

test_record_trims_field_whitespace() {
  local data out
  data="$TMP_ROOT/trim"
  mkdir -p "$data"
  run_cli "$data" record t1 --title "Spaced evidence" --evidence "README.md:12 " \
    --disposition " fix the pip command " >/dev/null || fail "first record failed"
  grep -qx -- "- evidence: README.md:12" "$data/t1/findings.md" \
    || fail "trailing blanks were written into the evidence line"
  grep -qx -- "- suggested-disposition: fix the pip command" "$data/t1/findings.md" \
    || fail "surrounding blanks were written into the disposition line"
  out=$(run_cli "$data" record t1 --title "Spaced evidence" --evidence "README.md:12 " \
    --disposition "fix the pip command") || fail "byte-identical re-record was refused: $out"
  assert_contains "$out" "already recorded: spaced-evidence" \
    "whitespace-only difference must be an idempotent no-op, not a refusal"
  pass "record trims field whitespace once, so dedup compares what was written"
}

test_triage_waits_for_a_concurrent_record() {
  local data file lock triage_out rc
  data="$TMP_ROOT/serialize"
  mkdir -p "$data"
  run_cli "$data" record t1 --title "First finding" --evidence "a.sh:1" \
    --disposition "file a fix task" >/dev/null || fail "seed record failed"
  file="$data/t1/findings.md"
  lock="$file.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$lock" || fail "the test could not take the findings lock"
  triage_out="$TMP_ROOT/serialize.triage.out"
  ( run_cli "$data" triage t1 first-finding --note "filed as FM-9" >"$triage_out" 2>&1 ) &
  local triage_pid=$!
  sleep 1
  kill -0 "$triage_pid" 2>/dev/null \
    || fail "triage rewrote the file while another writer held the task's lock"
  # The append a worker's record would have made inside triage's read window.
  printf '## finding: second-finding\n- status: pending\n- recorded: %s\n- evidence: b.sh:2\n- suggested-disposition: file another\n\n' \
    "2026-01-01T00:00:00Z" >> "$file"
  fm_lock_release "$lock"
  set +e
  wait "$triage_pid"
  rc=$?
  set -e
  expect_code 0 "$rc" "triage failed once the lock was free: $(cat "$triage_out")"
  assert_grep "- status: triaged " "$file" "triage did not close the first finding"
  grep -qx -- "## finding: second-finding" "$file" \
    || fail "triage's rewrite discarded the entry appended while it waited"
  pass "record and triage serialize, so a rewrite cannot drop a concurrent append"
}

test_record_refuses_a_task_id_that_is_not_one_path_component() {
  local data out rc
  data="$TMP_ROOT/bad-id"
  mkdir -p "$data"
  for bad in "t1/sub" "../escaped" ".." "." ".scratch"; do
    set +e
    out=$(run_cli "$data" record "$bad" --title "Adjacent bug" \
      --evidence "a.sh:1" --disposition "file it" 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "record accepted the unsafe task id '$bad': $out"
    assert_contains "$out" "invalid task id" "record did not name the bad id '$bad'"
  done
  assert_absent "$data/t1/sub/findings.md" "record created a nested findings file"
  assert_absent "$(dirname "$data")/escaped/findings.md" \
    "record wrote a findings file outside the data dir"
  # A dot-leading id is one path component, but the pending scan's glob never
  # matches it, so accepting it would record a finding nothing can surface.
  assert_absent "$data/.scratch/findings.md" \
    "record wrote a findings file the pending scan can never reach"
  out=$(run_cli "$data" list) || true
  assert_contains "$out" "no pending incidental findings" \
    "a refused record must leave nothing behind"
  set +e
  out=$(run_cli "$data" triage "t1/sub" some-slug --note "n" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "triage accepted an unsafe task id: $out"
  assert_contains "$out" "invalid task id" "triage did not name the bad id"
  pass "record and triage refuse a task id the pending scan could not reach"
}

test_record_refuses_a_unit_separator_in_a_field() {
  local data out rc sep
  data="$TMP_ROOT/unit-sep"
  mkdir -p "$data"
  sep=$(printf 'a\037b')
  set +e
  out=$(run_cli "$data" record t8 --title "Sep bug" --evidence "$sep" \
    --disposition "REAL DISPOSITION" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a field carrying the unit separator was recorded: $out"
  assert_absent "$data/t8/findings.md" "the refused record still wrote a file"
  # The same observation with a clean evidence line surfaces its real
  # disposition, not a shifted field.
  run_cli "$data" record t8 --title "Sep bug" --evidence "a b" \
    --disposition "REAL DISPOSITION" >/dev/null || fail "the clean record failed"
  out=$(run_cli "$data" list t8) || fail "listing failed: $out"
  assert_contains "$out" "sep-bug (2" "the clean entry did not surface"
  assert_contains "$out" "REAL DISPOSITION" "the surfaced disposition was shifted"
  pass "the unit separator is rejected where the field contract claims it is"
}

test_triage_inserts_a_missing_status_inside_its_block() {
  local data out
  data="$TMP_ROOT/stamp-placement"
  mkdir -p "$data/t9"
  local file="$data/t9/findings.md"
  printf '## finding: no-status\n- evidence: y\n\n## finding: other\n- status: pending\n- evidence: z\n\n' \
    > "$file"
  out=$(run_cli "$data" triage t9 no-status --note "dismissed") \
    || fail "triaging a status-less entry failed: $out"
  # The stamp belongs on the line right after its own header, exactly where
  # fm_findings_record writes the status line.
  local after
  after=$(awk '/^## finding: no-status$/ { getline; print; exit }' "$file")
  case "$after" in
    "- status: triaged "*" -- dismissed") ;;
    *) fail "the triage stamp did not land under its header (got: '$after')" ;;
  esac
  assert_grep "- evidence: y" "$file" "the block body was lost"
  # The blank separator between the two blocks survives the rewrite.
  local blanks
  blanks=$(grep -c '^$' "$file")
  assert_equals 2 "$blanks" "the blank separators between blocks were mangled"
  out=$(run_cli "$data" list t9) || fail "listing after triage failed: $out"
  assert_not_contains "$out" "no-status" "the triaged entry still surfaces"
  assert_contains "$out" "other" "triage closed an unrelated entry"
  pass "an inserted status line stays inside its own block"
}

test_torn_entry_never_blocks_a_retry() {
  local data out file
  data="$TMP_ROOT/torn-entry"
  mkdir -p "$data/t1"
  file="$data/t1/findings.md"
  # The crashed-record shapes: the append is one block, so a kill mid-write
  # can leave the evidence or the disposition line unwritten.
  printf '## finding: adj-bug\n- status: pending\n- recorded: 2026-01-01T00:00:00Z\n\n' \
    > "$file"
  out=$(run_cli "$data" record t1 --title "Adj bug" --evidence "a.sh:1" \
    --disposition "file it") \
    || fail "a retry after a torn entry was refused: $out"
  assert_contains "$out" "recorded: adj-bug" "the retry did not append a whole entry"
  out=$(run_cli "$data" list t1) || fail "listing failed: $out"
  assert_contains "$out" "file it" "the complete entry's disposition never surfaced"

  local data2 file2
  data2="$TMP_ROOT/torn-entry-disposition"
  mkdir -p "$data2/t1"
  file2="$data2/t1/findings.md"
  printf '## finding: adj-bug\n- status: pending\n- recorded: 2026-01-01T00:00:00Z\n- evidence: a.sh:1\n\n' \
    > "$file2"
  out=$(run_cli "$data2" record t1 --title "Adj bug" --evidence "a.sh:1" \
    --disposition "file it") \
    || fail "a retry after a disposition-less entry failed: $out"
  assert_contains "$out" "recorded: adj-bug" \
    "the retry reported success without appending the missing disposition"
  out=$(run_cli "$data2" list t1) || fail "listing failed: $out"
  assert_contains "$out" "file it" "firstmate still reads no disposition for the slug"
  # A complete pending entry still dedups, so the fall-through is scoped to
  # torn blocks only.
  out=$(run_cli "$data2" record t1 --title "Adj bug" --evidence "a.sh:1" \
    --disposition "file it") || fail "the complete-entry dedup broke: $out"
  assert_contains "$out" "already recorded" "a complete duplicate stopped deduping"
  pass "a torn entry neither blocks nor silently absorbs the retry"
}

test_brief_record_command_binds_the_scaffold_state_dir() {
  local out brief cmd prefix other state
  state="$TMP_ROOT/brief-state"
  mkdir -p "$state"
  out=$(FM_STATE_OVERRIDE="$state" run_brief fmfind-state proj-x --mode no-mistakes) \
    || fail "ship scaffold failed: $out"
  brief="$BRIEF_HOME/data/fmfind-state/brief.md"
  # shellcheck disable=SC2016 # sed, not the shell, expands the capture.
  cmd=$(sed -n 's/^Run: `\(.*\)`$/\1/p' "$brief")
  prefix="${cmd%% --title *}"
  [ "$prefix" != "$cmd" ] || fail "the emitted record command has no --title placeholder"
  other="$TMP_ROOT/state-other-home"
  mkdir -p "$other/data"
  out=$(env -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$other" bash -c \
    "$prefix --title 'Adjacent doc error' --evidence 'README.md:3' --disposition 'fix the link'" 2>&1) \
    || fail "the emitted record command failed: $out"
  assert_present "$BRIEF_HOME/data/fmfind-state/findings.md" \
    "the emitted command did not write into the scaffolding home"
  assert_absent "$other/state" \
    "the emitted command created a state dir in the ambient home"
  pass "the brief's record command binds the scaffolding home's state dir"
}

test_promoted_record_command_binds_the_promoting_home() {
  local home other out cmd prefix instructions
  home="$TMP_ROOT/promote-home"
  mkdir -p "$home/state" "$home/data/fmfind-promo"
  printf 'You are a crewmate.\n\n# Task\n## Captain'"'"'s intent\nScout the area.\n\n## Firstmate spec\nInvestigate.\n\n# Definition of done\n' \
    > "$home/data/fmfind-promo/brief.md"
  printf 'window=fm-fmfind-promo\nkind=scout\nworktree=/tmp/wt\n' > "$home/state/fmfind-promo.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" fmfind-promo --mode no-mistakes --yolo off 2>&1) || fail "promotion failed: $out"
  instructions="$home/data/fmfind-promo/ship-instructions.md"
  # The promoted instructions are the promote script's generated interface to
  # the crewmate; run the command they emit the way the pane would - from an
  # environment that names a DIFFERENT firstmate home.
  # shellcheck disable=SC2016 # sed, not the shell, expands the capture.
  cmd=$(sed -n 's/^.*run `\(.*\)` to append.*$/\1/p' "$instructions")
  [ -n "$cmd" ] || fail "promoted instructions emit no runnable record command"
  prefix="${cmd%% --title *}"
  [ "$prefix" != "$cmd" ] || fail "the emitted record command has no --title placeholder"
  other="$TMP_ROOT/promote-other-home"
  mkdir -p "$other/data"
  out=$(env -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$other" bash -c \
    "$prefix --title 'Adjacent flaky test' --evidence 'tests/x.sh:4' --disposition 'file a fix task'" 2>&1) \
    || fail "the emitted record command failed: $out"
  assert_present "$home/data/fmfind-promo/findings.md" \
    "the emitted command did not write into the promoting home"
  assert_absent "$other/data/fmfind-promo/findings.md" \
    "the emitted command wrote the finding into the ambient home instead"
  assert_absent "$other/state" \
    "the emitted command created a state dir in the ambient home"
  pass "the promoted ship instructions bind the promoting home"
}

test_slug_rules
test_record_happy_path
test_record_dedup
test_record_malformed_input
test_triage_closes_entries
test_malformed_files_degrade_safely
test_listing_is_bounded
test_teardown_preserves_and_surfaces_findings
test_teardown_without_findings_stays_silent
test_ship_brief_carries_findings_section
test_scout_and_secondmate_briefs_carry_no_findings_section
test_brief_record_command_binds_the_scaffold_home
test_empty_status_entry_stays_triageable
test_record_after_triage_reopens
test_record_trims_field_whitespace
test_triage_waits_for_a_concurrent_record
test_record_refuses_a_task_id_that_is_not_one_path_component
test_record_refuses_a_unit_separator_in_a_field
test_triage_inserts_a_missing_status_inside_its_block
test_torn_entry_never_blocks_a_retry
test_brief_record_command_binds_the_scaffold_state_dir
test_promoted_record_command_binds_the_promoting_home
