#!/usr/bin/env bash
# Drives the real bin/fm-watch-arm.sh + real bin/fm-watch.sh in a disposable lab home.
set -u
W=$1; MODE=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$W/bin/fm-lab-home.sh" create "$LAB" >/dev/null
CAP=$(mktemp -d "${TMPDIR:-/tmp}/fm-cap.XXXXXX")
[ "$MODE" = tmpdir-unwritable ] && chmod 500 "$CAP"
echo "== mode=$MODE lab=$LAB"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" TMPDIR="$CAP" "$W/bin/fm-watch-arm.sh" >"$LAB/arm.stdout" 2>"$LAB/arm.stderr" &
ARM=$!
i=0; while [ ! -e "$LAB/state/.watch.lock/pid" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
sleep 1
WPID=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
echo "arm=$ARM watcher=$WPID live=$(kill -0 "$WPID" 2>/dev/null && echo yes || echo no)"
echo "captures during run: $(ls "$CAP" 2>&1)"
case "$MODE" in
  lock-removed|tmpdir-unwritable) rm -rf "$LAB/state/.watch.lock" ;;
  state-removed) rm -rf "$LAB/state" ;;
  arm-term) kill -TERM "$ARM" ;;
esac
i=0; while kill -0 $ARM 2>/dev/null && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
wait $ARM; echo "arm exit=$?"
echo "--- arm stdout"; cat "$LAB/arm.stdout"
echo "--- arm stderr"; cat "$LAB/arm.stderr"
echo "--- state/.watch-cycle-stderr.log"; cat "$LAB/state/.watch-cycle-stderr.log" 2>&1
echo "--- leftover captures in TMPDIR: [$(ls -A "$CAP")] in state: [$(ls -A "$LAB/state" 2>/dev/null | grep -E 'watch-arm-output|fm-watch-arm-err' )]"
ls -l /dev/null
chmod 700 "$CAP"; rm -rf "$LAB" "$CAP"
