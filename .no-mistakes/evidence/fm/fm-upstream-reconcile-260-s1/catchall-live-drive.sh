#!/usr/bin/env bash
# Live drive: run the real fm-supervise-daemon.sh (executed, not sourced) in away
# mode against a disposable lab home + private tmux socket. A task status log has
# a watcher-surfaced prefix (.hb-surfaced marker ahead of the daemon's own
# marker) and then a backstop-only needs-decision append. With a 2s catch-all
# cadence the daemon runs several catch-all scans; count how many times the
# event is escalated/injected into the supervisor pane.
# Usage: catchall-live-drive.sh <bin-dir> <label>
set -u
BIN=$1; LABEL=$2
WT=/Users/achiu/.no-mistakes/worktrees/d9c8a3404af5/01M6PW84PZH2MHZDPZTYK3YHQK
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
STATE="$LAB/state"; LOG="$LAB/submitted.log"; : > "$LOG"
SOCK="fm-lab-catchall-$$"
TD=$(mktemp -d /tmp/fmt.XXXX)
T() { TMUX_TMPDIR="$TD" "$REAL_TMUX" -L "$SOCK" "$@"; }
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
printf '#!/usr/bin/env bash\nTMUX_TMPDIR=%q exec %q -L %q "$@"\n' "$TD" "$REAL_TMUX" "$SOCK" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
cleanup() { [ -n "${DPID:-}" ] && { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }; T kill-server 2>/dev/null; rm -rf "$LAB" "$SHIM" "$TD"; }
trap cleanup EXIT
T new-session -d -s supervisor -x 200 -y 50
PANE=$(T display-message -p -t supervisor '#{pane_id}')
cat > "$LAB/loop.sh" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"; stty -echo -icanon min 1 time 0 2>/dev/null
_buf=; redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"; }
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw; continue; fi
  case "$_ch" in $'\r'|$'\n') printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw;; *) _buf="$_buf$_ch"; redraw;; esac
done
LOOP
T send-keys -t "$PANE" "bash '$LAB/loop.sh' '$LOG'" Enter; sleep 1
# Fixture: watcher surfaced 'working: setup' (always-on mode, daemon not running),
# then away mode starts and the worker appends a backstop-only needs-decision.
printf 'working: setup\n' > "$STATE/live-t.status"
( . "$WT/bin/fm-classify-lib.sh"
  sz=$(wc -c < "$STATE/live-t.status" | tr -d ' ')
  status_presentation_marker_commit "$STATE/.hb-surfaced-live-t" "$STATE/live-t.status" "$sz" \
    "$(_fm_open_decisions_file_ident "$STATE/live-t.status")" )
date +%s > "$STATE/.afk"
printf 'needs-decision: pick A or B\n' >> "$STATE/live-t.status"
touch -t 202001010000 "$STATE/live-t.status"   # old mtime: no fresh signal wake
# The signal path misses this append (the case the catch-all exists for): the
# watcher's own signal marker already covers the current snapshot.
( FM_STATE_OVERRIDE="$STATE" FM_HOME="$LAB"; . "$WT/bin/fm-classify-lib.sh"; . "$WT/bin/fm-wake-lib.sh"
  fm_wake_status_mark_current "$STATE" "$STATE/live-t.status"
  fm_wake_status_reported_commit "$STATE" "$STATE/live-t.status" "$(fm_wake_signal_sig "$STATE/live-t.status")" ) || echo "seed failed"
FM_HOME="$LAB" FM_DAEMON_PRIMARY_HARNESS=unknown PATH="$SHIM:$PATH" \
  FM_STATE_OVERRIDE="$STATE" FM_SUPERVISOR_TARGET="$PANE" FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT_SCAN_SECS=2 \
  FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=5 FM_STALE_ESCALATE_SECS=999999 \
  FM_WEDGE_ALARM_EXEC=discard \
  nohup "$BIN/fm-supervise-daemon.sh" > "$LAB/daemon.out" 2> "$LAB/daemon.err" &
DPID=$!
sleep 20
echo "=== [$LABEL] daemon bin: $BIN"
echo "--- catch-all scans observed (.subsuper-last-scan present): $( [ -e "$STATE/.subsuper-last-scan" ] && echo yes || echo no)"
echo "--- daemon own marker vs log size:"; cat "$STATE"/.subsuper-seen-status-live-t 2>/dev/null; echo " log=$(wc -c < "$STATE/live-t.status")"
echo "--- digests injected into supervisor pane (submitted lines mentioning the event):"
grep -c 'pick A or B' "$LOG"
grep -o 'live-t.status: needs-decision: pick A or B[^|]*' "$LOG" | sed 's/^/  /' | head
echo "--- digest archive event count:"; cat "$STATE"/.subsuper-digests/* 2>/dev/null | grep -c 'pick A or B'
echo "--- daemon routing log:"; cat "$STATE"/.supervise-daemon.log 2>/dev/null | sed "s/^/  /" | grep -v "^  *$" | head -30
echo "--- daemon stderr tail:"; tail -5 "$LAB/daemon.err"
