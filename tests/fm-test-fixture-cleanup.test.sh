#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# An arm the Pi watcher tests leave behind ignores TERM, so removing the fixture
# directory does not stop it. The owner exiting must stop that arm, and must
# leave an arm launched from a different fixture running.
test_cleanup_reaps_owned_watch_arm_only() {
  local harness holder_hb victim_hb holder_dir release holder_pid victim_status
  local victim_a victim_b holder_a holder_b
  harness=$(fm_test_tmproot fm-test-cleanup-arm-harness)
  holder_hb="$harness/holder-hb"
  victim_hb="$harness/victim-hb"
  holder_dir="$harness/holder-dir"
  release="$harness/release"

  bash -c '
    set -u
    # shellcheck source=tests/lib.sh
    . "$1"
    d=$(fm_test_tmproot fm-pi-watch-extension)
    printf "%s\n" "$d" > "$2"
    mkdir -p "$d/root/bin"
    cat > "$d/root/bin/fm-watch-arm.sh" <<'"'"'SH'"'"'
#!/usr/bin/env bash
trap "" TERM INT
end=$((SECONDS + 12))
while [ ! -e "${FM_ARM_STOP:?}" ] && [ "$SECONDS" -lt "$end" ]; do
  n=$((n + 1))
  if ! echo "$n" > "${FM_ARM_HEARTBEAT:?}"; then
    exit 0
  fi
  sleep 0.2
done
SH
    chmod +x "$d/root/bin/fm-watch-arm.sh"
    export FM_ARM_HEARTBEAT="$3" FM_ARM_STOP="$4"
    "$d/root/bin/fm-watch-arm.sh" --restart >/dev/null 2>&1 &
    disown "$!" 2>/dev/null || true
    tries=0
    while [ ! -s "$FM_ARM_HEARTBEAT" ] && [ "$tries" -lt 50 ]; do
      sleep 0.05
      tries=$((tries + 1))
    done
    [ -s "$FM_ARM_HEARTBEAT" ] || exit 1
    end=$((SECONDS + 12))
    while [ ! -e "$FM_ARM_STOP" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.05; done
  ' _ "$LIB" "$holder_dir" "$holder_hb" "$release" &
  holder_pid=$!

  victim_status=0
  bash -c '
    set -u
    # shellcheck source=tests/lib.sh
    . "$1"
    d=$(fm_test_tmproot fm-pi-watch-extension)
    mkdir -p "$d/root/bin"
    cat > "$d/root/bin/fm-watch-arm.sh" <<'"'"'SH'"'"'
#!/usr/bin/env bash
trap "" TERM INT
end=$((SECONDS + 12))
while [ "$SECONDS" -lt "$end" ]; do
  n=$((n + 1))
  if ! echo "$n" > "${FM_ARM_HEARTBEAT:?}"; then
    exit 0
  fi
  sleep 0.2
done
SH
    chmod +x "$d/root/bin/fm-watch-arm.sh"
    export FM_ARM_HEARTBEAT="$2"
    "$d/root/bin/fm-watch-arm.sh" --restart >/dev/null 2>&1 &
    disown "$!" 2>/dev/null || true
    tries=0
    while [ ! -s "$FM_ARM_HEARTBEAT" ] && [ "$tries" -lt 50 ]; do
      sleep 0.05
      tries=$((tries + 1))
    done
    [ -s "$FM_ARM_HEARTBEAT" ] || exit 1
  ' _ "$LIB" "$victim_hb" || victim_status=$?
  [ "$victim_status" -eq 0 ] || fail "the fixture owner exited before its watch arm published a heartbeat"

  victim_a=$(cat "$victim_hb")
  sleep 0.6
  victim_b=$(cat "$victim_hb")
  [ "$victim_a" = "$victim_b" ] || fail "a watch arm kept running after its fixture owner exited"
  holder_a=$(cat "$holder_hb" 2>/dev/null || true)
  [ -n "$holder_a" ] || fail "the other fixture never armed its watch arm"
  sleep 0.6
  holder_b=$(cat "$holder_hb")
  [ "$holder_a" != "$holder_b" ] || fail "fixture cleanup stopped a watch arm owned by a different fixture"
  printf 'release\n' > "$release"
  wait "$holder_pid" || fail "the other fixture owner did not exit after release"
  pass "fixture cleanup stops only the watch arm its own fixture armed"
}

# A prior run can remove the fixture and leave the arm reparented. The next
# test process's startup sweep must stop an arm whose code root under the temp
# directory is already gone, and must leave an arm outside that directory.
test_orphan_sweep_reaps_pruned_temp_watch_arm_only() {
  local harness outside hb_temp hb_out stop_out temp_root
  local temp_a temp_b out_a out_b
  harness=$(fm_test_tmproot fm-test-cleanup-arm-orphan-harness)
  outside=$(mktemp -d "$ROOT/.fm-arm-scope.XXXXXX")
  hb_temp="$harness/temp-hb"
  hb_out="$harness/out-hb"
  stop_out="$harness/out-stop"
  temp_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-watch-extension.XXXXXX")

  launch_bounded_arm() { # <root> <heartbeat> [stop-file]
    local root=$1 heartbeat=$2 stop=${3:-}
    mkdir -p "$root/bin"
    if [ -n "$stop" ]; then
      cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT
end=$((SECONDS + 12))
while [ ! -e "${FM_ARM_STOP:?}" ] && [ "$SECONDS" -lt "$end" ]; do
  n=$((n + 1))
  if ! echo "$n" > "${FM_ARM_HEARTBEAT:?}"; then
    exit 0
  fi
  sleep 0.2
done
SH
    else
      cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT
end=$((SECONDS + 12))
while [ "$SECONDS" -lt "$end" ]; do
  n=$((n + 1))
  if ! echo "$n" > "${FM_ARM_HEARTBEAT:?}"; then
    exit 0
  fi
  sleep 0.2
done
SH
    fi
    chmod +x "$root/bin/fm-watch-arm.sh"
    FM_ARM_HEARTBEAT="$heartbeat" FM_ARM_STOP="$stop" "$root/bin/fm-watch-arm.sh" --restart >/dev/null 2>&1 &
    disown "$!" 2>/dev/null || true
  }

  launch_bounded_arm "$temp_root/root" "$hb_temp"
  launch_bounded_arm "$outside/root" "$hb_out" "$stop_out"
  local tries=0
  while [ "$tries" -lt 50 ]; do
    [ -s "$hb_temp" ] && [ -s "$hb_out" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$hb_temp" ] && [ -s "$hb_out" ] || {
    printf 'release\n' > "$stop_out"
    rm -rf "$outside" "$temp_root"
    fail "the pruned-root fixtures never armed"
  }
  rm -rf "$temp_root" "$outside/root"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  temp_a=$(cat "$hb_temp")
  sleep 0.6
  temp_b=$(cat "$hb_temp")
  out_a=$(cat "$hb_out")
  sleep 0.6
  out_b=$(cat "$hb_out")
  printf 'release\n' > "$stop_out"
  rm -rf "$outside"
  [ "$temp_a" = "$temp_b" ] || fail "a watch arm whose temp code root was already gone survived the next test startup"
  [ "$out_a" != "$out_b" ] || fail "test startup stopped a watch arm whose code root was outside the temp directory"
  pass "test startup reaps a pruned temp watch arm and leaves one outside the temp directory"
}

test_orphan_sweep_reaps_watch_arm_through_temp_alias() {
  local harness physical alias stale hb pid tries before after
  harness=$(fm_test_tmproot fm-test-cleanup-arm-alias)
  physical="$harness/physical"
  alias="$harness/alias"
  hb="$harness/heartbeat"
  mkdir -p "$physical"
  ln -s "$physical" "$alias"
  stale=$(mktemp -d "$alias/fm-pi-watch-extension.XXXXXX")
  mkdir -p "$stale/root/bin"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale/.fm-test-fixture"
  touch -t 202001010000 "$stale/.fm-test-fixture"
  cat > "$stale/root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT
n=0
end=$((SECONDS + 12))
while [ "$SECONDS" -lt "$end" ]; do
  n=$((n + 1))
  printf '%s\n' "$n" > "$FM_ARM_HEARTBEAT" || exit 0
  sleep 0.2
done
SH
  chmod +x "$stale/root/bin/fm-watch-arm.sh"
  FM_ARM_HEARTBEAT="$hb" "$stale/root/bin/fm-watch-arm.sh" --restart >/dev/null 2>&1 &
  pid=$!
  tries=0
  while [ ! -s "$hb" ] && [ "$tries" -lt 50 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if [ ! -s "$hb" ]; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the aliased fixture arm never published a heartbeat"
  fi
  TMPDIR="$alias" bash -c '. "$1"' _ "$LIB"
  before=$(cat "$hb")
  sleep 0.6
  after=$(cat "$hb")
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_absent "$stale" "the stale aliased fixture was not removed"
  [ "$before" = "$after" ] || fail "the stale fixture arm survived the first sweep through a temp alias"
  pass "the first stale-fixture sweep stops watch arms through a temp alias"
}

test_registries_avoid_git_worktree_root() {
  # A TMPDIR pointed at a repository root used to place live `.fm-test-*`
  # registries beside tracked files. A concurrent git add during a suite then
  # committed them (observed on the claim-walk CI fix round). The helper must
  # keep registries and fixture roots outside that root for the whole run.
  local harness repo dirfile child_dir pid tries entry
  harness=$(fm_test_tmproot fm-test-cleanup-gitroot-harness)
  repo="$harness/repo"
  dirfile="$harness/child-dir"
  mkdir -p "$repo"
  git -C "$repo" init -q
  bash -c '
    export TMPDIR="$1"
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-gitroot)
    printf "%s\n" "$d" > "$3"
    # Hold the suite open so a concurrent add would see any root-side leak.
    while :; do sleep 0.1; done
  ' _ "$repo" "$LIB" "$dirfile" &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the git-root TMPDIR child never published its fixture root"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the git-root TMPDIR child did not create a fixture root"
  case "$child_dir" in
    "$repo"|"$repo"/*)
      fail "fm_test_tmproot placed a fixture root inside the git worktree root: $child_dir"
      ;;
  esac
  for entry in "$repo"/.fm-test-cleanup.* "$repo"/.fm-test-procevent.* "$repo"/.fm-test-watcher.*; do
    [ ! -e "$entry" ] || fail "a live test registry landed in the git worktree root: $entry"
  done
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  assert_absent "$child_dir" \
    "the git-root TMPDIR child's fixture root survived SIGTERM"
  pass "test registries and fixture roots stay out of a git worktree TMPDIR"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_cleanup_reaps_owned_watch_arm_only
test_orphan_sweep_reaps_pruned_temp_watch_arm_only
test_orphan_sweep_reaps_watch_arm_through_temp_alias
test_registries_avoid_git_worktree_root
