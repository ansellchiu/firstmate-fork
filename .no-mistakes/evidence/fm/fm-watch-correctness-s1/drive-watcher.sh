#!/usr/bin/env bash
# Drives the real bin/fm-watch.sh from tree $1 against disposable state dirs.
# Usage: drive-watcher.sh <tree-root> <helpers-source-tree>
set -u
TREE=$1; HELP=$2
. "$TREE/tests/wake-helpers.sh"
. "$TREE/bin/fm-classify-lib.sh"
eval "$(sed -n '78,192p' "$HELP/tests/fm-watch-triage.test.sh")"
WATCH="$TREE/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-drive)
fail() { echo "FAIL: $*"; }
echo "=== tree: $TREE ($(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || cat "$TREE/.rev"))"

# S1/S3: absorbed heartbeat (no AFK) across streak values
for v in '1 2' 'abc' '' '-3' 4; do
  dir=$(make_case "absorb-$(printf '%s' "$v" | tr -c 'a-z0-9' _)x"); state="$dir/state"; out="$dir/watch.out"
  printf '%s' "$v" > "$state/.heartbeat-streak"; touch -t 200001010000 "$state/.last-heartbeat"
  expected=1; [ "$v" = 4 ] && expected=5
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_WAKE_BATCH_WINDOW=1 "$WATCH" > "$out" 2>&1 &
  pid=$!; i=0
  while [ $i -lt 150 ]; do
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null)" = "$expected" ] && break
    kill -0 $pid 2>/dev/null || break; sleep 0.1; i=$((i+1))
  done
  alive=no; kill -0 $pid 2>/dev/null && alive=yes
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  printf 'absorbed-heartbeat streak=%-6q -> streak=%s watcher_alive=%s errors=%s\n' "$v" \
    "$(cat "$state/.heartbeat-streak" 2>/dev/null)" "$alive" \
    "$(grep -ciE 'syntax error|integer expression|value too great' "$out")"
  grep -iE 'syntax error|integer expression' "$out" | sed 's/^/    stderr: /' | head -3
done

# S2: AFK-present heartbeat -> wake() path
for v in '1 2' 'junk'; do
  dir=$(make_case "afk-$(printf '%s' "$v" | tr -c 'a-z0-9' _)x"); state="$dir/state"; out="$dir/watch.out"
  printf '%s' "$v" > "$state/.heartbeat-streak"; touch -t 200001010000 "$state/.last-heartbeat"
  date '+%s' > "$state/.afk"; seed_daemon_lock "$state"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" 2>&1 &
  pid=$!; wait_for_exit $pid 150; wait $pid; rc=$?
  printf 'afk-heartbeat streak=%-6q -> exit=%s streak=%s queued_heartbeat=%s stdout_heartbeat=%s errors=%s\n' "$v" "$rc" \
    "$(cat "$state/.heartbeat-streak" 2>/dev/null)" \
    "$(awk -F '\t' '$3=="heartbeat"{n++} END{print n+0}' "$state/.wake-queue" 2>/dev/null)" \
    "$(grep -c '^heartbeat' "$out")" \
    "$(grep -ciE 'syntax error|integer expression' "$out")"
  grep -iE 'syntax error|integer expression' "$out" | sed 's/^/    stderr: /' | head -3
done

# S4: parked live worker, pane churn -> pause_state_class none -> clear_stale_hash_tracking
dir=$(make_case parked-churn); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; cap="$dir/pane.txt"; statusf="$state/parked.status"; window=test:fm-parked
key=$(printf '%s' "$window" | tr ':/.' '___')
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/parked.meta"
printf 'paused: waiting on the validation run to finish\n' > "$statusf"
printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-parked_status"
printf '%s' 'parked, elapsed 1s' > "$cap"
printf '%s' "$(hash_text 'parked, elapsed 1s')" > "$state/.hash-$key"; printf '1\n' > "$state/.count-$key"
# Adversarial: the .stale-sig file is executable; if the watcher runs it as a command it leaves a marker.
printf '#!/bin/sh\ntouch "%s/EXECUTED-stale-sig"\n' "$dir" > "$state/.stale-sig-$key"; chmod +x "$state/.stale-sig-$key"
printf 'parked, elapsed 2s' > "$cap"   # a new hash -> the hash-change branch
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$cap" \
  FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$WATCH" > "$out" 2>&1 &
pid=$!; c=0
while [ $c -lt 3 ]; do wait_poll_cycle "$state" $pid 300 || break; c=$((c+1)); done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
printf 'parked-churn: .stale-sig-%s present_after=%s executed_as_command=%s stale_sig_errors=%s\n' "$key" \
  "$([ -e "$state/.stale-sig-$key" ] && echo yes || echo no)" \
  "$([ -e "$dir/EXECUTED-stale-sig" ] && echo YES || echo no)" \
  "$(grep -c 'stale-sig' "$out")"
grep 'stale-sig' "$out" | sed 's/^/    stderr: /' | head -3
rm -rf "$TMP_ROOT"
