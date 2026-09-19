#!/usr/bin/env bash
# tests/fm-spawn-launch-postcondition.test.sh - regressions for bin/fm-spawn.sh's
# launch postcondition.
#
# The defect both guard: fm-spawn assembled a launch, wrote state/<id>.meta and
# printed `spawned ...` without anything confirming an agent had actually come
# up, so a launch that died inside the pane left a task reading `working`
# indefinitely. Drives everything through the real fm-spawn.sh with a fake tmux
# that controls what the pane's foreground command reports, so the production
# classifier decides each verdict. No live harness required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-postcondition)
SPAWN="$ROOT/bin/fm-spawn.sh"

# --- spawn harness -----------------------------------------------------------

# Fake tmux whose reported pane foreground command is read from a file, so each
# case drives the REAL classifier in bin/backends/tmux.sh to a chosen verdict.
# The pane tty it reports does not exist, so the foreground process-group half
# of the probe reads nothing and #{pane_current_command} settles the verdict.
make_fakebin() {  # <dir> <window-name>
  local dir=$1 window=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) printf '%s\n' "/dev/null/nonexistent"; exit 0 ;;
  *"#{pane_current_command}"*)
    cat "$dir/pane-command" 2>/dev/null || printf 'zsh\n'
    exit 0
    ;;
esac
case "\${1:-}" in
  # Empty until the window is actually created, so fm-spawn's pre-creation
  # collision check passes and the postcondition's inventory read still finds
  # the window afterwards.
  list-windows) [ -f "$dir/window-created" ] && printf '%s\n' "$window"; exit 0 ;;
  new-window) : > "$dir/window-created"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|kill-window|send-keys) exit 0 ;;
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
  printf '%s\n' "$fakebin"
}

# Builds a home/project/worktree trio and returns its fields.
make_case() {  # <name>
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  id="$name-z1"
  fakebin=$(make_fakebin "$case_dir/fake" "fm-$id")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
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
  printf '%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$case_dir" "$id"
}

run_spawn() {  # <home> <wt> <fakebin> <id> <proj> [extra-env...]
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  env -u FM_AV_INJECT -u FM_AV_INJECT_KEYS \
    HOME="$home" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" "$@" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

# --- postcondition: an agent that came up lets the spawn through -------------

rec=$(make_case alive)
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
[ "$rc" -eq 0 ] || fail "a spawn whose agent came up must succeed, got $rc: $out"
assert_contains "$out" "spawned $CASE_ID" "a live agent must report the spawn"
[ -f "$HOME_DIR/state/$CASE_ID.meta" ] || fail "a successful spawn must record its task"
pass "a launch that produces a live agent is reported as spawned and recorded"

# --- postcondition: a dead endpoint refuses ---------------------------------

rec=$(make_case dead)
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'zsh\n' > "$CASE_DIR/fake/pane-command"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=0.2 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
[ "$rc" -ne 0 ] || fail "a launch that produced no agent must refuse, got exit 0"
assert_not_contains "$out" "spawned $CASE_ID" "a dead launch must never report the spawn"
assert_contains "$out" "no agent came up" "the refusal must say no agent came up"
assert_contains "$(cat "$HOME_DIR/state/$CASE_ID.status" 2>/dev/null || true)" \
  "failed:" "a dead launch must record a failed event rather than leave the task reading working"
pass "a launch that leaves a bare shell refuses, prints no spawned line, and records the failure"

# --- postcondition: an adapter that cannot answer must not refuse ------------

rec=$(make_case ambiguous)
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
# `node` is attributable to no verified harness, so the classifier reports
# ambiguous - the same verdict an agy pane produces. It must not refuse.
printf 'node\n' > "$CASE_DIR/fake/pane-command"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=0.2 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
expect_code 0 "$rc" "an unattributable endpoint must not fail the spawn"
assert_contains "$out" "spawned $CASE_ID" "an adapter that cannot answer must degrade to success"
pass "an endpoint the classifier cannot attribute proceeds instead of producing a false refusal"

# --- the vault is no longer on the launch path -------------------------------
#
# Injection moved to the point of use, so a home that opted in must still spawn
# with no `av` on PATH at all. A spawn that starts failing on vault state again
# means a launch wrapper was reintroduced.

rec=$(make_case vault-independent)
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
printf 'on\n' > "$HOME_DIR/config/av-inject"
rm -f "$FAKEBIN/av"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
expect_code 0 "$rc" "an opted-in spawn must not depend on the vault"
assert_contains "$out" "spawned $CASE_ID" "an opted-in home with no vault must still spawn"
pass "an opted-in home spawns normally with no Automic Vault CLI on PATH"
