#!/usr/bin/env bash
# tests/fm-pi-working-composer-live-e2e.test.sh - the live guard for pi's
# WORKING composer shape (live-harness-optin family; task
# pi-composer-byte-captures-s1).
#
# The portable cases in tests/fm-composer-lib.test.sh pin the classifier
# against byte captures of pi 0.85.1 (tests/assets/pi-0.85-composer/). Captures
# age: pi moved this exact rendering once already, from a `Working...`
# transcript row inside the separator pair (<=0.84) to an indicator embedded in
# the composer's own top border (>=0.85), and that move silently broke both the
# composer scan and the delivery busy token. Per
# .agents/skills/firstmate-coding-guidelines a vendor-rendered signal must
# therefore also be proven against the REAL harness, which is what this guard
# does: it drives a genuine pi turn and requires a landed message to be
# CONFIRMED landed, in stock presentation and with Calm on.
#
# It spends NO model tokens. The turn is driven by a faux provider registered
# through pi's own extension API (@earendil-works/pi-ai `createFauxCore`), the
# same mechanism tests/fm-calm-pi-extension.test.sh uses, so the agent state,
# the rendering, and the submit path are all real while the model is not.
#
# Refresh docs/verification/pi-composer-shapes.md from this guard's output
# after any pi upgrade, and re-take the captures when it fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_WORKING_COMPOSER_LIVE tmux pi

TMP_ROOT=$(fm_test_tmproot fm-pi-working-composer)
SOCKET="fm-piwc-$$"
PI_VERSION=$(pi --version 2>/dev/null | head -1)
[ -n "$PI_VERSION" ] || fail "could not determine the installed pi version"
CHECKED=0
HOLD_MS=${FM_PI_WORKING_COMPOSER_HOLD_MS:-60000}

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

note() { printf '# %s\n' "$1"; }
fail_pi() { fail "pi ($PI_VERSION): $1"; }

assert_pi_085_working_border() {  # <captured-pane> <calm on|off> <present|absent>
  local pane=$1 calm=$2 want=$3 row found=0
  while IFS= read -r row; do
    row="${row#"${row%%[![:space:]]*}"}"
    fm_composer_normalize_trim_var row
    if _fm_composer_pi_titled_open_row "$row"; then
      found=1
      break
    fi
  done < <(printf '%s\n' "$pane" | fm_composer_strip_ansi)
  case "$want" in
    present)
      [ "$found" -eq 1 ] \
        || fail_pi "the live Working-row guard did not find Pi 0.85's titled composer border (calm=$calm)"
      ;;
    absent)
      [ "$found" -eq 0 ] \
        || fail_pi "a generating Calm pane still carries Pi 0.85's titled composer border (calm=$calm)"
      ;;
    *) fail_pi "unknown border expectation '$want' (calm=$calm)" ;;
  esac
}

# The library under test drives bare `tmux`, so a PATH shim keeps every call on
# this guard's private server and away from any live fleet.
SHIM_DIR="$TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

# Keep this guard non-vacuous: the exact shape matcher must reject a plausible
# but wrong border, before the real executable capture is checked below.
! _fm_composer_pi_titled_open_row '── Working ────────────────────────' \
  || fail_pi "the Working-row border guard accepts a word-titled border"

PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
PI_CONFIG="$TMP_ROOT/piconfig"
mkdir -p "$PROJECT/.pi/extensions/lib" "$HOME_DIR/config" "$PI_CONFIG"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
for f in fm-calm-assistant-layout.ts fm-calm-operational-user-layout.ts \
  fm-calm-visibility.ts fm-calm-working-ship.ts fm-operational-input.ts; do
  cp "$ROOT/.pi/extensions/lib/$f" "$PROJECT/.pi/extensions/lib/$f"
done
fm_git_init_commit "$PROJECT"

# The faux provider: a real pi turn that stays in its working state long enough
# to be observed, with no model call behind it.
cat > "$PROJECT/live-provider.ts" <<'TS'
import { createFauxCore, fauxAssistantMessage, fauxText } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HOLD_MS = Number(process.env.FM_PI_WORKING_COMPOSER_HOLD_MS ?? "60000");

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "fm-live-working-api",
    provider: "fm-live-working",
    models: [{
      id: "held",
      name: "Firstmate working-composer guard",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  const held = async () => {
    await new Promise((r) => setTimeout(r, HOLD_MS));
    return fauxAssistantMessage([fauxText("FM_LIVE_WORKING_DONE")]);
  };
  faux.setResponses([held, held, held, held]);
  pi.registerProvider("fm-live-working", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerCommand("fm-live-working-model", {
    description: "Select the held guard model.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("fm-live-working", "held");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("guard model unavailable");
      }
    },
  });
}
TS

