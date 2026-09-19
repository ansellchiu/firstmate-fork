#!/usr/bin/env bash
# tests/fm-wake-batching.test.sh - routine-wake coalescing and changed-record
# rehydration (bin/fm-classify-lib.sh's "routine-wake coalescing" section, plus
# the wake-time wiring in bin/fm-push-transition-lib.sh).
#
# The contract under test:
#   1. A burst of N absorbed routine events yields bounded local telemetry and
#      no notification merely because its timer elapsed.
#   2. Captain-relevant, check-kind, and uncertain events are never batched.
#   3. A batched presentation names only the records that actually changed, so
#      the supervision turn rehydrates those and skips the quiet rest.
#   4. Batching does not alter admission: an immediate wake carries any pending
#      telemetry out with it, while a quiet rollover stays local and the durable
#      queue is untouched by any of this.
#
# These drive the real functions over a hermetic state directory. The watcher's
# own absorb-path wiring is covered behaviorally by tests/fm-watch-triage.test.sh
# (which asserts absorbed events still do not exit the cycle).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-batching-tests)
CASE_N=0

# Each case gets its own state directory. CASE_N is bumped by the caller, not
# inside the command substitution, because a subshell increment would not stick
# and every case would silently share one directory.
new_state() {
  local state="$TMP_ROOT/case-$CASE_N"
  mkdir -p "$state"
  printf '%s' "$state"
}

# A minimal active record: metadata makes the task active, the status log is
# what a routine append moves.
make_record() {  # <state> <task> [status-line]
  local state=$1 task=$2 line=${3:-}
  printf 'kind=crew\n' > "$state/$task.meta"
  if [ -n "$line" ]; then printf '%s\n' "$line" > "$state/$task.status"; fi
}

# --- 1. urgency classification ---------------------------------------------

test_only_certified_routine_evidence_batches() {
  local kind evidence

  for kind in signal stale heartbeat; do
    for evidence in nonterminal unchanged; do
      [ "$(wake_event_urgency "$kind" "$evidence")" = routine ] \
        || fail "$kind/$evidence was not treated as routine"
    done
    for evidence in actionable unknown '' garbage; do
      [ "$(wake_event_urgency "$kind" "$evidence")" = immediate ] \
        || fail "$kind/'$evidence' was batched instead of delivered immediately"
    done
  done

  # check-kind is captain-facing by construction: a merge result, a Relay
  # mention, a credential need, an inbox note. It never batches, whatever
  # evidence a caller offers.
  for evidence in nonterminal unchanged actionable unknown; do
    [ "$(wake_event_urgency check "$evidence")" = immediate ] \
      || fail "a check wake with '$evidence' evidence was batched"
  done

  # An unrecognized kind is uncertain, so it is immediate too.
  [ "$(wake_event_urgency procevent nonterminal)" = immediate ] \
    || fail "an unknown wake kind was batched"

  pass "only certified-routine signal/stale/heartbeat evidence is batchable"
}

test_window_zero_disables_batching() {
  FM_WAKE_BATCH_WINDOW=0 wake_event_is_routine signal nonterminal \
    && fail "batching stayed on with a zero window"
  FM_WAKE_BATCH_WINDOW=60 wake_event_is_routine signal nonterminal \
    || fail "a positive window did not enable batching"
  # A malformed override is not a window: it must fall back to the default
  # rather than silently disabling batching or freezing the batch forever.
  [ "$(FM_WAKE_BATCH_WINDOW=later wake_batch_window)" = "$FM_WAKE_BATCH_WINDOW_DEFAULT" ] \
    || fail "a malformed window override did not fall back to the default"
  [ "$(FM_WAKE_BATCH_WINDOW=-5 wake_batch_window)" = "$FM_WAKE_BATCH_WINDOW_DEFAULT" ] \
    || fail "a negative window override did not fall back to the default"
  pass "the batching window is env-overridable and 0 disables batching"
}

# --- 2. coalescing ----------------------------------------------------------

