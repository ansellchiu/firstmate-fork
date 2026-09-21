#!/usr/bin/env bash
# The default-off, observe-only Pi idle detector.
#
# The first test is the important one: a home that has not opted in must not
# touch the status bar, subscribe to input, or write anything. The rest prove
# the observer observes and - the point of the whole prototype - that expiry
# never enters the away posture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v npm >/dev/null 2>&1 || { echo "skip: npm not found"; exit 0; }
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
[ -f "$PI_PACKAGE_DIR/package.json" ] || { echo "skip: installed @earendil-works/pi-coding-agent not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-pi-auto-afk-observe)
EXT="$ROOT/.pi/extensions/fm-pi-auto-afk-observe.ts"
LOCK_PID=$$

cat > "$TMP_ROOT/driver.mjs" <<'JS'
// Drives the extension against a stub Pi and prints one trace line per
// observable effect. ACTIONS is a comma list: wait:<ms>, raw:<bytes>,
// input:<source>:<text>, shutdown.
import { pathToFileURL } from "node:url";

const extension = await import(pathToFileURL(process.env.EXT).href);
const trace = [];
const handlers = new Map();
let terminalHandler;
let subscriptions = 0;

const ctx = {
  mode: process.env.MODE || "tui",
  ui: {
    setStatus(key, text) {
      trace.push(`setStatus ${key} ${text === undefined ? "<cleared>" : text}`);
    },
    notify(message) {
      trace.push(`notify ${message}`);
    },
    onTerminalInput(handler) {
      subscriptions += 1;
      trace.push("subscribe");
      terminalHandler = handler;
      return () => {
        trace.push("unsubscribe");
        terminalHandler = undefined;
      };
    },
  },
};

extension.default({
  on(event, handler) {
    handlers.set(event, handler);
    return () => {};
  },
});

const fire = (event, payload) => handlers.get(event)?.(payload ?? { type: event }, ctx);
fire("session_start");

for (const action of (process.env.ACTIONS || "").split(",").filter(Boolean)) {
  const [verb, ...rest] = action.split(":");
  if (verb === "wait") await new Promise((r) => setTimeout(r, Number(rest[0])));
  else if (verb === "raw") {
    const result = terminalHandler?.(rest.join(":"));
    if (result !== undefined) trace.push(`raw-altered ${JSON.stringify(result)}`);
  } else if (verb === "input") {
    fire("input", { type: "input", source: rest[0], text: rest.slice(1).join(":") });
  } else if (verb === "shutdown") fire("session_shutdown");
  else throw new Error(`unknown action ${action}`);
}

trace.push(`subscriptions=${subscriptions}`);
console.log(trace.join("\n"));
// Exit rather than draining the event loop: the assertions below read the
// observation log after this process ends, so the scripted window must be the
// whole window.
process.exit(0);
JS

# fixture <name> <config-value|-> ; echoes the home path
fixture() {
  local value=$2 home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$LOCK_PID" >"$home/state/.lock"
  [ "$value" = "-" ] || printf '%s\n' "$value" >"$home/config/pi-auto-afk"
  printf '%s\n' "$home"
}

# drive <home> <idle-seconds> <countdown-seconds> <actions> [extra env assignments...]
drive() {
  local home=$1 idle=$2 countdown=$3 actions=$4
  shift 4
  env -i PATH="$PATH" HOME="$HOME" \
    EXT="$EXT" ACTIONS="$actions" \
    FM_HOME="$home" \
    FM_PI_AUTO_AFK_IDLE_SECONDS="$idle" \
    FM_PI_AUTO_AFK_COUNTDOWN_SECONDS="$countdown" \
    "$@" \
    node "$TMP_ROOT/driver.mjs"
}

log_of() { cat "$1/state/.pi-auto-afk-observations" 2>/dev/null; }

# --- 1. default off is inert ------------------------------------------------
test_off_is_inert() {
  local home out
  home=$(fixture off -)
  out=$(drive "$home" 0.1 0.1 "wait:500") || fail "off-path driver failed"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && [ "$out" = "subscriptions=0" ] \
    || fail "an opted-out home produced observable effects: $out"
  [ -e "$home/state/.pi-auto-afk-observations" ] \
    && fail "an opted-out home wrote an observation log"
  pass "absent config/pi-auto-afk leaves the session untouched: no status, no input listener, no writes"

  # An unrecognized value is off too, not a typo that silently arms.
  home=$(fixture off-typo on)
  out=$(drive "$home" 0.1 0.1 "wait:500") || fail "unrecognized-value driver failed"
  [ "$out" = "subscriptions=0" ] || fail "config/pi-auto-afk=on armed the observer: $out"
  pass "only the exact value observe arms it; any other value stays off"
}

# --- 2. countdown ------------------------------------------------------------
test_countdown() {
  local home out
  home=$(fixture countdown observe)
  out=$(drive "$home" 0.2 5 "wait:600") || fail "countdown driver failed"
  printf '%s\n' "$out" | grep -q '^subscribe$' || fail "no raw input listener: $out"
  printf '%s\n' "$out" | grep -q 'setStatus firstmate-auto-afk Auto-AFK in [1-5]s - any Pi input cancels; /afk enters now' \
    || fail "countdown status not shown: $out"
  log_of "$home" | grep -q 'observe	countdown-start' || fail "countdown start not recorded: $(log_of "$home")"
  pass "on an opted-in home the idle deadline opens a visible countdown and records it"
}

# --- 3. any Pi input cancels -------------------------------------------------
test_input_cancels() {
  local home out
  home=$(fixture cancel observe)
  out=$(drive "$home" 0.2 5 "wait:600,raw:x,wait:900") || fail "cancel driver failed"
  printf '%s\n' "$out" | grep -q 'setStatus firstmate-auto-afk <cleared>' || fail "countdown not cleared: $out"
  printf '%s\n' "$out" | grep -q '^raw-altered' && fail "the listener altered the bytes Pi sees: $out"
  log_of "$home" | grep -q 'cancelled.*remaining=' || fail "cancellation not recorded: $(log_of "$home")"
  log_of "$home" | grep -q 'would-enter' && fail "a cancelled countdown still reached expiry"
  pass "one raw terminal byte cancels the countdown, is returned unchanged, and is recorded"

  # Firstmate's own pi.sendUserMessage traffic is source=extension and must not
  # look like the captain; a submitted interactive message must.
  home=$(fixture cancel-extension observe)
  out=$(drive "$home" 0.3 0.1 "input:extension:watcher wake,wait:800") || fail "extension-source driver failed"
  log_of "$home" | grep -q 'would-enter' || fail "extension input reset the idle timer: $out"
  pass "extension-sourced input does not count as the captain"

  home=$(fixture cancel-interactive observe)
  out=$(drive "$home" 0.2 5 "wait:600,input:interactive:hello,wait:400") || fail "interactive-source driver failed"
  printf '%s\n' "$out" | grep -q 'setStatus firstmate-auto-afk <cleared>' \
    || fail "a submitted interactive message did not cancel the countdown: $out"
  log_of "$home" | grep -q 'cancelled.*remaining=' || fail "interactive cancellation not recorded: $(log_of "$home")"
  pass "a submitted interactive message cancels it too, as a backup for the raw listener"
}

# --- 4. expiry observes and nothing more ------------------------------------
test_expiry_enters_nothing() {
  local home out
  home=$(fixture expiry observe)
  out=$(drive "$home" 0.2 0.1 "wait:700") || fail "expiry driver failed"
  printf '%s\n' "$out" | grep -q 'notify Auto-AFK would enter now (observe mode; no away posture entered)' \
    || fail "expiry did not report the observation: $out"
  log_of "$home" | grep -q 'observe	would-enter' || fail "expiry not recorded: $(log_of "$home")"
  # The consent boundary, asserted rather than trusted.
  for leftover in .afk-contract .afk .afk-contract.lock; do
    [ -e "$home/state/$leftover" ] && fail "expiry created away-posture state: $leftover"
  done
  [ -d "$home/afk-contracts" ] && fail "expiry archived an away-posture record"
  pass "expiry reports the observation and enters no away posture"
}

# --- 5. scope gates ----------------------------------------------------------
test_scope_gates() {
  local home out
  home=$(fixture scope-rpc observe)
  out=$(drive "$home" 0.1 0.1 "wait:400" MODE=rpc) || fail "rpc driver failed"
  [ "$out" = "subscriptions=0" ] || fail "rpc mode armed the observer: $out"
  pass "non-TUI modes stay inert"

  home=$(fixture scope-lock observe)
  printf '%s\n' 999999 >"$home/state/.lock"
  out=$(drive "$home" 0.1 0.1 "wait:400") || fail "foreign-lock driver failed"
  [ "$out" = "subscriptions=0" ] || fail "a session that does not hold the home lock armed the observer: $out"
  pass "a worker that does not hold the home lock stays inert"

  home=$(fixture scope-secondmate observe)
  : >"$home/.fm-secondmate-home"
  out=$(drive "$home" 0.1 0.1 "wait:400") || fail "secondmate driver failed"
  [ "$out" = "subscriptions=0" ] || fail "a secondmate home armed the observer: $out"
  pass "a secondmate home, which is idle by design, stays inert"

  for existing in .afk-contract .afk .afk-return-catchup; do
    home=$(fixture "scope-$existing" observe)
    : >"$home/state/$existing"
    out=$(drive "$home" 0.1 0.1 "wait:400") || fail "$existing driver failed"
    [ "$out" = "subscriptions=0" ] || fail "state/$existing present but the observer armed: $out"
  done
  pass "an existing away posture, legacy flag, or unfinished return suppresses the observer"
}

# --- 6. lifecycle ------------------------------------------------------------
test_lifecycle() {
  local home out
  home=$(fixture lifecycle observe)
  out=$(drive "$home" 0.2 5 "wait:600,shutdown,wait:900") || fail "lifecycle driver failed"
  printf '%s\n' "$out" | grep -q '^unsubscribe$' || fail "shutdown did not unsubscribe: $out"
  log_of "$home" | grep -q 'would-enter' && fail "a timer survived session shutdown and reached expiry"
  pass "session shutdown drops the listener and every pending timer"
}

test_off_is_inert
test_countdown
test_input_cancels
test_expiry_enters_nothing
test_scope_gates
test_lifecycle
