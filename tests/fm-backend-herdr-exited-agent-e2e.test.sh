#!/usr/bin/env bash
# tests/fm-backend-herdr-exited-agent-e2e.test.sh - isolated real-herdr
# regression test for the exited-but-still-registered agent, the condition that
# stranded a task on 2026-09-11: its agent exited, Herdr kept the registration,
# and every `exit` and `relaunch` waited forever for a stop that had already
# happened (bin/backends/herdr.sh's stale-agent classification; see
# docs/herdr-backend.md "Endpoint recovery classification").
#
# The verdict this pins is harness-dependent: it reads the agent label Herdr
# itself registered and the command names in the operating system's own process
# table, so a fake agent could only confirm the assumption already written into
# the fake. This guard therefore drives REAL Herdr lifecycle reporting against a
# REAL process, in its own private lab session, and runs the same transition the
# stranded task went through: a registered, running agent, then a reported
# turn-end, then the agent process dying without ever releasing its lifecycle
# authority while its pane survives.
#
# It spends no model tokens: the stand-in agent is an ordinary long-lived
# process registered through `herdr pane report-agent`, which is the same
# lifecycle-hook surface a real harness reports through.
#
# Safety (tests/herdr-test-safety.sh): cleanup uses ONLY
# herdr_safe_stop_and_delete, never a bare or inline-prefixed server stop.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane

SESSION="fm-lab-exited-agent-e2e-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-exited-agent.XXXXXX")
AGENT_LABEL=fmlabagent
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

# The stand-in agent must be a real non-shell executable whose command basename
# is the registered label. A symlink keeps the operating system's own process
# name pointing at it without copying a signed system binary, which macOS
# refuses to execute.
mkdir -p "$SCRATCH/bin"
ln -sf /bin/sleep "$SCRATCH/bin/$AGENT_LABEL"

fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated session's server"
CREATE_OUT=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$SCRATCH" --label exitedagent --no-focus) \
  || fail "could not create the lab workspace"
PANE=$(printf '%s' "$CREATE_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail "could not parse the lab pane id from workspace create: $CREATE_OUT"
TARGET="$SESSION:$PANE"

# --- 1. a registered, RUNNING agent ----------------------------------------

fm_backend_herdr_cli "$SESSION" pane report-agent "$PANE" \
  --source fm-exited-agent-e2e --agent "$AGENT_LABEL" --state working --seq 1 >/dev/null 2>&1 \
  || fail "could not report the stand-in agent's lifecycle state to the real herdr"

# Wait for the pane's own shell to settle before typing anything into it: a
# command sent to a shell that is not ready yet is buffered and run later, which
# would leave a SECOND stand-in agent behind and make the exit below a lie.
PANE_READY=false
READY_SAMPLES=0
for _ in $(seq 1 200); do
  if fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null | jq -e '
    .result.process_info as $process
    | ($process.foreground_processes | length == 1)
      and ($process.foreground_processes[0].pid == $process.shell_pid)
  ' >/dev/null 2>&1; then
    READY_SAMPLES=$((READY_SAMPLES + 1))
    [ "$READY_SAMPLES" -ge 10 ] && { PANE_READY=true; break; }
  else
    READY_SAMPLES=0
  fi
  sleep 0.1
done
[ "$PANE_READY" = true ] || fail "the lab pane's shell did not become ready"

fm_backend_herdr_cli "$SESSION" pane run "$PANE" "$SCRATCH/bin/$AGENT_LABEL 600" >/dev/null 2>&1 \
  || fail "could not start the stand-in agent process in the lab pane"
AGENT_PID=
for _ in $(seq 1 100); do
  AGENT_PID=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null \
    | jq -r --arg label "$AGENT_LABEL" \
      '.result.process_info.foreground_processes[]? | select(.argv0 == $label) | .pid')
  case "$AGENT_PID" in
    '') sleep 0.1 ;;
    *[!0-9]*) fail "more than one stand-in agent reached the lab pane: $AGENT_PID" ;;
    *) break ;;
  esac
done
[ -n "$AGENT_PID" ] || fail "the stand-in agent process never reached the lab pane's foreground"

REGISTERED=$(fm_backend_herdr_cli "$SESSION" agent get "$PANE" 2>/dev/null \
  | jq -r '[.result.agent.agent, .result.agent.agent_status] | @tsv')
[ "$REGISTERED" = "$(printf '%s\tworking' "$AGENT_LABEL")" ] \
  || fail "real herdr did not register the stand-in agent as working, got '$REGISTERED'"

LIVE_STATE=$(fm_backend_herdr_agent_state "$TARGET")
[ "$LIVE_STATE" = alive ] \
  || fail "a registered agent whose process is RUNNING must read alive - this is the refusal that stops a relaunch racing a live agent; got '$LIVE_STATE'"
pass "real herdr: a registered agent with a running process reads alive"

# --- 2. the stranding condition: the agent exits, the registration stays ----
# A turn-end hook reports the finished turn, then the process dies without ever
# calling `pane release-agent`, exactly as the stranded task's agent did.

fm_backend_herdr_cli "$SESSION" pane report-agent "$PANE" \
  --source fm-exited-agent-e2e --agent "$AGENT_LABEL" --state idle --seq 2 >/dev/null 2>&1 \
  || fail "could not report the stand-in agent's turn-end state"
kill -TERM "$AGENT_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  kill -0 "$AGENT_PID" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$AGENT_PID" 2>/dev/null && fail "the stand-in agent process did not exit"

# The condition itself: herdr STILL answers with the registration, and the pane
# is still there. Assert it, or the case below could pass for the wrong reason.
STALE=$(fm_backend_herdr_cli "$SESSION" agent get "$PANE" 2>/dev/null \
  | jq -r '[.result.agent.agent, .result.agent.agent_status] | @tsv')
[ "$STALE" = "$(printf '%s\tidle' "$AGENT_LABEL")" ] \
  || fail "the reproduction is wrong: real herdr no longer reports the exited agent's registration, got '$STALE'"
[ "$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE")" = live ] \
  || fail "the reproduction is wrong: the strict classifier no longer reads the exited agent's pane as live"

DEAD_STATE=$(fm_backend_herdr_agent_state "$TARGET")
[ "$DEAD_STATE" = dead ] \
  || fail "a registration whose agent process provably exited must read dead, or the task stays stranded; got '$DEAD_STATE'"
[ "$DEAD_STATE" != "$LIVE_STATE" ] \
  || fail "the exit evidence is not being read: both verdicts are '$DEAD_STATE'"

# Confinement: the strict classifier, which is what licenses CLOSING a pane,
# must be unchanged by any of this.
fm_backend_herdr_tab_is_husk "$SESSION" "$PANE" \
  && fail "the exited-agent rule leaked into the husk classifier, which licenses closing panes"
pass "real herdr: an exited agent's surviving registration reads dead, and the husk classifier still refuses"

exit 0
