#!/usr/bin/env bash
# Live guard for agy's interrupt and exit mechanics through fm-control.
#
# This spends one short model turn, so it is opt-in.
# It runs only in a named throwaway Herdr lab session and preserves the pane and
# repository after both lifecycle verbs, matching the production control-plane
# contract rather than testing raw keys in isolation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_CONTROL_LIVE_E2E agy herdr jq git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

SESSION=${FM_AGY_CONTROL_LAB_SESSION:-"fm-lab-agy-control-$$"}
OWNS_SESSION=1
[ -z "${FM_AGY_CONTROL_LAB_SESSION:-}" ] || OWNS_SESSION=0
LAB=
WORKSPACE_ID=
cleanup_all() {
  [ -z "$LAB" ] || rm -rf "$LAB"
  if [ "$OWNS_SESSION" -eq 0 ]; then
    [ -z "$WORKSPACE_ID" ] \
      || fm_herdr_lab_cli "$SESSION" workspace close "$WORKSPACE_ID" >/dev/null 2>&1 || true
  else
    herdr_safe_stop_and_delete "$SESSION"
  fi
}
trap cleanup_all EXIT

if [ "$OWNS_SESSION" -eq 1 ]; then
  # provision records the ownership tripwire itself; calling prepare first would
  # leave that tripwire in place and make provision refuse ambiguous ownership.
  fm_herdr_lab_provision "$SESSION" || fail "could not provision the isolated Herdr lab session"
else
  [ "$(fm_herdr_lab_cli "$SESSION" status --json | jq -r '.server.running // false')" = true ] \
    || fail "the caller-supplied Herdr lab session is not running"
fi

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-control.XXXXXX")
REPO="$LAB/repo"
HOME_DIR="$LAB/home"
mkdir -p "$REPO" "$HOME_DIR/state" "$HOME_DIR/data/agy-live"
git -C "$REPO" init -q
printf '# agy lifecycle fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
printf '# agy lifecycle fixture\n' > "$HOME_DIR/data/agy-live/brief.md"

WORKSPACE_JSON=$(fm_herdr_lab_cli "$SESSION" workspace create \
  --cwd "$REPO" --label agy-control-live --no-focus) \
  || fail "could not create the isolated Herdr workspace"
WORKSPACE_ID=$(printf '%s' "$WORKSPACE_JSON" | jq -er '.result.workspace.workspace_id') \
  || fail "workspace creation returned no workspace id"
TAB_ID=$(printf '%s' "$WORKSPACE_JSON" | jq -er '.result.tab.tab_id') \
  || fail "workspace creation returned no tab id"
PANE_ID=$(printf '%s' "$WORKSPACE_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace creation returned no pane id"

cat > "$HOME_DIR/state/agy-live.meta" <<EOF
window=$SESSION:$PANE_ID
endpoint_task_id=agy-live
worktree=$REPO
project=$REPO
harness=agy
kind=scout
mode=no-mistakes
yolo=off
model=gemini-3.7-flash-high
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE_ID
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE_ID
EOF

agy_state() {
  fm_herdr_lab_cli "$SESSION" agent get "$PANE_ID" 2>/dev/null \
    | jq -r '.result.agent.agent_status // .error.code // "unknown"' 2>/dev/null \
    || printf 'unknown\n'
}

pane_tail() {
  fm_herdr_lab_cli "$SESSION" pane read "$PANE_ID" \
    --source recent-unwrapped --lines 100 --format text 2>/dev/null || true
}

PROMPT='Do not read or change any files. Use run_command to execute sleep 120, wait for it to finish, then reply exactly DONE.'
printf -v AGY_COMMAND 'agy --dangerously-skip-permissions -i %q' "$PROMPT"
fm_herdr_lab_cli "$SESSION" pane run "$PANE_ID" "$AGY_COMMAND" >/dev/null \
  || fail "could not launch agy in the isolated pane"

TRUST_SENT=0
STARTED=0
for _ in $(seq 1 150); do
  TAIL=$(pane_tail)
  if [ "$TRUST_SENT" -eq 0 ] && printf '%s' "$TAIL" | grep -Fq 'Do you trust the contents of this project?'; then
    fm_herdr_lab_cli "$SESSION" pane send-keys "$PANE_ID" Enter >/dev/null \
      || fail "could not accept agy's workspace trust prompt"
    TRUST_SENT=1
  fi
  if [ "$(agy_state)" = working ]; then
    STARTED=1
    break
  fi
  sleep 0.2
done
[ "$STARTED" -eq 1 ] || fail "agy never reached its native working state"
printf '%s' "$(pane_tail)" | grep -Fq 'esc to cancel' \
  || fail "agy's running turn did not expose its documented Escape control"

INTERRUPT_OUT=$(env FM_HOME="$HOME_DIR" FM_CONTROL_POLL=0.2 FM_CONTROL_SETTLE_WAIT=1 \
  "$ROOT/bin/fm-control.sh" agy-live interrupt 2>&1) \
  || fail "fm-control could not interrupt the live agy turn: $INTERRUPT_OUT"
printf '%s' "$INTERRUPT_OUT" | grep -Fq \
  'interrupt-delivered agy-live harness=agy backend=herdr verified=agent-alive cancel=unconfirmed' \
  || fail "fm-control returned an unexpected agy interrupt result: $INTERRUPT_OUT"

SETTLED=0
for _ in $(seq 1 50); do
  case "$(agy_state)" in
    idle|done) SETTLED=1; break ;;
  esac
  sleep 0.2
done
[ "$SETTLED" -eq 1 ] || fail "agy did not return to a native settled state after the control-plane interrupt"
printf '%s' "$(pane_tail)" | grep -Fq 'Interrupted' \
  || fail "agy did not render its cancellation acknowledgement after Escape"
pass "agy interrupt: fm-control delivers one Escape and leaves the agent alive and settled"

EXIT_OUT=$(env FM_HOME="$HOME_DIR" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=10 \
  "$ROOT/bin/fm-control.sh" agy-live exit 2>&1) \
  || fail "fm-control could not exit agy: $EXIT_OUT"
printf '%s' "$EXIT_OUT" | grep -Fq 'stopped agy-live harness=agy backend=herdr' \
  || fail "fm-control returned an unexpected agy exit result: $EXIT_OUT"

SHELL_ONLY=0
for _ in $(seq 1 50); do
  PROCESS_JSON=$(fm_herdr_lab_cli "$SESSION" pane process-info --pane "$PANE_ID" 2>/dev/null || true)
  if printf '%s' "$PROCESS_JSON" | jq -e '
    .result.process_info.foreground_processes
    | length == 1
      and (.[0].name | IN("sh", "bash", "zsh", "dash", "fish"))
  ' >/dev/null 2>&1; then
    SHELL_ONLY=1
    break
  fi
  sleep 0.2
done
[ "$SHELL_ONLY" -eq 1 ] || fail "agy exited without returning the preserved pane to its shell"
fm_herdr_lab_cli "$SESSION" pane get "$PANE_ID" >/dev/null \
  || fail "fm-control removed the pane it was required to preserve"
[ -d "$REPO" ] || fail "fm-control removed the repository it was required to preserve"
pass "agy exit: fm-control submits /exit and Herdr proves the agent gone while preserving pane and repository"

AGY_VERSION=$(agy --version 2>&1 | head -1)
HERDR_VERSION=$(fm_herdr_lab_cli "$SESSION" status --json \
  | jq -r '.server.version // .client.version // "unknown"')
note "verified agy $AGY_VERSION through Herdr $HERDR_VERSION"

cleanup_all
trap - EXIT
