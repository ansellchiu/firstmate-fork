#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's agy authentication preflight gate.
#
# agy chooses its credential store per process, so a worker launched into an
# unauthenticated lane parks forever on an interactive OAuth prompt instead of
# failing. fm-spawn gates every agy launch on a bounded `agy models` probe
# (bin/fm-agy-lib.sh). These tests drive the real fm-spawn with a fake tmux and
# a stub agy so each probe verdict is asserted through the spawn's observable
# behavior: whether an endpoint was created, whether task metadata was written,
# and whether a launch command was typed.
#
# The last two cases drop to the library instead, because what they assert is
# which bounding mechanism the machine has: a stock macOS has no GNU timeout at
# all, and requiring one refused every agy spawn on a healthy lane. Driving
# them through fm-spawn would need the whole spawn's PATH curated down to a
# timeout-free set; sourcing bin/fm-agy-lib.sh directly makes the absent
# timeout the only variable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-preflight)

# Fake tmux that logs the literal launch command AND every window-creating
# call, so a refusal can be proven to have created no endpoint rather than
# merely to have printed an error.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  # An agent-free but present window: no readable pane tty, and a plain shell as
  # the current command. That is the endpoint shape --relaunch requires, so the
  # relaunch case reaches the same preflight a fresh spawn does.
  *"#{pane_tty}"*) exit 0 ;;
  *"#{pane_current_command}"*) printf 'bash\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_WINDOW_NAME:-}" ] || printf '%s\n' "$FM_FAKE_WINDOW_NAME"
    exit 0
    ;;
  has-session) exit 0 ;;
  new-session|new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0
    ;;
  kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse

  # A real timeout implementation rather than a pass-through, so the timeout
  # case exercises the same 124 path timeout(1) produces in production. It
  # shadows any system timeout, which is also what keeps these spawn-level
  # cases on the timeout branch regardless of the host.
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
set -u
dur=$1
shift
"$@" &
child=$!
( sleep "$dur"; kill -9 "$child" 2>/dev/null ) &
watcher=$!
wait "$child"
rc=$?
kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
[ "$rc" -lt 128 ] || exit 124
exit "$rc"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# Stub agy whose `models` verdict is driven by the environment, matching the
# real CLI's observed shapes: exit 0 with a catalog when the lane is signed in,
# exit 1 with the sign-in error when it is not.
install_stub_agy() {
  local fakebin=$1
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = models ]; then
  case "${FM_FAKE_AGY_MODELS:-ok}" in
    ok)
      printf '%s\n' 'gemini-3.7-flash-medium' 'gemini-3.7-flash-high'
      exit 0
      ;;
    hang)
      sleep 30
      exit 0
      ;;
    *)
      printf '%s\n' 'Fetching available models...' >&2
      printf '%s\n' 'Error: Please sign in to view available models. Launch the CLI without arguments to sign in.' >&2
      exit 1
      ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/agy"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  install_stub_agy "$fakebin"
  # A sandboxed OS home so resolve_agy_binary's ~/.local/bin/agy fallback can
  # never reach the developer's real installation and turn a stub case into a
  # live probe of their actual Gemini lane.
  mkdir -p "$case_dir/os-home"
  [ ! -f "$HOME/.gitconfig" ] || cp "$HOME/.gitconfig" "$case_dir/os-home/.gitconfig"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' agy > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  # Upstream requires filled Task subsections and a recorded delivery contract
  # before a ship spawn will run, so the fixture brief carries the minimum of both.
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the launch path for $id.

## Firstmate spec
Keep the fixture brief minimal.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  printf '%s\n' "$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/endpoint.log|$case_dir/os-home"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ENDPOINT_LOG OS_HOME <<EOF
$1
EOF
}

run_spawn() {
  : > "$LAUNCH_LOG"
  : > "$ENDPOINT_LOG"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_ENDPOINT_LOG="$ENDPOINT_LOG" \
    FM_FAKE_WINDOW_NAME="${FM_TEST_WINDOW_NAME:-}" \
    FM_FAKE_AGY_MODELS="${FM_TEST_AGY_MODELS:-ok}" \
    FM_AGY_PREFLIGHT_TIMEOUT="${FM_TEST_AGY_TIMEOUT:-10}" \
    CLAUDE_CONFIG_DIR='' HOME="$OS_HOME" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$@" 2>&1
}

# Every refusal must leave the fleet exactly as it found it: no endpoint, no
# worktree handoff typed into a pane, and no task metadata a supervisor would
# later read as live work.
assert_refused_before_any_side_effect() {
  local out=$1 status=$2 id=$3 label=$4
  expect_code 1 "$status" "$label should refuse the spawn"
  assert_contains "$out" "the Gemini lane is down" \
    "$label refusal did not name the Gemini lane as the cause"
  assert_contains "$out" "agy-auth-state-s1/report.md section 3" \
    "$label refusal did not point at the sign-in procedure"
  assert_absent "$HOME_DIR/state/$id.meta" "$label refusal wrote task metadata"
  [ ! -s "$ENDPOINT_LOG" ] || fail "$label refusal created an endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "$label refusal typed a launch command"
}

