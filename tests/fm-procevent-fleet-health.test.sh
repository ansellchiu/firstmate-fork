#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-fleet-health.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-fleet-health.XXXXXX")
FAKEBIN="$LAB/fakebin"
STATE="$LAB/state"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN" "$STATE"

# The fake runner API answers from FLEET_RUNNER: `online`, `offline`, `none`,
# or `error`, switching to FLEET_RUNNER_THEN after FLEET_RUNNER_AFTER calls.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${FLEET_COUNT:-/dev/null}" ] || read -r count < "$FLEET_COUNT"
count=$((count + 1))
[ -z "${FLEET_COUNT:-}" ] || printf '%s\n' "$count" > "$FLEET_COUNT"
mode=${FLEET_RUNNER:-online}
if [ -n "${FLEET_RUNNER_THEN:-}" ] && [ "$count" -gt "${FLEET_RUNNER_AFTER:-0}" ]; then
  mode=$FLEET_RUNNER_THEN
fi
case "$mode" in
  online)  printf 'online\n' ;;
  offline) printf 'offline\n' ;;
  none)    : ;;
  error)   exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# The fake box answers `true` reachability and, for the OOM probe, runs the
# script the adapter sends the way a real remote shell would, against a fake
# kernel log that holds FLEET_OOM OOM lines and fails to read at all when
# FLEET_JOURNAL is not `ok`. Running the real script is what makes the exit
# status of a clean read observable.
cat > "$FAKEBIN/sudo" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = journalctl ] || exit 1
[ "${FLEET_JOURNAL:-ok}" = ok ] || exit 1
i=0
while [ "$i" -lt "${FLEET_OOM:-0}" ]; do
  printf 'kernel: Out of memory: Killed process %s\n' "$i"
  i=$((i + 1))
done
SH
chmod +x "$FAKEBIN/sudo"

cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
[ "${FLEET_BOX:-up}" = up ] || exit 255
for arg in "$@"; do
  case "$arg" in
    *journalctl*) exec bash -c "$arg" ;;
  esac
done
exit 0
SH
chmod +x "$FAKEBIN/ssh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# poll_once <timeout-secs> [env assignments already exported] - run one poll
# bounded so a deliberately silent poll cannot hang the suite.
run_poll() {
  local bound=$1; shift
  FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" \
    perl -e 'alarm shift; exec @ARGV' "$bound" \
    "$BIN/fm-procevent-fleet-health.sh" poll --repo owner/repo --host box \
    --interval 0.01 --confirm 2 --timeout 5 "$@"
}