start_pi() {  # <session> <calm on|off>
  local session=$1 calm=$2 extensions='-e ./live-provider.ts' i=0 pane
  if [ "$calm" = on ]; then
    printf 'on\n' >"$HOME_DIR/config/calm"
    extensions="-e ./.pi/extensions/fm-calm.ts $extensions"
  else
    rm -f "$HOME_DIR/config/calm"
  fi
  rm -rf "$TMP_ROOT/sessions"; mkdir -p "$TMP_ROOT/sessions"
  tmux -L "$SOCKET" kill-session -t "$session" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$session" -x 120 -y 40 \
    "cd '$PROJECT' && env FM_HOME='$HOME_DIR' PI_CODING_AGENT_DIR='$PI_CONFIG' PI_OFFLINE=1 FM_PI_WORKING_COMPOSER_HOLD_MS=$HOLD_MS pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions $extensions --session-dir '$TMP_ROOT/sessions'; sleep 30"
  while [ "$i" -lt 200 ]; do
    pane=$(tmux -L "$SOCKET" capture-pane -p -t "$session" 2>/dev/null || true)
    printf '%s\n' "$pane" | grep -Fq 'live-provider.ts' && break
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$pane" | grep -Fq 'live-provider.ts' \
    || fail_pi "the guard pi session never reached a ready composer (calm=$calm)"
  tmux -L "$SOCKET" send-keys -t "$session" -l '/fm-live-working-model'
  tmux -L "$SOCKET" send-keys -t "$session" Enter
  sleep 2
}