# What this case owns is the preflight's NEGATIVE: a signed-in lane is not
# refused by it. It deliberately does not assert the whole launch, because the
# agy launch path beyond the preflight - folder-trust pre-registration and the
# trust-dialog wait - is owned and faked by tests/fm-agy-harness.test.sh, and
# asserting it twice from a fixture that models neither would only pin this
# suite to that other suite's fake.
test_healthy_lane_is_not_refused_by_the_preflight() {
  local rec id out
  id=agy-preflight-ok-a1
  rec=$(make_case agy-preflight-ok "$id")
  read_case_record "$rec"

  out=$(FM_TEST_AGY_MODELS=ok run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off) || true
  assert_not_contains "$out" "not signed in" "a signed-in lane was refused as signed out"
  assert_not_contains "$out" "sign-in check" "a signed-in lane tripped the sign-in check"
  assert_not_contains "$out" "no usable agy executable" \
    "a signed-in lane was refused for a missing executable"
  pass "the preflight passes a signed-in agy lane through to the launch path"
}

test_signed_out_lane_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=agy-preflight-signedout-a2
  rec=$(make_case agy-preflight-signedout "$id")
  read_case_record "$rec"

  out=$(FM_TEST_AGY_MODELS=signedout run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_refused_before_any_side_effect "$out" "$status" "$id" "a signed-out agy lane"
  # The probe's own stderr carries auth noise a supervisor should never have to
  # read; only the single reason line is allowed through.
  assert_not_contains "$out" "Fetching available models" \
    "refusal leaked the probe's own output into the reason"
  pass "a signed-out agy lane refuses before any endpoint, worktree, or metadata exists"
}

test_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=agy-preflight-missing-a3
  rec=$(make_case agy-preflight-missing "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/agy"

  out=$(run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a missing agy executable should refuse the spawn"
  assert_absent "$HOME_DIR/state/$id.meta" "missing agy refusal wrote task metadata"
  [ ! -s "$ENDPOINT_LOG" ] || fail "missing agy refusal created an endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing agy refusal typed a launch command"
  pass "an absent agy executable refuses before any endpoint, worktree, or metadata exists"
}

test_probe_timeout_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=agy-preflight-timeout-a4
  rec=$(make_case agy-preflight-timeout "$id")
  read_case_record "$rec"

  out=$(FM_TEST_AGY_MODELS=hang FM_TEST_AGY_TIMEOUT=1 \
    run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  assert_refused_before_any_side_effect "$out" "$status" "$id" "an unresponsive agy lane"
  assert_contains "$out" "did not finish within 1s" \
    "timeout refusal did not name the bounded wait it exceeded"
  pass "a probe that never returns refuses instead of hanging the spawn"
}

# A refusal must stay a refusal: quietly launching a different harness would
# hide the credential problem the captain has to fix.
test_refusal_never_falls_back_to_another_harness() {
  local rec id out status
  id=agy-preflight-nofallback-a5
  rec=$(make_case agy-preflight-nofallback "$id")
  read_case_record "$rec"

  out=$(FM_TEST_AGY_MODELS=signedout run_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a signed-out lane should refuse rather than substitute a harness"
  assert_not_contains "$out" "spawned $id" "refusal reported a spawn"
  assert_absent "$HOME_DIR/state/$id.meta" "refusal recorded a task under any harness"
  pass "a refused agy launch never silently falls back to another harness"
}

test_relaunch_is_gated_identically() {
  local rec id out status meta
  id=agy-preflight-relaunch-a6
  rec=$(make_case agy-preflight-relaunch "$id")
  read_case_record "$rec"

  # What this case owns is the RELAUNCH gate, so the task it relaunches is
  # seeded directly. Driving a full initial spawn would also drive the agy
  # launch path - folder trust, the trust-dialog answer and the working
  # indicator - which tests/fm-agy-harness.test.sh owns and this fixture's
  # fake pane does not render.
  meta="$HOME_DIR/state/$id.meta"
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=agy" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=fixture-$id" > "$meta"
  chmod 600 "$meta"
  assert_present "$meta" "the relaunch fixture wrote no task metadata"

  # The lane goes down between the spawn and the relaunch; the replacement must
  # be refused on the same evidence a fresh spawn would be.
  out=$(FM_TEST_AGY_MODELS=signedout FM_TEST_WINDOW_NAME="fm-$id" \
    run_spawn --relaunch "$id")
  status=$?
  expect_code 1 "$status" "a relaunch onto a signed-out agy lane should refuse"
  assert_contains "$out" "the Gemini lane is down" \
    "relaunch refusal did not name the Gemini lane as the cause"
  assert_contains "$out" "agy-auth-state-s1/report.md section 3" \
    "relaunch refusal did not point at the sign-in procedure"
  [ ! -s "$LAUNCH_LOG" ] || fail "relaunch refusal typed a launch command"
  pass "a relaunch is gated on the same authentication preflight as a fresh spawn"
}


# --- bounding-mechanism cases, driven through the library directly ---------

AGY_LIB="$ROOT/bin/fm-agy-lib.sh"

# A PATH holding exactly the named tools, so "this machine has no timeout" is a
# fact of the test environment rather than a fact of whoever is running it.
make_probe_path() {  # <case-name> <tool>...
  local dir="$TMP_ROOT/$1/bin" tool src
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    src=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$tool") || continue
    ln -sf "$src" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# Stub agy on a curated PATH: `models` honours FM_FAKE_AGY_MODELS the same way
# the spawn-level stub does.
install_probe_agy() {  # <dir>
  cat > "$1/agy" <<'SH'
#!/bin/sh
if [ "${1:-}" = models ]; then
  case "${FM_FAKE_AGY_MODELS:-ok}" in
    ok) echo 'gemini-3.7-flash-medium'; exit 0 ;;
    hang) sleep 30; exit 0 ;;
    *) echo 'Error: Please sign in to view available models.' >&2; exit 1 ;;
  esac
fi
exit 0
SH
  chmod +x "$1/agy"
}