test_burst_of_routine_events_yields_one_bounded_presentation() {
  local state opened i out header
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  export FM_WAKE_BATCH_WINDOW=120

  for i in 1 2 3 4 5 6 7; do
    wake_batch_record "$state" signal "alpha.status" "working: step $i"
  done
  wake_batch_record "$state" stale "fm:beta" "idle pane, provably working"

  [ "$(wake_batch_pending_count "$state")" = 8 ] \
    || fail "the batch did not count all 8 routine events: $(wake_batch_pending_count "$state")"

  # Still inside the window: nothing is due, so the cycle keeps polling and no
  # turn is spent.
  opened=$(wake_batch_opened_at "$state") || fail "the window opened-at marker was not written"
  wake_batch_due "$state" "$((opened + 119))" \
    && fail "the batch presented before its window elapsed"
  wake_batch_due "$state" "$((opened + 120))" \
    || fail "the batch was not due once its window elapsed"

  out=$(wake_batch_presentation "$state" "$((opened + 130))") \
    || fail "a due batch produced no presentation"

  header=$(printf '%s\n' "$out" | head -1)
  case "$header" in
    "heartbeat: batched routine activity: 8 event(s) over 130s"*) ;;
    *) fail "the summary header did not carry the true burst size and span: $header" ;;
  esac

  # One presentation for the whole burst: the seven same-source signals collapse
  # to a single counted line, not seven.
  [ "$(printf '%s\n' "$out" | grep -c '^  batched ')" = 2 ] \
    || fail "the burst was not collapsed to one line per source: $out"
  printf '%s\n' "$out" | grep -q '^  batched signal x7 alpha.status: working: step 7$' \
    || fail "the repeated signal source was not collapsed with its count and latest detail: $out"
  printf '%s\n' "$out" | grep -q '^  batched stale fm:beta: idle pane, provably working$' \
    || fail "the stale source was not summarized: $out"

  # Presented means consumed: the next cycle starts a fresh window.
  [ "$(wake_batch_pending_count "$state")" = 0 ] \
    || fail "the batch was not cleared after presentation"
  wake_batch_due "$state" && fail "an empty batch reported itself due"
  wake_batch_presentation "$state" >/dev/null \
    && fail "an empty batch produced a presentation"

  unset FM_WAKE_BATCH_WINDOW
  pass "a burst of routine events yields one bounded presentation, then a fresh window"
}

test_summary_is_bounded_by_row_and_line_caps() {
  local state i out
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  export FM_WAKE_BATCH_WINDOW=1 FM_WAKE_BATCH_MAX_ROWS=5 FM_WAKE_BATCH_SUMMARY_MAX=2

  for i in 1 2 3 4 5 6 7 8; do
    wake_batch_record "$state" signal "task-$i.status" "working: $i"
  done

  # Three rows past the cap are dropped, but the burst's true size is not: a
  # supervisor must still see how much traffic this represents.
  [ "$(wake_batch_pending_count "$state")" = 8 ] \
    || fail "overflowed rows were not counted: $(wake_batch_pending_count "$state")"

  out=$(wake_batch_presentation "$state") || fail "no presentation for a capped batch"
  printf '%s\n' "$out" | head -1 | grep -q '8 event(s)' \
    || fail "the header lost the overflowed events: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^  batched ')" = 2 ] \
    || fail "the summary printed more detail lines than its cap: $out"
  printf '%s\n' "$out" | grep -q '^  batched: 3 more distinct source(s) omitted (summary cap)$' \
    || fail "the omitted-source count was not reported: $out"

  unset FM_WAKE_BATCH_WINDOW FM_WAKE_BATCH_MAX_ROWS FM_WAKE_BATCH_SUMMARY_MAX
  pass "the summary is bounded by both the row cap and the detail-line cap, and says what it dropped"
}

test_a_corrupt_window_marker_surfaces_instead_of_holding() {
  local state
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  export FM_WAKE_BATCH_WINDOW=99999
  wake_batch_record "$state" signal "alpha.status" "working: one"
  wake_batch_due "$state" && fail "a fresh batch was due under a long window"
  printf 'not-an-epoch\n' > "$state/.wake-batch-opened"
  wake_batch_due "$state" \
    || fail "a batch with an unreadable window marker was held instead of surfaced"
  unset FM_WAKE_BATCH_WINDOW
  pass "a corrupt window marker surfaces the batch rather than holding it forever"
}

# --- 3. changed-record rehydration ------------------------------------------

test_only_changed_active_records_are_rehydrated() {
  local state changed line
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  make_record "$state" alpha 'working: start'
  make_record "$state" beta 'working: start'
  make_record "$state" gamma

  # First observation: every record is new, so every record is named once.
  changed=$(wake_changed_records "$state" | LC_ALL=C sort | tr '\n' ' ')
  [ "$changed" = "alpha beta gamma " ] \
    || fail "the first diff did not name every active record: '$changed'"

  wake_commit_record_manifest "$state"
  [ -z "$(wake_changed_records "$state")" ] \
    || fail "an unchanged fleet still reported changed records"

  # Only beta moves.
  sleep 1
  printf 'working: more\n' >> "$state/beta.status"
  changed=$(wake_changed_records "$state" | tr '\n' ' ')
  [ "$changed" = "beta " ] \
    || fail "the diff did not isolate the one record that moved: '$changed'"

  line=$(wake_rehydration_line "$state")
  case "$line" in
    "changed records: beta - rehydrate only these"*) ;;
    *) fail "the rehydration line did not name only the changed record: $line" ;;
  esac

  # The line commits, so the next diff is quiet.
  line=$(wake_rehydration_line "$state")
  case "$line" in
    "changed records: none - rehydrate nothing"*) ;;
    *) fail "an unchanged fleet did not report a no-op rehydration: $line" ;;
  esac

  # A retired record leaves no entry to diff against forever, and a brand new
  # one is named once.
  rm -f "$state/gamma.meta"
  make_record "$state" delta 'working: fresh'
  changed=$(wake_changed_records "$state" | tr '\n' ' ')
  [ "$changed" = "delta " ] \
    || fail "record retirement or arrival was not handled: '$changed'"

  pass "only changed active records are rehydrated; retired ones drop out"
}

