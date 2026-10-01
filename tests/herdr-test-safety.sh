#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

# herdr_test_agent_prepare <dir> <lab-helper>:
# Build a token-free long-lived stand-in for real fm-spawn tests. The launcher
# registers the pane through the isolated lab helper before execing a process
# whose basename is part of the production harness vocabulary, so the launch
# postcondition proves a real live agent instead of racing a short-lived shell.
HERDR_TEST_AGENT_LAUNCHER=
herdr_test_agent_prepare() {
  local dir=$1 helper=$2 helper_path=${3:-$PATH} helper_q agent_q helper_path_q
  mkdir -p "$dir" || return 1
  ln -sf /bin/sleep "$dir/codex-test-agent" || return 1
  printf -v helper_q '%q' "$helper"
  printf -v agent_q '%q' "$dir/codex-test-agent"
  printf -v helper_path_q '%q' "$helper_path"
  cat > "$dir/launch" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${1:-}" ] || printf '%s\n' "\$1"
PATH=$helper_path_q $helper_q run "\${HERDR_SESSION:?}" pane report-agent "\${HERDR_PANE_ID:?}" \
  --source fm-real-herdr-test --agent codex-test-agent --state idle --seq 1 >/dev/null
exec $agent_q 600
SH
  chmod +x "$dir/launch" || return 1
  HERDR_TEST_AGENT_LAUNCHER="$dir/launch"
}

herdr_test_agent_command() { # [marker]
  local launcher_q marker_q
  [ -n "$HERDR_TEST_AGENT_LAUNCHER" ] || return 1
  printf -v launcher_q '%q' "$HERDR_TEST_AGENT_LAUNCHER"
  printf -v marker_q '%q' "${1:-}"
  printf '%s %s\n' "$launcher_q" "$marker_q"
}

herdr_test_write_landing_receipt() { # <root> <home> <task-id>
  local root=$1 home=$2 task_id=$3
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$root" "$root/bin/fm-receipt.sh" write-landing \
      --task "$task_id" --project-fallback project \
      --commit-sha 1111111111111111111111111111111111111111 \
      --sha-source 'fixture commit' >/dev/null
}
