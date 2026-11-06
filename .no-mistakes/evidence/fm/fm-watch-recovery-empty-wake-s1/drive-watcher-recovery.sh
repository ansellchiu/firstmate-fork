#!/usr/bin/env bash
# drive.sh <tree> <empty|queued> : start the real fm-watch.sh after a dead predecessor's lock
set -u
TREE=$1 MODE=$2
. "$TREE/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fmval-drive)
dir=$(make_case "dead-lock-$MODE"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
dp=none; if [ "${NOLOCK:-0}" != 1 ]; then mkdir "$state/.watch.lock"; dp=$(dead_pid); printf "%s\n" "$dp" > "$state/.watch.lock/pid"; fi
echo "== tree=$(basename $TREE) mode=$MODE dead predecessor pid=$dp"
case "${3:-}" in acked) printf "acked:downtime:gen1\n" > "$state/.watcher-down";; malformed) printf "garbage\n" > "$state/.watcher-down";; esac; echo "-- marker before: $(cat $state/.watcher-down 2>/dev/null || echo absent)"
if [ "$MODE" = queued ]; then append_wake "$state" check startup-network 'check: queued before recovery'; fi
echo "-- durable queue before start:"; ls -1 "$state" | grep -i wake || true; [ -f "$state/.wake-queue" ] && cat "$state/.wake-queue"
PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$TREE/bin/fm-watch.sh" > "$out" 2>&1 &
pid=$!; i=0
while [ $i -lt 40 ] && is_live_non_zombie $pid; do sleep 0.1; i=$((i+1)); done
if is_live_non_zombie $pid; then echo "-- watcher still running after 4s (no wake emitted, stayed armed)"; kill $pid; wait $pid 2>/dev/null; else wait $pid; echo "-- watcher exited rc=$? (wake delivered)"; fi
echo "-- watcher output:"; cat "$out"
echo "-- marker after: $(cat $state/.watcher-down 2>/dev/null || echo absent); quarantine: $(ls -d $state/.watcher-down.invalid.* 2>/dev/null | wc -l | tr -d " ")"