if help=$("$BIN/fm-procevent-fleet-health.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-fleet-health.sh retire' || fail "help omitted retire"
printf '%s\n' "$help" | grep -Fq 'set -u' && fail "help leaked executable source"
ok "help renders only the complete header"

if err=$("$BIN/fm-procevent-fleet-health.sh" poll --host box 2>&1); then
  fail "poll without a repo unexpectedly succeeded"
fi
[ "$err" = "error: at least one --repo is required" ] || fail "missing repo returned: $err"
ok "poll refuses to watch nothing"

# A healthy fleet never returns: the poll is killed by its own bound, silent.
rm -f "$STATE/fleet-health.state"
out=$(FLEET_RUNNER=online FLEET_BOX=up FLEET_OOM=0 run_poll 2 2>/dev/null)
[ -z "$out" ] || fail "healthy poll emitted output: $out"
[ ! -f "$STATE/fleet-health.state" ] || fail "healthy poll wrote a marker"
ok "a healthy poll stays silent and records nothing"

# An outage returns exactly one result, and autohandle records it.
out=$(FLEET_RUNNER=offline FLEET_BOX=up FLEET_OOM=0 run_poll 10)
printf '%s\n' "$out" | grep -qx 'status: problem' || fail "outage did not report a problem: $out"
printf '%s\n' "$out" | grep -qx 'problems: runner:owner/repo' || fail "outage named the wrong problem: $out"
printf '%s\n' "$out" | grep -q 'owner/repo runner: offline' || fail "outage omitted the detail: $out"
ok "an outage produces exactly one problem result"

# autohandle_capture <sequence> <result-file> - run the adapter's autohandle the
# way the runner does. It always refuses to acknowledge: recording the announced
# health is its whole job, and closing the capture is the handler's.
autohandle_capture() {
  if FM_HOME="$LAB" FM_STATE_OVERRIDE="$STATE" \
      "$BIN/fm-procevent-fleet-health.sh" autohandle fleet-health "$1" "$2" 2>/dev/null; then
    fail "autohandle acknowledged its own announcement for sequence $1"
  fi
}

# Stage the capture the way the runner does, so the handled acknowledgement
# has the inbox record it demands.
INBOX="$STATE/procevent-inbox"
mkdir -p "$INBOX"
stage_capture() { # <sequence> <result-text>
  printf '%s\n' "$2" > "$INBOX/fleet-health.$1.result"
  printf 'fleet-health\n' > "$INBOX/fleet-health.$1.adapter"
  printf '%s\n' "$INBOX/fleet-health.$1.result"
}

RESULT=$(stage_capture 1 "$out")
[ "$(FM_STATE_OVERRIDE="$STATE" "$BIN/fm-procevent-fleet-health.sh" classify "$RESULT")" = problem ] \
  || fail "classify did not read the problem status"
if FM_STATE_OVERRIDE="$STATE" "$BIN/fm-procevent-fleet-health.sh" terminal "$RESULT"; then
  fail "a fleet-health capture claimed to end its source"
fi
ok "a problem capture classifies and keeps the source armed"

autohandle_capture 1 "$RESULT"
[ "$(FM_STATE_OVERRIDE="$STATE" "$BIN/fm-procevent-fleet-health.sh" state)" = problem ] \
  || fail "autohandle did not record the announced problem"
ok "autohandle records the announced outage"

# The same outage, still standing, says nothing more - including after a
# restart, because the marker and not conversation memory is what remembers.
out=$(FLEET_RUNNER=offline FLEET_BOX=up FLEET_OOM=0 run_poll 2 2>/dev/null)
[ -z "$out" ] || fail "a standing outage re-announced itself: $out"
ok "a restart during a standing outage does not re-announce it"

# Recovery returns exactly one result the other way.
out=$(FLEET_RUNNER=online FLEET_BOX=up FLEET_OOM=0 run_poll 10)
printf '%s\n' "$out" | grep -qx 'status: recovered' || fail "recovery did not report recovered: $out"
printf '%s\n' "$out" | grep -qx 'problems: none' || fail "recovery still named problems: $out"
ok "a clear produces exactly one recovery result"

RESULT=$(stage_capture 2 "$out")
[ "$(FM_STATE_OVERRIDE="$STATE" "$BIN/fm-procevent-fleet-health.sh" classify "$RESULT")" = recovered \
  ] || fail "classify did not read the recovered status"
autohandle_capture 2 "$RESULT"
[ "$(FM_STATE_OVERRIDE="$STATE" "$BIN/fm-procevent-fleet-health.sh" state)" = healthy \
  ] || fail "autohandle did not record the recovery"
out=$(FLEET_RUNNER=online FLEET_BOX=up FLEET_OOM=0 run_poll 2 2>/dev/null)
[ -z "$out" ] || fail "a recovered fleet kept announcing: $out"
ok "autohandle records the recovery and the fleet goes quiet again"

# One blip does not open an episode: --confirm needs consecutive agreement.
rm -f "$STATE/fleet-health.state"
COUNT="$LAB/count"
rm -f "$COUNT"
out=$(FLEET_COUNT="$COUNT" FLEET_RUNNER=error FLEET_RUNNER_THEN=online FLEET_RUNNER_AFTER=1 \
  FLEET_BOX=up FLEET_OOM=0 run_poll 2 2>/dev/null)
[ -z "$out" ] || fail "a single API blip announced an outage: $out"
ok "a single blip does not open an episode"

# Each watched condition reaches the wake on its own.
rm -f "$STATE/fleet-health.state"
out=$(FLEET_RUNNER=online FLEET_BOX=down run_poll 10)
printf '%s\n' "$out" | grep -qx 'problems: box-unreachable' || fail "a dead box was not distinguished: $out"
rm -f "$STATE/fleet-health.state"
out=$(FLEET_RUNNER=online FLEET_BOX=up FLEET_OOM=3 run_poll 10)
printf '%s\n' "$out" | grep -qx 'problems: box-oom' || fail "recent OOM kills did not fire: $out"
printf '%s\n' "$out" | grep -q '3 OOM kill line' || fail "OOM detail omitted the count: $out"
rm -f "$STATE/fleet-health.state"
out=$(FLEET_RUNNER=none FLEET_BOX=up FLEET_OOM=0 run_poll 10)
printf '%s\n' "$out" | grep -q 'no registration found' || fail "a missing registration did not fire: $out"
ok "each watched condition fires on its own"

# A repo whose runners are all deregistered - the very outage this trip wire
# exists for - rides the same durable marker as any other problem: it wakes
# once when it starts, stays silent while it stands, and wakes once when it
# clears.
rm -f "$STATE/fleet-health.state"
out=$(FLEET_RUNNER=none FLEET_BOX=up FLEET_OOM=0 run_poll 10)
printf '%s\n' "$out" | grep -qx 'problems: runner:owner/repo' \
  || fail "a missing registration did not open an episode: $out"
RESULT=$(stage_capture 3 "$out")
autohandle_capture 3 "$RESULT"
[ "$(FM_STATE_OVERRIDE="$STATE" "$BIN/fm-procevent-fleet-health.sh" state)" = problem ] \
  || fail "autohandle did not record the missing registration"
out=$(FLEET_RUNNER=none FLEET_BOX=up FLEET_OOM=0 run_poll 2 2>/dev/null)
[ -z "$out" ] || fail "a standing missing registration re-announced itself: $out"
out=$(FLEET_RUNNER=online FLEET_BOX=up FLEET_OOM=0 run_poll 10)
printf '%s\n' "$out" | grep -qx 'status: recovered' \
  || fail "a re-registered runner did not announce a recovery: $out"
RESULT=$(stage_capture 4 "$out")
autohandle_capture 4 "$RESULT"
out=$(FLEET_RUNNER=online FLEET_BOX=up FLEET_OOM=0 run_poll 2 2>/dev/null)
[ -z "$out" ] || fail "a re-registered runner kept announcing: $out"
ok "a missing registration wakes once, stays silent, and wakes once on clear"

# A readable kernel log with no OOM lines is a clean box, not an unknown one,
# and only a journal that actually fails to read stays unknown.
rm -f "$STATE/fleet-health.state"
out=$(FLEET_RUNNER=offline FLEET_BOX=up FLEET_OOM=0 run_poll 10)
printf '%s\n' "$out" | grep -q 'box box: no recent OOM kills' \
  || fail "a clean kernel log was not reported as clean: $out"
rm -f "$STATE/fleet-health.state"
out=$(FLEET_RUNNER=offline FLEET_BOX=up FLEET_JOURNAL=unreadable run_poll 10)
printf '%s\n' "$out" | grep -q 'kernel log unreadable, OOM state unknown' \
  || fail "an unreadable kernel log was not reported unknown: $out"
printf '%s\n' "$out" | grep -qx 'problems: runner:owner/repo' \
  || fail "an unreadable kernel log changed the problem set: $out"
ok "a clean kernel log reads clean and only a failed read is unknown"

# Arming refuses a repo whose runner API cannot answer, so a typo or a missing
# credential never arms a watch that would report a permanent fake outage.
ARM_HOME="$LAB/arm-probe"
mkdir -p "$ARM_HOME"
if err=$(FM_HOME="$ARM_HOME" PATH="$FAKEBIN:$PATH" FLEET_RUNNER=error \
    "$BIN/fm-procevent-fleet-health.sh" arm --repo owner/repo --timeout 5 2>&1); then
  fail "arm accepted a repo whose runner API does not answer"
fi
printf '%s\n' "$err" | grep -q 'owner/repo' || fail "arm refusal did not name the repo: $err"
[ ! -e "$ARM_HOME/state/procevent/fleet-health.source" ] \
  || fail "a refused arm still published a registration"
FM_HOME="$ARM_HOME" PATH="$FAKEBIN:$PATH" FLEET_RUNNER=online \
  "$BIN/fm-procevent-fleet-health.sh" arm --repo owner/repo --timeout 5 >/dev/null \
  || fail "arm refused a repo whose runner API answers"
[ -e "$ARM_HOME/state/procevent/fleet-health.source" ] \
  || fail "an accepted arm published no registration"
FM_HOME="$ARM_HOME" "$BIN/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
ok "arm probes the runner API before registering the watch"

out=$(FM_HOME="$LAB/retire-home" FM_STATE_OVERRIDE="$LAB/retire-state" \
  "$BIN/fm-procevent-fleet-health.sh" retire)
[ "$out" = "retired: fleet-health" ] || fail "retire targeted the wrong source: $out"
ok "retire resolves the canonical source id"

# --- end to end through the real runner ------------------------------------
# The acceptance criterion is a wake count, so prove it against the runner that
# publishes wakes rather than against the poll's stdout alone.
HOME_E2E="$LAB/e2e"
mkdir -p "$HOME_E2E/state"
export FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
wake_lines() { grep -c . "$HOME_E2E/state/.wake-queue" 2>/dev/null || printf '0\n'; }

# The handler - not the adapter - closes a capture, so the test plays that part.
latest_seq() {
  local f seq=0 n
  for f in "$HOME_E2E/state/procevent-inbox"/fleet-health.*.result; do
    [ -e "$f" ] || continue
    n=${f##*/fleet-health.}; n=${n%.result}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -le "$seq" ] || seq=$n
  done
  printf '%s\n' "$seq"
}
handle_latest() {
  FM_HOME="$HOME_E2E" "$BIN/fm-procevent.sh" handled fleet-health "$(latest_seq)" >/dev/null \
    || fail "the handler could not acknowledge the capture"
}
reconcile() {
  FM_HOME="$HOME_E2E" PATH="$FAKEBIN:$PATH" \
    perl -e 'alarm shift; exec @ARGV' 20 \
    "$BIN/fm-procevent.sh" reconcile >/dev/null 2>&1
  return 0
}

# One attached capture cycle. Each transition returns on its own, so the bound
# here only stops a broken poll from hanging the suite; the silent-poll cases
# are proved above against the poll itself, where killing one leaves no claim.
capture() {
  FM_HOME="$HOME_E2E" PATH="$FAKEBIN:$PATH" \
    perl -e 'alarm shift; exec @ARGV' "$1" \
    "$BIN/fm-procevent.sh" start fleet-health >/dev/null 2>&1
  return 0
}

FM_HOME="$HOME_E2E" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-fleet-health.sh" arm \
  --repo owner/repo --host box --interval 0.01 --confirm 2 --timeout 5 >/dev/null \
  || fail "arm did not register the fleet-health source"
[ "$(wake_lines)" = 0 ] || fail "arming alone queued a wake"

export FLEET_RUNNER=offline FLEET_BOX=up FLEET_OOM=0
capture 20
[ "$(wake_lines)" = 1 ] || fail "the outage did not produce exactly one wake: $(wake_lines)"
[ "$(FM_STATE_OVERRIDE="$HOME_E2E/state" "$BIN/fm-procevent-fleet-health.sh" state)" = problem ] \
  || fail "the runner did not record the announced outage"

# An announcement nobody has handled yet is still owed, so the marker alone must
# not retire it: reconcile re-announces it until the handler acknowledges it.
FM_HOME="$HOME_E2E" "$BIN/fm-procevent.sh" retire fleet-health >/dev/null \
  || fail "could not retire the source before reconciling"
reconcile
[ "$(wake_lines)" = 2 ] \
  || fail "an unacknowledged outage was not re-announced: $(wake_lines)"
handle_latest
reconcile
[ "$(wake_lines)" = 2 ] \
  || fail "a handled outage was announced again: $(wake_lines)"
ok "an unacknowledged transition is re-announced until a handler closes it"

FM_HOME="$HOME_E2E" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-fleet-health.sh" arm \
  --repo owner/repo --host box --interval 0.01 --confirm 2 --timeout 5 >/dev/null \
  || fail "arm did not re-register the fleet-health source"
FLEET_RUNNER=online
capture 20
[ "$(wake_lines)" = 3 ] || fail "the clear did not produce exactly one more wake: $(wake_lines)"
[ "$(FM_STATE_OVERRIDE="$HOME_E2E/state" "$BIN/fm-procevent-fleet-health.sh" state)" = healthy ] \
  || fail "the runner did not record the recovery"
handle_latest

ok "an armed source wakes exactly once per transition"

FM_HOME="$HOME_E2E" "$BIN/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true

printf '# all fm-procevent-fleet-health tests passed\n'
