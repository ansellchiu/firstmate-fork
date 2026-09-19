#!/usr/bin/env bash
# tests/fm-spawn-packet.test.sh - the dispatch packet classification boundary
# (the captain's balanced-lane data policy, mechanized at bin/fm-spawn.sh intake).
#
# The brief is the smallest packet the worker will see, so the fixed
# "Packet: class=<ordinary|flagged|prohibited>" line recorded on it governs.
# bin/fm-brief.sh emits the line from --packet; bin/fm-spawn.sh reads the same
# line and enforces the class before any endpoint, worktree, or record exists:
# ordinary stays silent, flagged dispatches normally with the one-line
# China-usage warning in the task record and on the spawn output, and
# prohibited is the one-concise-captain-ask hard stop. The harness, model, and
# backend are never inputs, and no provider name implies a jurisdiction.
#
# Refusal cases run against a fake tmux that exits non-zero, so a case that is
# meant to get past the packet check still creates nothing. Record cases run a
# postcondition-shaped fake so the real fm-spawn publishes state/<id>.meta and
# the test reads the class back from the task record. No live harness required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-packet)
SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF_TOOL="$ROOT/bin/fm-brief.sh"

# A minimal home with a project repo and a fake tmux whose verdict a case
# chooses: refusing (default) or launch-shaped (records the task).
# Echoes "<home>|<project-dir>|<worktree>|<fakebin>|<case-dir>|<id>".
make_home() {  # <name> <launching>
  local name=$1 launching=$2 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  id="$name-z1"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  if [ "$launching" = launch ]; then
    printf 'claude\n' > "$case_dir/fake/pane-command"
    cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) printf '%s\n' "/dev/null/nonexistent"; exit 0 ;;
  *"#{pane_current_command}"*)
    cat "$case_dir/fake/pane-command" 2>/dev/null || printf 'zsh\n'
    exit 0
    ;;
esac
case "\${1:-}" in
  list-windows) [ -f "$case_dir/fake/window-created" ] && printf '%s\n' "fm-$id"; exit 0 ;;
  new-window) : > "$case_dir/fake/window-created"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  # A relaunch types the launch command into the existing pane: simulate the
  # agent taking the foreground so the postcondition sees it come up.
  send-keys) printf 'claude\n' > "$case_dir/fake/pane-command"; exit 0 ;;
  capture-pane) exit 0 ;;
esac
exit 0
SH
    chmod +x "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" treehouse
    cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
    chmod +x "$fakebin/timeout"
    fm_git_worktree "$proj" "$wt" "wt-$name"
  else
    printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
    chmod +x "$fakebin/tmux"
    mkdir -p "$proj"
    git -C "$proj" init -q || fail "could not initialize project fixture"
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$case_dir" "$id"
}