# SSH markers are pre-set so the probe never needs `env`, keeping the curated
# PATH down to exactly the tools whose presence is under test.
run_probe() {  # <path-dir> <models-verdict> <timeout>
  ( set +u
    export SSH_CONNECTION='127.0.0.1 0 127.0.0.1 22'
    export PATH="$1" FM_FAKE_AGY_MODELS="$2" FM_AGY_PREFLIGHT_TIMEOUT="$3"
    # shellcheck source=/dev/null
    . "$AGY_LIB"
    fm_agy_preflight "$1/agy" 2>&1
    printf 'STATUS=%s\n' "$?"
  )
}

test_bound_works_without_gnu_timeout() {
  local dir out status
  dir=$(make_probe_path agy-preflight-notimeout perl sleep)
  install_probe_agy "$dir"
  [ ! -e "$dir/timeout" ] && [ ! -e "$dir/gtimeout" ] \
    || fail "the timeout-free probe PATH still exposes a timeout command"

  out=$(run_probe "$dir" ok 10)
  status=${out##*STATUS=}
  expect_code 0 "$status" "a signed-in lane should pass with no timeout binary present"
  assert_not_contains "$out" "the Gemini lane is down" \
    "the perl fallback refused a healthy lane"

  # The fallback has to bound, not merely run: an unresponsive probe must still
  # come back as the same expired-wait refusal timeout(1) produces.
  out=$(run_probe "$dir" hang 1)
  status=${out##*STATUS=}
  expect_code 1 "$status" "an unresponsive lane should refuse with no timeout binary present"
  assert_contains "$out" "did not finish within 1s" \
    "the perl fallback did not report the bound it enforced"

  out=$(run_probe "$dir" signedout 10)
  status=${out##*STATUS=}
  expect_code 1 "$status" "a signed-out lane should still refuse with no timeout binary present"
  assert_contains "$out" "the Gemini lane is down" \
    "the perl fallback lost the signed-out refusal reason"
  pass "the probe is bounded, and keeps every verdict, on a machine with no GNU timeout"
}

test_no_bounding_mechanism_at_all_refuses() {
  local dir out status
  dir=$(make_probe_path agy-preflight-nobound)
  install_probe_agy "$dir"

  out=$(run_probe "$dir" ok 10)
  status=${out##*STATUS=}
  expect_code 1 "$status" "a machine with no way to bound the probe should refuse"
  assert_contains "$out" "no timeout, gtimeout, or perl" \
    "the unbounded refusal did not name what is missing"
  pass "a machine with no way to bound the probe refuses rather than running it unbounded"
}

test_healthy_lane_is_not_refused_by_the_preflight
test_signed_out_lane_refuses_before_endpoint_or_metadata
test_missing_binary_refuses_before_endpoint_or_metadata
test_probe_timeout_refuses_before_endpoint_or_metadata
test_refusal_never_falls_back_to_another_harness
test_relaunch_is_gated_identically
test_bound_works_without_gnu_timeout
test_no_bounding_mechanism_at_all_refuses

echo "# all fm-agy-preflight tests passed"