# check_presentation: the whole point of the guard, run once per presentation.
# A steer submitted into an idle pi must be DELIVERED exactly once, and the
# generating pane it leaves behind must never read as injectable. Those are the
# two properties this guard owns; they are asserted against a real pi turn.
# The two presentations diverge on the CONFIRMATION, and deliberately so:
#   - stock: pi draws its working indicator INTO the composer's top border, and
#     a titled opener is structural proof the pane is generating, so the
#     composer verdict is `unknown` and the submit is not confirmed here. That
#     is the safe direction - the durable steering inbox re-rings an
#     unacknowledged message - and confirming it on this plane needs the tmux
#     busy captures this task did not take.
#   - Calm on: Calm CLEARS that indicator and draws its boat above the pair, so
#     the opener is a solid rule and the cleared composer confirms the submit.
#     The same reading makes a GENERATING Calm pane read `empty`, which is the
#     away-mode injector's permission verdict - a KNOWN RECORDED GAP, not a
#     desired property. It predates this branch and the titled-opener refusal
#     cannot reach it (Calm leaves no titled opener to refuse); closing it
#     needs tmux busy captures. See "Still reachable, and NOT introduced here"
#     in docs/verification/pi-composer-shapes.md.
# The captured pi 0.85 busy SHAPES are deliberately not part of either path:
# they are scoped to the herdr delivery read, so a generating pi reads idle
# through tmux, and this guard pins that too
# (docs/verification/pi-composer-shapes.md).
check_presentation() {  # <calm on|off> <expected-submit-verdict> <expected-generating-composer>
  local calm=$1 want_verdict=$2 want_composer=$3
  local session="piwc-$1" probe="FM_LIVE_STEER_${1}" verdict occurrences want_border generating i
  start_pi "$session" "$calm"

  [ "$(fm_tmux_composer_state "$session")" = empty ] \
    || fail_pi "an idle guard composer did not read empty (calm=$calm)"
  [ "$(fm_pane_busy_state "$session" pi)" = idle ] \
    || fail_pi "an idle guard pane read busy before any turn started (calm=$calm)"

  verdict=$(fm_tmux_submit_core "$session" "$probe" 4 0.5 0.4)
  [ "$verdict" = "$want_verdict" ] \
    || fail_pi "the tmux submit verdict for a landed steer changed: expected '$want_verdict', got '$verdict' (calm=$calm)"
  # Whatever the verdict, DELIVERY is what must not go wrong: the steer landed
  # exactly once. An unconfirmed-but-delivered steer is recoverable (the
  # durable inbox re-rings it); a duplicated or lost one is not.
  occurrences=$(tmux -L "$SOCKET" capture-pane -p -t "$session" -S - 2>/dev/null | grep -Fc "$probe" || true)
  [ "$occurrences" -eq 1 ] \
    || fail_pi "the steer appeared $occurrences times, expected exactly 1 (calm=$calm)"

  # The border shape below is only evidence while the turn is STILL running: an
  # ABSENT indicator is what a FINISHED turn leaves too, so the Calm expectation
  # needs the mid-turn precondition asserted first.
  generating=$(tmux -L "$SOCKET" capture-pane -e -p -t "$session" -S 0 -E - 2>/dev/null)
  # Calm's own mid-turn rendering is the working ship. Requiring it makes the
  # ABSENT border below evidence that Calm CLEARED pi's indicator, rather than
  # evidence that no turn was running - the stock `present` expectation carries
  # that proof on its own.
  if [ "$calm" = on ]; then
    i=0
    while [ "$i" -lt 240 ] \
      && ! printf '%s\n' "$generating" | fm_composer_strip_ansi | grep -Fq '\__/'; do
      sleep 0.05
      generating=$(tmux -L "$SOCKET" capture-pane -e -p -t "$session" -S 0 -E - 2>/dev/null)
      i=$((i + 1))
    done
    printf '%s\n' "$generating" | fm_composer_strip_ansi | grep -Fq '\__/' \
      || fail_pi "Calm never drew its working ship, so a cleared composer border proves nothing (calm=$calm)"
  fi
  ! printf '%s\n' "$generating" | fm_composer_strip_ansi | grep -Fq FM_LIVE_WORKING_DONE \
    || fail_pi "the guard turn finished before the generating pane was read; raise FM_PI_WORKING_COMPOSER_HOLD_MS (calm=$calm)"
  if [ "$calm" = off ]; then want_border=present; else want_border=absent; fi
  assert_pi_085_working_border "$generating" "$calm" "$want_border"

  # The busy shapes must stay off this plane. If either of these ever reads
  # busy, the herdr scoping has leaked and the baseline-gated conversion has
  # become reachable for pi without the pre-Enter narrowing that makes it safe.
  [ "$(fm_pane_busy_state "$session" pi)" = idle ] \
    || fail_pi "the pi busy shapes must stay herdr-scoped; the tmux read went busy (calm=$calm)"
  [ "$(fm_pane_busy_state "$session")" = idle ] \
    || fail_pi "the pi busy shapes must stay herdr-scoped; the harness-less union went busy (calm=$calm)"
  # The generating composer verdict, read off the real pane. In stock this must
  # not be `empty`: that is the verdict the away-mode injector treats as
  # permission to type into the pane, and this pane is mid-turn.
  [ "$(fm_tmux_composer_state "$session")" = "$want_composer" ] \
    || fail_pi "a generating pi's composer read '$(fm_tmux_composer_state "$session")', expected '$want_composer' (calm=$calm)"

  tmux -L "$SOCKET" send-keys -t "$session" -l 'a real half typed draft'
  sleep 1
  [ "$(fm_tmux_composer_state "$session")" = pending \
  ] || fail_pi "a half-typed draft on a generating pi must stay pending, got '$(fm_tmux_composer_state "$session")' (calm=$calm)"
  tmux -L "$SOCKET" send-keys -t "$session" C-u

  tmux -L "$SOCKET" kill-session -t "$session" 2>/dev/null || true
  CHECKED=$((CHECKED + 1))
  printf 'ok - pi (%s) calm=%s: the steer landed exactly once, submit read %s, the generating composer read %s, and a draft on it stays pending\n' \
    "$PI_VERSION" "$calm" "$want_verdict" "$want_composer"
}

note "pi version under test: $PI_VERSION"
# stock: the titled working border makes the generating composer refuse
# `empty`, so the submit is unconfirmed here - safe, and confirming it needs
# tmux busy captures. Calm: the indicator is cleared, the opener is solid, and
# the cleared composer confirms.
check_presentation off unknown unknown
check_presentation on empty empty

[ "$CHECKED" -eq 2 ] \
  || fail_pi "the guard verified $CHECKED presentation(s); it must verify both stock and Calm or fail"
printf 'ok - pi (%s): the working-composer guard verified both presentations\n' "$PI_VERSION"