write_brief() {  # <home> <id> <packet-header-lines|-> [<secret-marker>]
  local home=$1 id=$2 packet=$3 marker=${4:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n'
    [ "$packet" = - ] || printf '%s\n\n' "$packet"
    printf '# Task\n## Captain'\''s intent\nExercise the packet boundary.\n'
    [ -z "$marker" ] || printf 'Redact %s before any packet leaves the vault.\n' "$marker"
    printf '\n## Firstmate spec\nVerify the recorded packet behavior.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n'
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  env -u FM_AV_INJECT -u FM_AV_INJECT_KEYS \
    HOME="$home" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_launch() {  # <home> <wt> <fakebin> <id> <proj> [harness] [extra-spawn-args...]
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5 harness=${6:-}
  shift 5
  [ -n "$harness" ] || harness=claude
  FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    run_spawn "$home" "$fakebin" "$id" "$proj" "$harness" --mode no-mistakes --yolo off "$@"
}

# --- scaffolds: fm-brief emits and validates the packet line ------------------

test_scaffold_records_and_validates_the_packet_class() {
  local rec home proj fakebin out status brief
  rec=$(make_home scaffold refuse)
  IFS='|' read -r home proj _ fakebin _ <<<"$rec"

  FM_HOME="$home" "$BRIEF_TOOL" s1 "$proj" --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/s1/brief.md"
  grep -qx 'Packet: class=ordinary' "$brief" \
    || fail "a ship scaffold without --packet did not record the ordinary default"

  FM_HOME="$home" "$BRIEF_TOOL" s2 "$proj" --mode no-mistakes --packet flagged >/dev/null 2>&1
  brief="$home/data/s2/brief.md"
  grep -qx 'Packet: class=flagged' "$brief" \
    || fail "--packet flagged was not recorded on the ship scaffold"

  FM_HOME="$home" "$BRIEF_TOOL" s3 "$proj" --scout --packet prohibited >/dev/null 2>&1
  brief="$home/data/s3/brief.md"
  grep -qx 'Packet: class=prohibited' "$brief" \
    || fail "--packet prohibited was not recorded on the scout scaffold"

  out=$(FM_HOME="$home" "$BRIEF_TOOL" s4 "$proj" --mode no-mistakes --packet banana 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an invalid packet class should refuse the scaffold"
  assert_contains "$out" "--packet must be one of ordinary, flagged, prohibited" \
    "an invalid packet class did not name the closed set"

  out=$(FM_HOME="$home" "$BRIEF_TOOL" sm "$home" --secondmate "$proj" --packet flagged 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--packet on a secondmate scaffold should refuse"
  assert_contains "$out" "--packet applies only to ship and scout briefs" \
    "a secondmate charter did not refuse the packet flag"
  if [ -e "$home/data/sm/brief.md" ]; then
    grep -q '^Packet:' "$home/data/sm/brief.md" \
      && fail "a secondmate charter must not carry a Packet line"
  fi
  pass "fm-brief: scaffolds record the packet class and refuse invalid or secondmate values"
}

# --- boundary: prohibited is the one-concise-captain-ask hard stop ------------

test_prohibited_packet_refuses_dispatch() {
  local rec home proj fakebin out status
  rec=$(make_home prohibited refuse)
  IFS='|' read -r home proj _ fakebin _ <<<"$rec"
  write_brief "$home" prohibited-z1 'Packet: class=prohibited'

  out=$(run_spawn "$home" "$fakebin" prohibited-z1 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a prohibited packet must refuse dispatch"
  assert_contains "$out" "prohibited-z1 packet is recorded prohibited" \
    "the refusal did not name the recorded packet class"
  assert_contains "$out" "explicit legal or contractual prohibition" \
    "the refusal did not state the prohibited class"
  assert_contains "$out" "Ask the captain once before any dispatch" \
    "the refusal did not carry the one concise captain ask"
  # The captain's answer is recorded by editing the one region the gate reads,
  # so the refusal must send the operator to the header block, not just "the
  # brief" - a line appended below the first heading is inert.
  assert_contains "$out" "above the first '#' heading" \
    "the refusal did not tell the operator where to record the captain's answer"
  assert_absent "$home/state/prohibited-z1.meta" "a refused prohibited spawn wrote task metadata"
  pass "fm-spawn: a prohibited packet refuses dispatch with the one concise captain ask"
}

# --- boundary: malformed Packet lines refuse ----------------------------------

test_malformed_packet_line_refuses_dispatch() {
  local rec home proj fakebin out status n=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    rec=$(make_home "malformed-$n" refuse)
    IFS='|' read -r home proj _ fakebin _ <<<"$rec"
    write_brief "$home" "malformed-$n-z1" "$line"
    out=$(run_spawn "$home" "$fakebin" "malformed-$n-z1" "$proj" claude --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "malformed packet line '$line' should refuse dispatch"
    assert_contains "$out" "malformed Packet line" \
      "malformed packet line '$line' was not named as malformed"
    assert_absent "$home/state/malformed-$n-z1.meta" \
      "a malformed packet spawn wrote task metadata"
  done <<'ROWS'
Packet: class=banana
Packet: banana
Packet: class=
Packet: class=ordinary extra
ROWS
  pass "fm-spawn: a Packet line outside the exact closed set refuses as malformed"
}

# --- boundary: one brief is one packet ----------------------------------------

test_disagreeing_packet_lines_refuse_dispatch() {
  local rec home proj wt fakebin out status
  rec=$(make_home disagree refuse)
  IFS='|' read -r home proj wt fakebin _ <<<"$rec"
  write_brief "$home" disagree-z1 $'Packet: class=ordinary\nPacket: class=prohibited'

  out=$(run_spawn "$home" "$fakebin" disagree-z1 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief recording two different packet classes must refuse dispatch"
  assert_contains "$out" "disagreeing Packet lines" \
    "the refusal did not name the disagreement"
  assert_contains "$out" "class=ordinary" "the refusal did not name the first recorded class"
  assert_contains "$out" "class=prohibited" "the refusal did not name the second recorded class"
  assert_absent "$home/state/disagree-z1.meta" \
    "a refused disagreeing-packet spawn wrote task metadata"
  pass "fm-spawn: disagreeing Packet lines refuse before anything is created, naming both classes"
}

test_duplicate_identical_packet_lines_dispatch_as_that_class() {
  local rec home proj wt fakebin id out status meta
  rec=$(make_home duplicate launch)
  IFS='|' read -r home proj wt fakebin _ id <<<"$rec"
  write_brief "$home" "$id" $'Packet: class=flagged\nPacket: class=flagged'

  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "a re-recorded identical packet class must still dispatch, got $status: $out"
  assert_contains "$out" "China-usage warning: conflict-level packet dispatched on normal rotation" \
    "a duplicated flagged line did not dispatch as flagged"
  meta="$home/state/$id.meta"
  grep -qx 'packet=flagged' "$meta" || fail "a duplicated flagged line did not record packet=flagged"
  [ "$(grep -c '^packet_warning=' "$meta")" -eq 1 ] \
    || fail "a duplicated flagged line did not record exactly one packet_warning line"
  pass "fm-spawn: an identically re-recorded packet class stays idempotent and dispatches as that class"
}

# --- boundary: only the structured header field is intake authority ----------

test_prose_quoted_packet_lines_are_inert() {
  local rec home proj wt fakebin id out status meta
  rec=$(make_home prose launch)
  IFS='|' read -r home proj wt fakebin _ id <<<"$rec"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'BRIEF'
You are a crewmate.

Packet: class=ordinary

# Task
## Captain's intent
Document the dispatch packet boundary, quoting the line shape it reads:
Packet: class=<class>

## Firstmate spec
An example of a conflict-level record is:
Packet: class=flagged

# Definition of done
Delivery contract: mode=no-mistakes
BRIEF

  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "a brief quoting Packet lines in its prose must still dispatch, got $status: $out"
  assert_not_contains "$out" "malformed Packet line" \
    "a placeholder quoted in the intent prose was read as a structured packet field"
  assert_not_contains "$out" "disagreeing Packet lines" \
    "an example quoted in the spec prose was read as a structured packet field"
  assert_not_contains "$out" "China-usage warning" \
    "an example quoted in the spec prose changed the dispatched class"
  meta="$home/state/$id.meta"
  grep -qx 'packet=ordinary' "$meta" \
    || fail "the structured header field was not the sole intake authority"
  pass "fm-spawn: only the structured header packet field governs; quoted lines in brief prose are inert"
}

# --- boundary: a refused packet creates nothing at all ------------------------

test_refused_packet_renders_no_launch_brief() {
  local rec home proj fakebin out status
  rec=$(make_home noartifact refuse)
  IFS='|' read -r home proj _ fakebin _ <<<"$rec"
  write_brief "$home" noartifact-z1 'Packet: class=prohibited'

  out=$(run_spawn "$home" "$fakebin" noartifact-z1 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a prohibited packet must refuse dispatch"
  assert_absent "$home/data/noartifact-z1/launch-brief.md" \
    "a refused packet rendered the launch brief before refusing"
  assert_absent "$home/state/noartifact-z1.meta" "a refused packet wrote task metadata"
  pass "fm-spawn: a refused packet creates nothing - no launch brief and no task record"
}

# --- boundary: ordinary and flagged dispatch, and only flagged warns ----------

test_ordinary_and_flagged_packets_dispatch_normally() {
  local rec home wt fakebin case_dir id out status meta

  # Ordinary: silent normal dispatch; the record carries the class, no warning.
  rec=$(make_home dispatch-ordinary launch)
  IFS='|' read -r home proj wt fakebin case_dir id <<<"$rec"
  write_brief "$home" "$id" 'Packet: class=ordinary'
  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "an ordinary packet must dispatch normally, got $status: $out"
  assert_contains "$out" "spawned $id" "an ordinary packet did not report the spawn"
  assert_not_contains "$out" "China-usage warning" "an ordinary packet produced a China-usage warning"
  assert_not_contains "$out" "records no Packet line" "an ordinary Packet line was treated as absent"
  meta="$home/state/$id.meta"
  grep -qx 'packet=ordinary' "$meta" || fail "an ordinary spawn did not record packet=ordinary"
  grep -q '^packet_warning=' "$meta" && fail "an ordinary spawn recorded a packet warning"

  # Flagged: normal dispatch plus exactly one concise warning in the record.
  rec=$(make_home dispatch-flagged launch)
  IFS='|' read -r home proj wt fakebin case_dir id <<<"$rec"
  write_brief "$home" "$id" 'Packet: class=flagged'
  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "a flagged packet must dispatch normally, got $status: $out"
  assert_contains "$out" "China-usage warning: conflict-level packet dispatched on normal rotation" \
    "a flagged dispatch did not carry the one-line China-usage warning"
  assert_contains "$out" "include it in the next captain update" \
    "the flagged warning did not point at the next captain update"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off packet=flagged" \
    "the flagged spawn line did not name the packet class"
  meta="$home/state/$id.meta"
  grep -qx 'packet=flagged' "$meta" || fail "a flagged spawn did not record packet=flagged"
  [ "$(grep -c '^packet_warning=' "$meta")" -eq 1 ] \
    || fail "a flagged spawn did not record exactly one packet_warning line"
  grep -q '^packet_warning=China-usage warning: conflict-level packet dispatched on normal rotation' "$meta" \
    || fail "the recorded warning is not the fixed one-line China-usage warning"
  pass "fm-spawn: ordinary and flagged packets dispatch normally; only flagged records the warning"
}

# --- boundary: the mechanism adds no secret surface ---------------------------

test_packet_outputs_stay_secret_free() {
  local rec home wt fakebin id out meta marker status
  marker='PACKETTESTSECRETVALUE-7f3a'
  rec=$(make_home secretfree launch)
  IFS='|' read -r home proj wt fakebin _ id <<<"$rec"
  write_brief "$home" "$id" 'Packet: class=flagged' "$marker"
  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "a flagged dispatch should succeed, got $status: $out"
  grep -q "$marker" "$home/data/$id/brief.md" \
    || fail "fixture sanity: the marker must sit in the packet itself"
  assert_not_contains "$out" "$marker" \
    "the spawn output echoed packet content into the warning surface"
  meta="$home/state/$id.meta"
  assert_not_contains "$(cat "$meta")" "$marker" \
    "the task record echoed packet content next to the warning"
  pass "fm-spawn: packet outputs stay secret-free - the record and warning never quote packet content"
}

# --- boundary: classification never infers from the lane ----------------------

test_classification_is_lane_independent() {
  local rec home proj fakebin out status first_out second_out
  rec=$(make_home lane refuse)
  IFS='|' read -r home proj _ fakebin _ <<<"$rec"

  # The same prohibited packet refuses identically on two different lanes,
  # before any endpoint: the verdict tracks the packet, never the provider.
  write_brief "$home" lane-prohibited 'Packet: class=prohibited'
  first_out=$(run_spawn "$home" "$fakebin" lane-prohibited "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a prohibited packet must refuse on the claude lane"
  second_out=$(run_spawn "$home" "$fakebin" lane-prohibited "$proj" pi --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a prohibited packet must refuse on the pi lane"
  assert_contains "$first_out" "lane-prohibited packet is recorded prohibited" \
    "the claude-lane refusal did not name the packet"
  assert_contains "$second_out" "lane-prohibited packet is recorded prohibited" \
    "the pi-lane refusal did not name the packet"

  # A flagged packet warns identically on both lanes: the China-usage warning
  # is a property of the conflict-level packet, not of the lane it rides.
  write_brief "$home" lane-flagged 'Packet: class=flagged'
  first_out=$(run_spawn "$home" "$fakebin" lane-flagged "$proj" claude --mode no-mistakes --yolo off)
  second_out=$(run_spawn "$home" "$fakebin" lane-flagged "$proj" pi --mode no-mistakes --yolo off)
  assert_contains "$first_out" "China-usage warning: conflict-level packet dispatched on normal rotation" \
    "the claude lane did not warn for the flagged packet"
  assert_contains "$second_out" "China-usage warning: conflict-level packet dispatched on normal rotation" \
    "the pi lane did not warn for the flagged packet"
  pass "fm-spawn: packet classification is identical across lanes; no provider name implies a jurisdiction"
}

# --- boundary: legacy briefs warn once and dispatch ordinary ------------------

test_legacy_brief_without_packet_line_warns_and_dispatches() {
  local rec home wt fakebin id out status meta
  rec=$(make_home legacy launch)
  IFS='|' read -r home proj wt fakebin _ id <<<"$rec"
  write_brief "$home" "$id" -
  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "a legacy brief must still dispatch, got $status: $out"
  assert_contains "$out" "records no Packet line" "a legacy brief did not warn about its missing packet line"
  meta="$home/state/$id.meta"
  grep -qx 'packet=ordinary' "$meta" || fail "a legacy dispatch did not record packet=ordinary"
  pass "fm-spawn: a brief without a Packet line warns once and dispatches ordinary"
}

# A Packet line appended below the first heading is inert, so the warning that
# sends an operator to fix a legacy brief must name the region that governs.

test_legacy_warning_names_the_authoritative_header_region() {
  local rec home proj wt fakebin id out status meta
  rec=$(make_home legacyregion launch)
  IFS='|' read -r home proj wt fakebin _ id <<<"$rec"
  write_brief "$home" "$id" -
  printf 'Packet: class=prohibited\n' >> "$home/data/$id/brief.md"
  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "a Packet line below the first heading is inert, so the spawn should dispatch, got $status: $out"
  meta="$home/state/$id.meta"
  grep -qx 'packet=ordinary' "$meta" || fail "an inert Packet line should still record packet=ordinary"
  assert_contains "$out" "above the first '#' heading" \
    "the legacy warning did not tell the operator where a Packet line counts"
  pass "fm-spawn: the missing-packet warning names the header region that governs"
}

# --- boundary: relaunch re-derives the class without duplicating the warning --

test_relaunch_rederives_the_class_without_duplicating_the_warning() {
  local rec home wt fakebin case_dir id out status meta
  rec=$(make_home relaunch launch)
  IFS='|' read -r home proj wt fakebin case_dir id <<<"$rec"
  write_brief "$home" "$id" 'Packet: class=flagged'
  out=$(run_launch "$home" "$wt" "$fakebin" "$id" "$proj"); status=$?
  [ "$status" -eq 0 ] || fail "the first flagged dispatch should succeed, got $status: $out"
  meta="$home/state/$id.meta"
  [ "$(grep -c '^packet_warning=' "$meta")" -eq 1 ] \
    || fail "the first dispatch did not record exactly one warning"

  # The endpoint goes idle (an exited agent leaves a shell), then the
  # relaunch types the launch command and the agent comes up again.
  printf 'zsh\n' > "$case_dir/fake/pane-command"
  out=$(FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    run_spawn "$home" "$fakebin" "$id" --relaunch); status=$?
  [ "$status" -eq 0 ] || fail "a relaunch of a flagged task should succeed, got $status: $out"
  assert_contains "$out" "China-usage warning" "the relaunch did not re-derive the flagged warning"
  [ "$(grep -c '^packet=flagged' "$meta")" -eq 1 ] \
    || fail "the relaunch duplicated the packet class line"
  [ "$(grep -c '^packet_warning=' "$meta")" -eq 1 ] \
    || fail "the relaunch duplicated the warning in the task record"
  pass "fm-spawn: a relaunch re-derives the class from the brief and never duplicates the warning"
}

# --- boundary: a scout dispatch classifies the same way -----------------------

test_scout_dispatch_carries_the_packet_class() {
  local rec home wt fakebin id out status meta
  rec=$(make_home scoutflag launch)
  IFS='|' read -r home proj wt fakebin _ id <<<"$rec"
  write_brief "$home" "$id" 'Packet: class=flagged'
  out=$(FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    run_spawn "$home" "$fakebin" "$id" "$proj" claude --scout); status=$?
  [ "$status" -eq 0 ] || fail "a flagged scout dispatch should succeed, got $status: $out"
  assert_contains "$out" "China-usage warning" "a flagged scout dispatch did not warn"
  meta="$home/state/$id.meta"
  grep -qx 'packet=flagged' "$meta" || fail "a scout dispatch did not record packet=flagged"
  pass "fm-spawn: a scout dispatch records and warns on the packet class like a ship"
}

test_scaffold_records_and_validates_the_packet_class
test_prohibited_packet_refuses_dispatch
test_malformed_packet_line_refuses_dispatch
test_prose_quoted_packet_lines_are_inert
test_refused_packet_renders_no_launch_brief
test_disagreeing_packet_lines_refuse_dispatch
test_duplicate_identical_packet_lines_dispatch_as_that_class
test_ordinary_and_flagged_packets_dispatch_normally
test_packet_outputs_stay_secret_free
test_classification_is_lane_independent
test_legacy_brief_without_packet_line_warns_and_dispatches
test_legacy_warning_names_the_authoritative_header_region
test_relaunch_rederives_the_class_without_duplicating_the_warning
test_scout_dispatch_carries_the_packet_class
