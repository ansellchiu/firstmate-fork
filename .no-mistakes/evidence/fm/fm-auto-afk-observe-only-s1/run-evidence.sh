#!/usr/bin/env bash
# Produces the reviewer-visible transcripts for the observe-only Pi idle detector.
set -u
ROOT=$1; EV=$2
EXT="$ROOT/.pi/extensions/fm-pi-auto-afk-observe.ts"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 29min/60s scaled to 3s/5s so a whole cycle is watchable; the state machine,
# the absolute deadlines and the gates are the production ones.
IDLE=3; COUNT=5

home() {
  local h="$WORK/$1"; mkdir -p "$h/state" "$h/config"
  printf '%s\n' "$$" >"$h/state/.lock"
  [ "${2:--}" = "-" ] || printf '%s\n' "$2" >"$h/config/pi-auto-afk"
  printf '%s\n' "$h"
}
drive() { local h=$1 a=$2; shift 2
  env -i PATH="$PATH" HOME="$HOME" EXT="$EXT" ACTIONS="$a" FM_HOME="$h" \
    FM_PI_AUTO_AFK_IDLE_SECONDS=$IDLE FM_PI_AUTO_AFK_COUNTDOWN_SECONDS=$COUNT \
    "$@" node "$EV/session-driver.mjs"
}
log() { echo; echo "state/.pi-auto-afk-observations:"; if [ -e "$1/state/.pi-auto-afk-observations" ]; then sed 's/^/    /' "$1/state/.pi-auto-afk-observations"; else echo "    (file does not exist)"; fi; }
away() { echo; echo "away-posture state after the run:"; for f in .afk-contract .afk .afk-return-catchup; do
    if [ -e "$1/state/$f" ]; then echo "    state/$f  PRESENT"; else echo "    state/$f  absent"; fi; done
  if [ -d "$1/afk-contracts" ]; then echo "    afk-contracts/  PRESENT"; else echo "    afk-contracts/  absent"; fi; }

{
echo "=== A. armed home: config/pi-auto-afk = observe (idle ${IDLE}s / countdown ${COUNT}s) ==="
echo "What the captain sees in the Pi status bar, and what expiry does."
echo
h=$(home armed observe); drive "$h" "wait:9000"; log "$h"; away "$h"
} > "$EV/a-armed-full-cycle.txt" 2>&1

{
echo "=== B. default off: no config/pi-auto-afk ==="
echo "Same scripted session on a home that never opted in."
echo
h=$(home off -); drive "$h" "wait:9000"; log "$h"
} > "$EV/b-default-off.txt" 2>&1

{
echo "=== C. one raw terminal byte during the countdown cancels it ==="
echo
h=$(home cancel observe); drive "$h" "wait:5000,raw:h,wait:6000"; log "$h"; away "$h"
} > "$EV/c-raw-byte-cancels.txt" 2>&1

{
echo "=== D. firstmate's own pi.sendUserMessage traffic does not count as the captain ==="
echo "An extension-sourced input mid-countdown; then a submitted interactive one."
echo
h=$(home ext observe); drive "$h" "wait:5000,input:extension:watcher wake,wait:4000"; log "$h"
echo; echo "--- and a real submitted interactive message, same timing ---"; echo
h2=$(home interactive observe); drive "$h2" "wait:5000,input:interactive:hello,wait:4000"; log "$h2"
} > "$EV/d-source-discrimination.txt" 2>&1

{
echo "=== E. gates: an existing away posture, a foreign lock, a secondmate home, non-tui ==="
echo
h=$(home gate-contract observe); : >"$h/state/.afk-contract"
echo "--- state/.afk-contract already present ---"; drive "$h" "wait:9000"; log "$h"
echo; echo "--- home lock held by another process (pid 999999) ---"
h=$(home gate-lock observe); printf '999999\n' >"$h/state/.lock"; drive "$h" "wait:9000"; log "$h"
echo; echo "--- .fm-secondmate-home marker present ---"
h=$(home gate-second observe); : >"$h/.fm-secondmate-home"; drive "$h" "wait:9000"; log "$h"
echo; echo "--- pi running in rpc mode, not tui ---"
h=$(home gate-rpc observe); drive "$h" "wait:9000" MODE=rpc; log "$h"
} > "$EV/e-gates.txt" 2>&1
echo done