test_an_unreadable_record_reads_as_changed() {
  local state
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  make_record "$state" alpha 'working: start'
  wake_commit_record_manifest "$state"
  [ -z "$(wake_changed_records "$state")" ] || fail "a settled fleet reported a change"
  rm -f "$state/alpha.status"
  [ "$(wake_changed_records "$state")" = alpha ] \
    || fail "a record whose status log vanished did not read as changed"
  pass "a record that becomes unreadable reads as changed and gets looked at"
}

test_a_batched_presentation_carries_its_rehydration_line() {
  local state out
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  export FM_WAKE_BATCH_WINDOW=1
  make_record "$state" alpha 'working: start'
  make_record "$state" beta 'working: start'
  wake_commit_record_manifest "$state"
  sleep 1
  printf 'working: more\n' >> "$state/alpha.status"
  wake_batch_record "$state" signal "alpha.status" "working: more"

  out=$(wake_batch_presentation "$state") || fail "no presentation produced"
  printf '%s\n' "$out" | grep -q '^changed records: alpha - rehydrate only these' \
    || fail "the presentation did not carry a changed-record rehydration line: $out"
  printf '%s\n' "$out" | grep -q 'beta' \
    && fail "the presentation named an unchanged record: $out"

  unset FM_WAKE_BATCH_WINDOW
  pass "a batched presentation carries the changed-record rehydration line"
}

# --- 4. wake-time wiring ----------------------------------------------------

# Drive the real wake_batch_absorbed / wake from
# bin/fm-push-transition-lib.sh with a recording wake callback, so the exit
# contract is observable without ending the test process.
wiring_harness() {  # <state> <script>
  local state=$1 script=$2
  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-push-transition-lib.sh"
    WAKES="$2/wakes"
    : > "$WAKES"
    # Replace only the delivery half: wake() itself - including the pending-batch
    # fold this suite is here to prove - stays the real production function.
    wake_deliver() {
      printf "%s\n--\n" "$1" >> "$WAKES"
      return 0
    }
    eval "$3"
  ' _ "$ROOT" "$state" "$script"
}

test_immediate_events_are_never_folded_into_the_batch() {
  local state wakes
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  # The absorbed fold is the only batching call site in production, and it
  # re-checks urgency itself: a check-kind or unrecognized-kind event must fall
  # straight through it, leaving the caller's own wake the thing that delivers.
  # shellcheck disable=SC2016 # The script runs in the harness's child shell.
  FM_WAKE_BATCH_WINDOW=600 wiring_harness "$state" '
    wake_batch_absorbed check pr-poll "merged"
    wake_batch_absorbed procevent fm:beta "unknown"
    [ "$(wc -l < "$WAKES" | tr -d "[:space:]")" = 0 ] || { echo "rang early" >&2; exit 1; }
    wake "check: pr-poll merged"
    wake "stale: fm:beta"
  ' || fail "the wiring harness failed"
  wakes="$state/wakes"
  [ "$(wake_batch_pending_count "$state")" = 0 ] \
    || fail "an immediate event was recorded into the batch"
  [ "$(grep -c -- '^--$' "$wakes")" = 2 ] \
    || fail "captain-relevant and uncertain events did not all ring immediately: $(cat "$wakes")"
  grep -Fxq 'check: pr-poll merged' "$wakes" || fail "the check wake was not delivered verbatim"
  grep -Fxq 'stale: fm:beta' "$wakes" || fail "the uncertain stale was not delivered verbatim"
  pass "check-kind and uncertain events are never folded into the batch and ring verbatim"
}

