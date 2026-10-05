#!/usr/bin/env bash
# Live driver: real bin/fm-watch.sh + real tmux (private socket) + real fm-teardown
# against a disposable marked lab home. Usage: drive-standdown.sh <repo-root> <variant>
# variant: incident (pr= + stamped needs-decision/resolved status), stamped-only,
#          pr-only, empty (control: genuinely never started).
set -u
ROOT=$1; VARIANT=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TMUXD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TMUXD"; unset TMUX
cleanup() { tmux kill-server 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
# The Treehouse worktree pool is external machine state; a lab-local no-op shim keeps teardown off the real pool.
mkdir -p "$LAB/shim"; printf '#!/bin/sh\nexit 0\n' > "$LAB/shim/treehouse"; chmod +x "$LAB/shim/treehouse"; export PATH="$LAB/shim:$PATH"
STATE="$LAB/state"; DATA="$LAB/data"; task=fm-dispatch-model-id-validation-s1
proj="$LAB/projects/demo"; wt="$LAB/wt"
mkdir -p "$proj" "$DATA/$task"; echo brief > "$DATA/$task/brief.md"
git init -q -b main "$proj"; git -C "$proj" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
git -C "$proj" worktree add -q -b "$task" "$wt" main
tmux new-session -d -s lab -n "fm-$task" "printf 'Please authenticate: Sign in with Google to continue\n'; sleep 3600"
win="lab:fm-$task"
printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nspawn_gen=1\ndispatch_base=%s\n' \
  "$win" "$task" "$wt" "$proj" "$(git -C "$wt" rev-parse HEAD)" > "$STATE/$task.meta"
: > "$STATE/$task.status"
case "$VARIANT" in
  incident|pr-only) echo 'pr=https://github.com/ansellchiu/firstmate-fork/pull/33' >> "$STATE/$task.meta" ;; esac
case "$VARIANT" in
  incident|stamped-only) printf 'needs-decision [at=1791218000] [key=ci-1]: CI failed on PR 33, retry or fix?\nresolved [at=1791218932] [key=ci-1]: answered: fix\n' > "$STATE/$task.status" ;; esac
( cd "$LAB" && tasks-axi add "$task" "model id validation" --file "$DATA/backlog.md" >/dev/null 2>&1 && tasks-axi start "$task" --file "$DATA/backlog.md" >/dev/null 2>&1 )
echo "== variant=$VARIANT  meta:"; cat "$STATE/$task.meta"; echo "== status:"; cat "$STATE/$task.status"
probe() { FM_HOME="$LAB" bash -c '. "$1/bin/fm-classify-lib.sh"; printf "crew-state: %s | absorb=%s | " "$("$1/bin/fm-crew-state.sh" "$2" 2>&1 | head -1)" "$(crew_absorb_class "$2")"; if crew_is_never_started "$2" "$3"; then echo never-started=YES; else echo never-started=no; fi' _ "$ROOT" "$task" "$STATE"; }
echo "== classifier probe before watcher: $(probe)"
for round in 1 2 3 4 5 6; do
  out="$LAB/watch.$round.out"
  ( env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$LAB" FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_STALE_AUTO_STANDDOWN_THRESHOLD=3 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      timeout 40 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$out.err" ) 
  echo "== round $round watcher said: $(grep -E 'stale|auto-standdown' "$out" | head -2)"
  FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>"$LAB/drain.err"
  seq=$(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\1 \2/p' "$LAB/drain.err")
  [ -n "$seq" ] && FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" --ack-through ${seq% *} --recovery-generation ${seq#* } >/dev/null 2>&1
  grep -q auto-standdown "$out" && break
  [ -f "$STATE/$task.meta" ] || break
done
echo "== after: meta present? $([ -f "$STATE/$task.meta" ] && echo yes || echo NO)  status present? $([ -f "$STATE/$task.status" ] && echo yes || echo NO)"
echo "== escalation count: $(cat "$STATE"/.wedge-escalations-* 2>/dev/null)"
echo "== standdown log: $(cat "$STATE"/.standdown-*.log 2>/dev/null | head -c 600)"; grep -h auto-standdown "$STATE"/*triage* "$STATE"/.triage* 2>/dev/null | tail -2
echo "== backlog:"; cat "$DATA/backlog.md"