test_due_absorbed_events_roll_into_local_telemetry_without_a_wake() {
  local state wakes triage
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  make_record "$state" alpha 'working: start'
  # The first three events record silently inside a long window. Aging the
  # window marker (rather than sleeping through a real one) makes "the window
  # elapsed" exact instead of a timing race, so the fourth event is the one that
  # closes the quiet telemetry window.
  # shellcheck disable=SC2016 # The script runs in the harness's child shell.
  FM_WAKE_BATCH_WINDOW=600 wiring_harness "$state" '
    wake_batch_absorbed signal alpha.status "progress only"
    wake_batch_absorbed signal alpha.status "progress only"
    wake_batch_absorbed stale fm:beta "idle pane, provably working"
    [ "$(wc -l < "$WAKES" | tr -d "[:space:]")" = 0 ] || { echo "rang early" >&2; exit 1; }
    printf "%s\n" "$(( $(date +%s) - 601 ))" > "$STATE/.wake-batch-opened"
    wake_batch_absorbed heartbeat heartbeat "fleet scan found no captain-relevant change"
  ' || fail "the absorbed-event wiring failed"
  wakes="$state/wakes"
  [ "$(grep -c -- '^--$' "$wakes")" = 0 ] \
    || fail "elapsed time turned an absorbed batch into a notification: $(cat "$wakes")"
  triage="$state/.watch-triage.log"
  grep -q 'closed quiet batch without notification:' "$triage" \
    || fail "the due quiet batch left no local telemetry: $(cat "$triage")"
  grep -q 'heartbeat: batched routine activity: 4 event(s)' "$triage" \
    || fail "the local telemetry lost the absorbed burst count: $(cat "$triage")"
  [ "$(wake_batch_pending_count "$state")" = 0 ] \
    || fail "the due quiet batch did not start a fresh bounded window"
  pass "an absorbed batch stays quiet when due and rolls into bounded local telemetry"
}

test_an_immediate_wake_carries_a_pending_batch_out_with_it() {
  local state wakes
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  make_record "$state" alpha 'working: start'
  # shellcheck disable=SC2016 # The script runs in the harness's child shell.
  FM_WAKE_BATCH_WINDOW=9999 wiring_harness "$state" '
    wake_batch_absorbed signal alpha.status "progress only"
    wake_batch_absorbed stale fm:beta "idle pane, provably working"
    [ "$(wc -l < "$WAKES" | tr -d "[:space:]")" = 0 ] || { echo "rang early" >&2; exit 1; }
    wake "signal: alpha.status"
  ' || fail "the wiring harness failed"
  wakes="$state/wakes"
  [ "$(grep -c -- '^--$' "$wakes")" = 1 ] \
    || fail "the pending batch produced a second wake instead of riding along: $(cat "$wakes")"
  head -1 "$wakes" | grep -q '^heartbeat: batched routine activity: 2 event(s)' \
    || fail "the pending batch was not carried out with the immediate wake: $(cat "$wakes")"
  tail -2 "$wakes" | grep -Fxq 'signal: alpha.status' \
    || fail "the actionable reason was lost behind the batch summary: $(cat "$wakes")"
  [ "$(wake_batch_pending_count "$state")" = 0 ] \
    || fail "the carried-out batch was not cleared"
  pass "an immediate wake carries any pending batch out with it, so no burst is stranded"
}

test_disabled_batching_preserves_the_absorb_contract() {
  local state
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  FM_WAKE_BATCH_WINDOW=0 wiring_harness "$state" '
    wake_batch_absorbed signal alpha.status "progress only"
    wake_batch_absorbed heartbeat heartbeat "no change"
  ' || fail "the wiring harness failed"
  [ "$(grep -c -- '^--$' "$state/wakes")" = 0 ] \
    || fail "a disabled window turned absorbed events into wakes: $(cat "$state/wakes")"
  [ "$(wake_batch_pending_count "$state")" = 0 ] \
    || fail "a disabled window still recorded a batch"
  pass "with batching disabled, an already-absorbed event stays absorbed"
}

test_batching_never_touches_the_durable_queue() {
  local state
  CASE_N=$((CASE_N + 1))
  state=$(new_state)
  make_record "$state" alpha 'working: start'
  FM_WAKE_BATCH_WINDOW=1 wiring_harness "$state" '
    wake_batch_absorbed signal alpha.status "progress only"
    sleep 2
    wake_batch_absorbed signal alpha.status "progress only"
  ' || fail "the wiring harness failed"
  # Coalescing is a presentation layer over the durable queue, never a second
  # queue: it must not create, consume, or rewrite a single durable row.
  [ ! -s "$state/.wake-queue" ] \
    || fail "batching wrote to the durable wake queue: $(cat "$state/.wake-queue")"
  pass "batching is presentation-only and never writes the durable wake queue"
}

test_only_certified_routine_evidence_batches
test_window_zero_disables_batching
test_burst_of_routine_events_yields_one_bounded_presentation
test_summary_is_bounded_by_row_and_line_caps
test_a_corrupt_window_marker_surfaces_instead_of_holding
test_only_changed_active_records_are_rehydrated
test_an_unreadable_record_reads_as_changed
test_a_batched_presentation_carries_its_rehydration_line
test_immediate_events_are_never_folded_into_the_batch
test_due_absorbed_events_roll_into_local_telemetry_without_a_wake
test_an_immediate_wake_carries_a_pending_batch_out_with_it
test_disabled_batching_preserves_the_absorb_contract
test_batching_never_touches_the_durable_queue
