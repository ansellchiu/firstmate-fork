#!/usr/bin/env bash
# Tests for the Pi primary session's growth policy
# (.pi/extensions/lib/fm-primary-growth.ts) and the circuit breakers built on
# it (.pi/extensions/fm-primary-growth.ts): the calibrated trigger checks,
# threshold overrides, quota-pressure reduction, the once-per-conversation
# warning contract, and the two safety properties the extension owns - a
# rotation never splits a bounded action, and a rotation never happens in a
# session that is not the primary.
#
# The policy module is pure and imports nothing, and the extension imports the
# Pi SDK for types only, so both run directly under node with no Pi SDK and a
# scripted stand-in for the extension API. The thresholds asserted here are the
# measured ones; docs/verification/pi-primary-growth-baseline.md owns the
# measurement they came from, and bin/fm-pi-session-metrics.sh reproduces it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-growth)
LIB="$ROOT/.pi/extensions/lib/fm-primary-growth.ts"
EXT="$ROOT/.pi/extensions/fm-primary-growth.ts"
export NODE_NO_WARNINGS=1

test_thresholds_match_the_measured_baseline() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/defaults" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { GROWTH_DEFAULTS } = await import(pathToFileURL(process.env.LIB).href);

// These three numbers are the whole calibration. They are asserted literally
// so a change to any of them has to come with a re-measured baseline rather
// than sliding in as a tweak.
const expected = { enabled: true, cacheReadPerAssistantMessage: 200000, compactions: 2, events: 5000 };
for (const [key, value] of Object.entries(expected)) {
  if (GROWTH_DEFAULTS[key] !== value) {
    throw new Error(`${key} is ${GROWTH_DEFAULTS[key]}, expected the measured ${value}`);
  }
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/defaults")
  expect_code 0 "$status" "defaults must match the measured baseline: $out"
  pass "default thresholds are the measured ones: 200k cache-read per message, 2 compactions, 5000 events"
}

test_triggers_fire_in_a_fixed_order_and_only_when_crossed() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/triggers" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const {
  GROWTH_DEFAULTS,
  UNKNOWN_QUOTA,
  growthDecision,
  newGrowthState,
  recordAssistantMessage,
  recordCompaction,
  recordEvent,
  recordNotified,
  recordTurn,
} = await import(pathToFileURL(process.env.LIB).href);

const fresh = newGrowthState(1_000_000);
const quiet = growthDecision(fresh, GROWTH_DEFAULTS, UNKNOWN_QUOTA);
if (quiet.level !== "ok") throw new Error("a brand-new conversation must be ok");

// A busy conversation is not by itself a runaway one: turns and assistant
// messages are counted, but neither is a trigger on its own.
let busy = fresh;
for (let i = 0; i < 500; i += 1) busy = recordAssistantMessage(recordTurn(busy), { cacheRead: 1000 });
if (growthDecision(busy, GROWTH_DEFAULTS, UNKNOWN_QUOTA).level !== "ok") {
  throw new Error("turn count alone must never trip a breaker");
}

// The measurement's central finding: the FIRST compaction is ordinary, and it
// is the second that marks the runaway class.
const once = growthDecision(recordCompaction(fresh), GROWTH_DEFAULTS, UNKNOWN_QUOTA);
if (once.level !== "ok") throw new Error(`one compaction must not rotate: ${JSON.stringify(once)}`);
const twice = growthDecision(recordCompaction(recordCompaction(fresh)), GROWTH_DEFAULTS, UNKNOWN_QUOTA);
if (twice.level !== "hard" || twice.reason !== "compaction") {
  throw new Error(`the second compaction must rotate: ${JSON.stringify(twice)}`);
}

let grown = fresh;
for (let i = 0; i < GROWTH_DEFAULTS.events - 1; i += 1) grown = recordEvent(grown, "other");
if (growthDecision(grown, GROWTH_DEFAULTS, UNKNOWN_QUOTA).level === "hard") {
  throw new Error("one event below the boundary must not rotate");
}
const runaway = growthDecision(recordEvent(grown, "other"), GROWTH_DEFAULTS, UNKNOWN_QUOTA);
if (runaway.level !== "hard" || runaway.reason !== "event_growth") {
  throw new Error(`the event boundary must rotate: ${JSON.stringify(runaway)}`);
}

// Cache re-reads warn, they never rotate: a session can be expensive without
// being unrecoverable, and warning is the whole point of the soft level.
let hot = fresh;
for (let i = 0; i < 10; i += 1) hot = recordAssistantMessage(hot, { cacheRead: 250_000 });
const warned = growthDecision(hot, GROWTH_DEFAULTS, UNKNOWN_QUOTA);
if (warned.level !== "soft" || warned.reason !== "cache_reread") {
  throw new Error(`abnormal cache re-reads must warn: ${JSON.stringify(warned)}`);
}
let cool = fresh;
for (let i = 0; i < 10; i += 1) cool = recordAssistantMessage(cool, { cacheRead: 78_777 });
if (growthDecision(cool, GROWTH_DEFAULTS, UNKNOWN_QUOTA).level !== "ok") {
  throw new Error("a session at the measured median must not warn");
}

// Hard outranks soft, so an already-runaway session is asked to rotate rather
// than merely warned about its cache.
const both = recordCompaction(recordCompaction(hot));
const ranked = growthDecision(both, GROWTH_DEFAULTS, UNKNOWN_QUOTA);
if (ranked.level !== "hard" || ranked.reason !== "compaction") {
  throw new Error(`hard must outrank soft deterministically: ${JSON.stringify(ranked)}`);
}

// One warning per reason per conversation, not one per turn.
if (growthDecision(recordNotified(hot, "cache_reread"), GROWTH_DEFAULTS, UNKNOWN_QUOTA).level !== "ok") {
  throw new Error("a delivered warning must not repeat");
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/triggers")
  expect_code 0 "$status" "growth triggers must be deterministic: $out"
  pass "compaction, event growth, and cache re-reads fire at the measured boundaries in a fixed order"
}

test_quota_pressure_is_read_not_invented() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/quota" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { GROWTH_DEFAULTS, UNKNOWN_QUOTA, growthDecision, newGrowthState, quotaPressure } =
  await import(pathToFileURL(process.env.LIB).href);

const report = {
  providers: [
    {
      provider: "codex",
      quotaSemantics: {
        effectiveAvailability: [
          {
            scope: "all_models",
            effectivePercentRemaining: 40,
            limitingWindowIds: ["five_hour"],
            runway: { status: "projected_exhaustion", usableRunwaySeconds: 6994 },
          },
        ],
      },
    },
    {
      provider: "claude",
      quotaSemantics: {
        effectiveAvailability: [
          { scope: "all_models", effectivePercentRemaining: 69, runway: { status: "through_reset" } },
        ],
      },
    },
  ],
};

const tight = quotaPressure(report, "codex");
if (tight.status !== "projected_exhaustion" || tight.usableRunwaySeconds !== 6994) {
  throw new Error(`projected exhaustion must be carried through: ${JSON.stringify(tight)}`);
}
const roomy = quotaPressure(report, "claude");
if (roomy.status !== "through_reset") throw new Error("a comfortable provider must not read as pressure");

// Anything unreadable is unknown, never pressure: warning on a parse failure
// would train the reader to ignore the warning.
for (const bad of [null, undefined, "", {}, { providers: "no" }, { providers: [] }]) {
  if (quotaPressure(bad, "codex").status !== "unknown") {
    throw new Error(`unreadable quota must be unknown: ${JSON.stringify(bad)}`);
  }
}
if (quotaPressure(report, "grok").status !== "unknown") {
  throw new Error("a provider absent from the report must be unknown");
}

const fresh = newGrowthState(0);
if (growthDecision(fresh, GROWTH_DEFAULTS, roomy).level !== "ok") {
  throw new Error("through_reset must not warn");
}
if (growthDecision(fresh, GROWTH_DEFAULTS, UNKNOWN_QUOTA).level !== "ok") {
  throw new Error("unknown quota must not warn");
}
const warned = growthDecision(fresh, GROWTH_DEFAULTS, tight);
if (warned.level !== "soft" || warned.reason !== "quota_runway") {
  throw new Error(`projected exhaustion must warn: ${JSON.stringify(warned)}`);
}

// The Harm-or-Duty and protected-material boundaries, enforced structurally:
// the advice exists, and it cannot name a destination for anything.
const advice = warned.modelChangeAdvice;
if (!advice) throw new Error("a quota warning must carry model-change advice");
if (advice.target !== null) throw new Error("the policy must never name a target provider or model");
if (advice.advisory !== true || advice.requiresEligibilityReview !== true) {
  throw new Error(`advice must stay advisory and reviewed: ${JSON.stringify(advice)}`);
}
if (advice.owner !== "quota-array-dispatch") {
  throw new Error("the destination decision must point at its existing owner");
}
if (JSON.stringify(warned).includes("setModel")) throw new Error("the policy must not carry a model action");
EOF
  status=$?
  out=$(cat "$TMP_ROOT/quota")
  expect_code 0 "$status" "quota pressure must be read from quota-axi, never invented: $out"
  pass "quota pressure is read from quota-axi, unknown when unreadable, and advises without naming a destination"
}

test_the_quota_provider_binding_comes_from_quota_axi_itself() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/binding" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { quotaProviderForPiProvider } = await import(pathToFileURL(process.env.LIB).href);

// The shape quota-axi's own `auth --json` reports. A `pi:<provider>` source is
// quota-axi stating outright which Pi login it is metering, which is why the
// binding is read from here rather than from a table of guessed name pairs.
const auth = {
  auth: [
    { provider: "claude", sources: [{ source: "oauth-file" }, { source: "keychain" }] },
    { provider: "codex", sources: [{ source: "auth-json" }, { source: "cli-rpc" }] },
    { provider: "grok", sources: [{ source: "auth-json" }, { source: "pi:xai" }] },
    { provider: "kimi", sources: [{ source: "pi:kimi-coding" }] },
    { provider: "zai", sources: [{ source: "opencode:auth.json" }, { source: "pi:zai" }] },
    { provider: "deepseek", sources: [{ source: "env:DEEPSEEK_API_KEY" }, { source: "pi:deepseek" }] },
  ],
};

// Published bindings resolve, across the identifier gap between the two tools.
for (const [pi, quota] of [["xai", "grok"], ["zai", "zai"], ["deepseek", "deepseek"], ["kimi-coding", "kimi"]]) {
  const got = quotaProviderForPiProvider(auth, pi);
  if (got !== quota) throw new Error(`${pi} must bind to ${quota}, got ${got}`);
}

// A Pi provider quota-axi does not claim to meter resolves to nothing, even
// when a similarly-named quota-axi provider exists. Reading `codex` numbers
// for Pi's `openai-codex` login would be inventing evidence: nothing local
// proves the two logins are the same account.
for (const pi of ["openai-codex", "anthropic", "ollama", "unknown-provider"]) {
  const got = quotaProviderForPiProvider(auth, pi);
  if (got !== null) throw new Error(`${pi} must not bind by name similarity, got ${got}`);
}

// Anything unreadable resolves to nothing rather than to a guess.
for (const bad of [null, undefined, "", {}, { auth: "no" }, { auth: [] }, { auth: [{ provider: 1 }] }]) {
  if (quotaProviderForPiProvider(bad, "xai") !== null) {
    throw new Error(`an unreadable auth report must not bind: ${JSON.stringify(bad)}`);
  }
}
if (quotaProviderForPiProvider(auth, null) !== null) throw new Error("an unknown Pi provider must not bind");
EOF
  status=$?
  out=$(cat "$TMP_ROOT/binding")
  expect_code 0 "$status" "the provider binding must come from quota-axi's own report: $out"
  pass "the Pi-to-quota provider binding is read from quota-axi's published credential sources, never guessed by name"
}

test_thresholds_are_env_overridable_and_survive_bad_input() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/env" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { GROWTH_DEFAULTS, readGrowthThresholds } = await import(pathToFileURL(process.env.LIB).href);

const empty = readGrowthThresholds({});
if (JSON.stringify(empty) !== JSON.stringify(GROWTH_DEFAULTS)) throw new Error("an empty environment must be the defaults");

const tuned = readGrowthThresholds({
  FM_PI_GROWTH_COMPACTIONS: "3",
  FM_PI_GROWTH_EVENTS: "12000",
  FM_PI_GROWTH_CACHE_READ_PER_MESSAGE: "500000",
});
if (tuned.compactions !== 3 || tuned.events !== 12000 || tuned.cacheReadPerAssistantMessage !== 500000) {
  throw new Error(`overrides must apply: ${JSON.stringify(tuned)}`);
}

// 0 disables one axis without disabling the others.
const partial = readGrowthThresholds({ FM_PI_GROWTH_COMPACTIONS: "0" });
if (partial.compactions !== 0 || partial.events !== GROWTH_DEFAULTS.events) {
  throw new Error(`0 must disable exactly one axis: ${JSON.stringify(partial)}`);
}

// Malformed input never silently disables the policy.
for (const bad of ["", "  ", "-1", "abc", "2.5", "1e3"]) {
  const fallback = readGrowthThresholds({ FM_PI_GROWTH_COMPACTIONS: bad });
  if (fallback.compactions !== GROWTH_DEFAULTS.compactions) {
    throw new Error(`malformed input must fall back, got ${fallback.compactions} for ${JSON.stringify(bad)}`);
  }
}
if (readGrowthThresholds({ FM_PI_GROWTH: "nonsense" }).enabled !== true) {
  throw new Error("a malformed kill switch must not disable the policy");
}
if (readGrowthThresholds({ FM_PI_GROWTH: "0" }).enabled !== false) throw new Error("the kill switch must work");
EOF
  status=$?
  out=$(cat "$TMP_ROOT/env")
  expect_code 0 "$status" "thresholds must be overridable and fail safe: $out"
  pass "thresholds are environment-overridable and malformed input never disables the policy"
}

# The extension imports the Pi SDK for types only, so it activates against a
# scripted stand-in with no SDK present. This is what lets the two safety
# properties be asserted as behavior instead of as prose.
write_extension_driver() {
  cat > "$TMP_ROOT/driver.mjs" <<'EOF'
import { pathToFileURL } from "node:url";

export async function drive(script) {
  const handlers = new Map();
  const sent = [];
  const commands = new Map();
  const pi = {
    on(event, handler) {
      if (!handlers.has(event)) handlers.set(event, []);
      handlers.get(event).push(handler);
    },
    registerCommand(name, options) {
      commands.set(name, options);
    },
    sendUserMessage(content, options) {
      sent.push({ content, options });
    },
  };
  const activate = (await import(pathToFileURL(process.env.EXT).href)).default;
  activate(pi);
  const emit = async (event, payload, ctx) => {
    for (const handler of handlers.get(event) ?? []) await handler(payload ?? { type: event }, ctx);
  };
  return script({ emit, sent, commands, handlers });
}
EOF
}

test_rotation_only_happens_at_a_settled_quiet_boundary() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/home/state"
  printf '%s\n' "$$" > "$TMP_ROOT/home/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/home/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/boundary" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);

const busyContext = { isIdle: () => false, hasPendingMessages: () => false, ui: { notify() {} } };
const queuedContext = { isIdle: () => true, hasPendingMessages: () => true, ui: { notify() {} } };
const quietContext = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };

await drive(async ({ emit, sent, commands }) => {
  if (!commands.has("fm-primary-rotate")) throw new Error("the rotation command must be registered");

  await emit("session_start");
  // Two compactions: the hard boundary.
  await emit("session_compact");
  await emit("session_compact");

  // A settle that is not actually quiet must change nothing at all. This is
  // the never-split-a-bounded-action property: the only place a rotation can
  // originate refuses to act while the context reports work in flight.
  await emit("agent_settled", undefined, busyContext);
  if (sent.length !== 0) throw new Error(`a mid-action settle must send nothing: ${JSON.stringify(sent)}`);
  await emit("agent_settled", undefined, queuedContext);
  if (sent.length !== 0) throw new Error(`a settle with queued work must send nothing: ${JSON.stringify(sent)}`);

  // Phase one at the first genuinely quiet boundary: capture, never rotate.
  await emit("agent_settled", undefined, quietContext);
  if (sent.length !== 1) throw new Error(`expected one capture request: ${JSON.stringify(sent)}`);
  if (!sent[0].content.includes("/stow")) throw new Error("the capture request must ask for durable knowledge capture");
  if (sent[0].content.includes("/fm-primary-rotate")) throw new Error("phase one must not rotate");
  if (sent[0].options?.deliverAs !== "followUp") throw new Error("the request must be delivered as a follow-up");

  // Phase two, only after the capture turn itself has settled.
  await emit("agent_settled", undefined, quietContext);
  if (sent.length !== 2) throw new Error(`expected the rotation dispatch: ${JSON.stringify(sent)}`);
  if (sent[1].content !== "/fm-primary-rotate") throw new Error(`phase two must dispatch the command: ${sent[1].content}`);
  if (sent[1].options?.expandPromptTemplates !== true) throw new Error("the command must be dispatched, not typed as prose");

  // Already dispatched: further settles add nothing.
  await emit("agent_settled", undefined, quietContext);
  if (sent.length !== 2) throw new Error(`a dispatched rotation must not repeat: ${JSON.stringify(sent)}`);

  // The replacement conversation starts clean, which is what makes a rotation
  // loop impossible rather than merely unlikely.
  await emit("session_start");
  await emit("agent_settled", undefined, quietContext);
  if (sent.length !== 2) throw new Error(`a fresh conversation must not rotate: ${JSON.stringify(sent)}`);
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/boundary")
  expect_code 0 "$status" "rotation must wait for a quiet settled boundary: $out"
  pass "rotation captures first, dispatches only at a quiet settled boundary, and cannot loop"
}

test_a_session_without_the_helm_never_acts() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/other/state"
  # A live pid that is neither this process nor an ancestor of it: the shape a
  # crewmate sees when it loads these extensions from a firstmate worktree.
  printf '1\n' > "$TMP_ROOT/other/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/other/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/notprimary" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };

await drive(async ({ emit, sent }) => {
  await emit("session_start");
  await emit("session_compact");
  await emit("session_compact");
  for (let i = 0; i < 5; i += 1) await emit("agent_settled", undefined, quiet);
  if (sent.length !== 0) {
    throw new Error(`a session that does not hold the helm must stay inert: ${JSON.stringify(sent)}`);
  }
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/notprimary")
  expect_code 0 "$status" "a non-primary session must stay inert: $out"
  pass "a session that does not hold the home's helm never warns and never rotates"
}

test_the_kill_switch_stops_every_breaker() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/off/state"
  printf '%s\n' "$$" > "$TMP_ROOT/off/state/.lock"
  EXT="$EXT" \
  FM_PI_GROWTH=0 \
  FM_STATE_OVERRIDE="$TMP_ROOT/off/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/off-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };
await drive(async ({ emit, sent }) => {
  await emit("session_start");
  await emit("session_compact");
  await emit("session_compact");
  for (let i = 0; i < 5; i += 1) await emit("agent_settled", undefined, quiet);
  if (sent.length !== 0) throw new Error(`the kill switch must stop every breaker: ${JSON.stringify(sent)}`);
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/off-output")
  expect_code 0 "$status" "the kill switch must stop every breaker: $out"
  pass "FM_PI_GROWTH=0 stops both the warnings and the rotation"
}

test_soft_warnings_are_delivered_once_and_carry_the_operational_marker() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/soft/state"
  printf '%s\n' "$$" > "$TMP_ROOT/soft/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/soft/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/soft-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };

await drive(async ({ emit, sent }) => {
  await emit("session_start");
  for (let i = 0; i < 10; i += 1) {
    await emit("message_end", { message: { role: "assistant", provider: "codex", usage: { cacheRead: 250_000 } } });
  }
  await emit("agent_settled", undefined, quiet);
  if (sent.length !== 1) throw new Error(`expected one warning: ${JSON.stringify(sent)}`);
  if (!sent[0].content.includes("GROWTH WARNING")) throw new Error(`unexpected warning body: ${sent[0].content}`);
  if (!sent[0].content.includes("FIRSTMATE_OP:")) throw new Error("a warning must carry the operational marker");

  // A warning is one notice, not a per-turn nag.
  for (let i = 0; i < 5; i += 1) await emit("agent_settled", undefined, quiet);
  if (sent.length !== 1) throw new Error(`the warning must not repeat: ${JSON.stringify(sent)}`);
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/soft-output")
  expect_code 0 "$status" "soft warnings must be delivered once: $out"
  pass "a growth warning is delivered once per conversation and carries the operational marker"
}

# A dispatch that nothing ever acts on must end at the documented stand-down
# rather than leaving the breaker permanently and silently disabled. This is
# the regression: before the fix, `rotation-dispatched` returned on every later
# settle, so the attempt budget stopped moving and no loud line was ever
# written.
test_a_dispatch_nothing_acts_on_stands_down_once_and_loudly() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/stuck/state"
  printf '%s\n' "$$" > "$TMP_ROOT/stuck/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/stuck/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/stuck-output" 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };
const recordPath = `${process.env.FM_STATE_OVERRIDE}/.pi-primary-growth`;

// The loud line is written to stderr, so it is collected rather than printed
// while the assertions run, then restored before anything is reported.
const lines = [];
const realWrite = process.stderr.write.bind(process.stderr);
let failure = null;
try {
  process.stderr.write = (chunk) => {
    lines.push(String(chunk));
    return true;
  };
  await drive(async ({ emit, sent }) => {
    await emit("session_start");
    await emit("session_compact");
    await emit("session_compact");
    // No session_start ever follows the dispatch and no handler runs: the
    // request was sent and nothing acted on it.
    for (let i = 0; i < 8; i += 1) await emit("agent_settled", undefined, quiet);
    if (sent.length !== 2) failure = `a stalled dispatch must not re-dispatch: ${JSON.stringify(sent)}`;

    // Standing down ends the ladder, not the observation: the record still
    // tracks what the conversation went on to do.
    const atStandDown = JSON.parse(readFileSync(recordPath, "utf8"));
    await emit("session_compact");
    await emit("agent_settled", undefined, quiet);
    const afterStandDown = JSON.parse(readFileSync(recordPath, "utf8"));
    if (!failure && afterStandDown.compactions <= atStandDown.compactions) {
      failure = `a stood-down conversation must keep its record current: ${JSON.stringify(afterStandDown)}`;
    }
  });
} finally {
  process.stderr.write = realWrite;
}
if (failure) throw new Error(failure);
const stoodDown = lines.filter((line) => line.includes("stood down"));
if (stoodDown.length !== 1) {
  throw new Error(`a stalled dispatch must stand down exactly once: ${JSON.stringify(lines)}`);
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/stuck-output")
  expect_code 0 "$status" "a stalled dispatch must reach the stand-down: $out"
  pass "a rotation dispatch nothing acts on spends its bounded budget and stands down with one loud line"
}

# The second half of the never-split-a-bounded-action guarantee lives in the
# command handler, so it is driven directly. The rotation record in the state
# directory is this extension's own serialized observation of what it did, and
# it is what makes the counters and the phase observable from outside.
test_the_rotation_command_refuses_waits_and_records() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/rotate/state"
  printf '%s\n' "$$" > "$TMP_ROOT/rotate/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/rotate/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/rotate-output" 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);

const recordPath = `${process.env.FM_STATE_OVERRIDE}/.pi-primary-growth`;
const readRecord = () => JSON.parse(readFileSync(recordPath, "utf8"));

await drive(async ({ emit, commands }) => {
  const rotate = commands.get("fm-primary-rotate");
  if (!rotate) throw new Error("the rotation command must be registered");
  await emit("session_start");

  const order = [];
  const ctx = (session) => ({
    waitForIdle: async () => {
      order.push("waitForIdle");
    },
    newSession: async () => {
      order.push("newSession");
      return session();
    },
    ui: { notify: (message) => order.push(`notify:${message}`) },
  });

  // The conversation is only replaced once the moment the boundary check chose
  // has actually arrived, so idle is awaited before the replacement is asked
  // for, never after.
  await rotate.handler([], ctx(() => ({ cancelled: true })));
  if (order[0] !== "waitForIdle" || order[1] !== "newSession") {
    throw new Error(`idle must be awaited before the replacement: ${JSON.stringify(order)}`);
  }
  const cancelled = readRecord();
  if (cancelled.rotations !== 0 || cancelled.phase !== "stood-down") {
    throw new Error(`a cancelled rotation must stand down and count nothing: ${JSON.stringify(cancelled)}`);
  }

  // A replacement that rejects must leave the request where the settled ladder
  // can still act on it, rather than leaving a rejected promise and a phase
  // nothing will ever move again. Invoked by an operator while the ladder is
  // idle, no capture was ever owed, so the phase stays idle and a later hard
  // decision still starts at phase one.
  await emit("session_start");
  await rotate.handler([], ctx(() => {
    throw new Error("session replacement failed");
  }));
  const failedFromIdle = readRecord();
  if (failedFromIdle.rotations !== 0 || failedFromIdle.phase !== "idle") {
    throw new Error(`a failed operator rotation must not arm a capture: ${JSON.stringify(failedFromIdle)}`);
  }

  // Dispatched by the ladder, the same failure must stay actionable so the
  // bounded budget still reaches its loud stand-down.
  await emit("session_start");
  await emit("session_compact");
  await emit("session_compact");
  await emit("agent_settled", undefined, { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } });
  await emit("agent_settled", undefined, { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } });
  await rotate.handler([], ctx(() => {
    throw new Error("session replacement failed");
  }));
  const failed = readRecord();
  if (failed.rotations !== 0 || failed.phase !== "capture-requested") {
    throw new Error(`a failed dispatched rotation must stay actionable: ${JSON.stringify(failed)}`);
  }

  await rotate.handler([], ctx(() => ({ cancelled: false })));
  const rotated = readRecord();
  if (rotated.rotations !== 1) {
    throw new Error(`a completed rotation must be counted: ${JSON.stringify(rotated)}`);
  }
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/rotate-output")
  expect_code 0 "$status" "the rotation command must wait, record, and stay actionable: $out"

  mkdir -p "$TMP_ROOT/rotate-other/state"
  printf '1\n' > "$TMP_ROOT/rotate-other/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/rotate-other/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/rotate-refused" 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);

await drive(async ({ commands }) => {
  const notices = [];
  let replaced = false;
  await commands.get("fm-primary-rotate").handler([], {
    waitForIdle: async () => {},
    newSession: async () => {
      replaced = true;
      return { cancelled: false };
    },
    ui: { notify: (message) => notices.push(message) },
  });
  if (replaced) throw new Error("a session without the helm must never replace a conversation");
  if (!notices.some((notice) => notice.includes("rotation refused"))) {
    throw new Error(`the refusal must be said out loud: ${JSON.stringify(notices)}`);
  }
  // The record lives in the shared home, so a session that has just proven it
  // does not hold the helm must not overwrite the primary's evidence with its
  // own empty counters.
  if (existsSync(`${process.env.FM_STATE_OVERRIDE}/.pi-primary-growth`)) {
    throw new Error("a session without the helm must not write the home's growth record");
  }
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/rotate-refused")
  expect_code 0 "$status" "the rotation command must re-check the helm: $out"
  pass "the rotation command re-checks the helm, waits for idle before replacing, counts rotations, and stays actionable when it fails"
}

# An operator can invoke the rotation command directly, before the ladder has
# asked for anything. When that invocation refuses or fails, the durable
# knowledge capture the hard action owes has still never been requested, so the
# next hard decision must start at phase one rather than dispatching a rotation
# the session was never told about.
test_a_failed_operator_rotation_still_leaves_the_capture_owed() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/manual/state"
  printf '%s\n' "$$" > "$TMP_ROOT/manual/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/manual/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/manual-output" 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);

const lockPath = `${process.env.FM_STATE_OVERRIDE}/.lock`;
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };
const rotateCtx = (session) => ({
  waitForIdle: async () => {},
  newSession: async () => session(),
  ui: { notify() {} },
});

const drivePastTheCommand = async (emit, sent, invoke) => {
  await emit("session_start");
  await invoke();
  await emit("session_compact");
  await emit("session_compact");
  await emit("agent_settled", undefined, quiet);
  if (sent.length !== 1) {
    throw new Error(`the hard decision must send exactly one thing first: ${JSON.stringify(sent)}`);
  }
  if (sent[0].content.includes("/fm-primary-rotate")) {
    throw new Error(`a rotation must never precede the capture request: ${JSON.stringify(sent)}`);
  }
  await emit("agent_settled", undefined, quiet);
  if (sent[1]?.content !== "/fm-primary-rotate") {
    throw new Error(`the rotation must follow the capture request: ${JSON.stringify(sent)}`);
  }
};

await drive(async ({ emit, sent, commands }) => {
  const rotate = commands.get("fm-primary-rotate");

  await drivePastTheCommand(emit, sent, async () => {
    await rotate.handler([], rotateCtx(() => {
      throw new Error("session replacement failed");
    }));
  });

  sent.length = 0;
  await drivePastTheCommand(emit, sent, async () => {
    writeFileSync(lockPath, "1\n");
    await rotate.handler([], rotateCtx(() => ({ cancelled: false })));
    writeFileSync(lockPath, `${process.pid}\n`);
  });
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/manual-output")
  expect_code 0 "$status" "a failed or refused operator rotation must leave the capture owed: $out"
  pass "a failed or refused operator rotation still leaves the durable knowledge capture owed"
}

# A cancel is an answer, so the ladder ends there; a failure is not, so the
# ladder keeps walking to the documented loud stand-down. Both halves are
# pinned together because the difference between them is the whole rule.
test_a_cancelled_rotation_stands_down_and_a_failed_one_keeps_walking() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/cancel/state"
  printf '%s\n' "$$" > "$TMP_ROOT/cancel/state/.lock"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/cancel/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/cancel-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };
const rotateCtx = (session) => ({
  waitForIdle: async () => {},
  newSession: async () => session(),
  ui: { notify() {} },
});

const lines = [];
const realWrite = process.stderr.write.bind(process.stderr);
let failure = null;
try {
  process.stderr.write = (chunk) => {
    lines.push(String(chunk));
    return true;
  };
  await drive(async ({ emit, sent, commands }) => {
    const rotate = commands.get("fm-primary-rotate");

    // Walk the ladder to a dispatch, then have the operator cancel it.
    await emit("session_start");
    await emit("session_compact");
    await emit("session_compact");
    await emit("agent_settled", undefined, quiet);
    await emit("agent_settled", undefined, quiet);
    if (sent.length !== 2) failure = `expected capture then dispatch: ${JSON.stringify(sent)}`;
    await rotate.handler([], rotateCtx(() => ({ cancelled: true })));

    // The operator has answered: nothing further is asked of this conversation.
    for (let i = 0; i < 8; i += 1) await emit("agent_settled", undefined, quiet);
    if (!failure && sent.length !== 2) failure = `a cancelled rotation must send nothing further: ${JSON.stringify(sent)}`;
    if (!failure && lines.some((line) => line.includes("stood down"))) {
      failure = `a cancelled rotation must not also announce a stand-down: ${JSON.stringify(lines)}`;
    }

    // A failure is not an answer, so the same ladder runs to its loud end.
    sent.length = 0;
    lines.length = 0;
    await emit("session_start");
    await emit("session_compact");
    await emit("session_compact");
    await emit("agent_settled", undefined, quiet);
    await emit("agent_settled", undefined, quiet);
    if (!failure && sent.length !== 2) failure = `expected capture then dispatch after the reset: ${JSON.stringify(sent)}`;
    await rotate.handler([], rotateCtx(() => {
      throw new Error("session replacement failed");
    }));
    for (let i = 0; i < 8; i += 1) await emit("agent_settled", undefined, quiet);
  });
} finally {
  process.stderr.write = realWrite;
}
if (failure) throw new Error(failure);
const stoodDown = lines.filter((line) => line.includes("stood down"));
if (stoodDown.length !== 1) {
  throw new Error(`a failed rotation must still stand down exactly once: ${JSON.stringify(lines)}`);
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/cancel-output")
  expect_code 0 "$status" "a cancel must end the ladder and a failure must not: $out"
  pass "a cancelled rotation stands down at once while a failed one still walks to the loud stand-down"
}

# The helm is re-read whenever the lock records a different owner. A session
# that settles before it holds the lock - the lock absent, or held by someone
# else - and then takes it mid-conversation must not stay inert until the next
# session boundary, because bin/fm-lock.sh reclaims the lock whenever it runs.
test_taking_the_helm_mid_conversation_is_noticed() {
  local out status
  write_extension_driver
  mkdir -p "$TMP_ROOT/latch/state"
  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/latch/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  SELF_PID="$$" \
  DRIVER="$TMP_ROOT/driver.mjs" \
    node --input-type=module > "$TMP_ROOT/latch-output" 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };
const lock = `${process.env.FM_STATE_OVERRIDE}/.lock`;

await drive(async ({ emit, sent }) => {
  await emit("session_start");
  await emit("session_compact");
  await emit("session_compact");

  // No lock at all: nothing to act for, so nothing is done.
  await emit("agent_settled", undefined, quiet);
  if (sent.length !== 0) throw new Error(`a session with no lock must stay inert: ${JSON.stringify(sent)}`);

  // A live pid that is neither this process nor an ancestor of it.
  writeFileSync(lock, "1\n");
  await emit("agent_settled", undefined, quiet);
  if (sent.length !== 0) throw new Error(`a session that does not hold the lock must stay inert: ${JSON.stringify(sent)}`);

  // The lock is reclaimed for this session mid-conversation, with no
  // intervening session_start. The breaker must come back to life.
  writeFileSync(lock, `${process.env.SELF_PID}\n`);
  await emit("agent_settled", undefined, quiet);
  if (sent.length !== 1) {
    throw new Error(`taking the helm mid-conversation must re-arm the breaker: ${JSON.stringify(sent)}`);
  }
  if (!sent[0].content.includes("/stow")) throw new Error("the re-armed breaker must ask for capture first");
});
EOF
  status=$?
  out=$(cat "$TMP_ROOT/latch-output")
  expect_code 0 "$status" "taking the helm mid-conversation must re-arm the breaker: $out"
  pass "a session that takes the home's helm mid-conversation is not latched inert"
}

# The event threshold is derived from what bin/fm-pi-session-metrics.mjs counts
# as a recorded event and applied to what the extension counts live, so the two
# have to be the same quantity. This drives both sides over one event stream -
# a transcript for the measurement, the equivalent message_end and compaction
# events for the breaker - and requires the totals to agree. It fails when a
# record class Pi emits `message_end` for is left out of the measured basis, or
# when a class Pi emits no message for is counted into it.
test_the_measured_event_basis_is_what_the_breaker_counts() {
  local out status dir report
  write_extension_driver
  dir="$TMP_ROOT/basis/sessions/--Users-someone-project--"
  mkdir -p "$dir" "$TMP_ROOT/basis/state"
  printf '%s\n' "$$" > "$TMP_ROOT/basis/state/.lock"
  {
    # Records Pi emits no message for: they must not reach the measured basis.
    printf '{"type":"session","version":3,"id":"01a01f3c-bade-7801-90e6-708e6fc8e9c8","timestamp":"2026-08-20T12:00:00.000Z"}\n'
    printf '{"type":"model_change","timestamp":"2026-08-20T12:00:01.000Z","provider":"xai","modelId":"grok-5"}\n'
    printf '{"type":"thinking_level_change","timestamp":"2026-08-20T12:00:02.000Z","level":"high"}\n'
    # Records Pi does emit message_end for, in every class it has.
    printf '{"type":"message","timestamp":"2026-08-20T12:00:03.000Z","message":{"role":"user","content":[]}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:04.000Z","message":{"role":"user","content":[]}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:05.000Z","message":{"role":"assistant","provider":"xai","model":"grok-5","usage":{"cacheRead":10}}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:06.000Z","message":{"role":"assistant","provider":"xai","model":"grok-5","usage":{"cacheRead":10}}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:07.000Z","message":{"role":"toolResult","content":[]}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:08.000Z","message":{"role":"toolResult","content":[]}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:09.000Z","message":{"role":"bashExecution","content":[]}}\n'
    printf '{"type":"custom_message","timestamp":"2026-08-20T12:00:10.000Z","customType":"firstmate","content":"x"}\n'
    printf '{"type":"custom_message","timestamp":"2026-08-20T12:00:11.000Z","customType":"firstmate","content":"y"}\n'
    printf '{"type":"compaction","timestamp":"2026-08-20T12:00:12.000Z","summary":"s"}\n'
  } > "$dir/2026-08-20T12-00-00-000Z_01a01f3c-bade-7801-90e6-708e6fc8e9c8.jsonl"

  report=$("$ROOT/bin/fm-pi-session-metrics.sh" --sessions-dir "$TMP_ROOT/basis/sessions" --min-assistant-messages 1 2>/dev/null)
  expect_code 0 "$?" "the measurement must read the fixture transcript: $report"

  EXT="$EXT" \
  FM_STATE_OVERRIDE="$TMP_ROOT/basis/state" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  DRIVER="$TMP_ROOT/driver.mjs" \
  REPORT="$report" \
    node --input-type=module > "$TMP_ROOT/basis-output" 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { drive } = await import(pathToFileURL(process.env.DRIVER).href);
const quiet = { isIdle: () => true, hasPendingMessages: () => false, ui: { notify() {} } };

const measured = JSON.parse(process.env.REPORT).sessions[0];
const message = (role, extra) => ({ message: { role, ...extra } });

await drive(async ({ emit }) => {
  await emit("session_start");
  // The same stream Pi would deliver for the transcript above: one message_end
  // per message record, including the custom messages, and session_compact for
  // the compaction. The setting changes and the session header deliver nothing.
  await emit("message_end", message("user"));
  await emit("message_end", message("user"));
  await emit("message_end", message("assistant", { provider: "xai", usage: { cacheRead: 10 } }));
  await emit("message_end", message("assistant", { provider: "xai", usage: { cacheRead: 10 } }));
  await emit("message_end", message("toolResult"));
  await emit("message_end", message("toolResult"));
  await emit("message_end", message("bashExecution"));
  await emit("message_end", message("custom"));
  await emit("message_end", message("custom"));
  await emit("session_compact");
  await emit("agent_settled", undefined, quiet);
});

// The extension's own serialized record is how the live counters are read back.
const live = JSON.parse(readFileSync(`${process.env.FM_STATE_OVERRIDE}/.pi-primary-growth`, "utf8"));

if (live.events !== measured.recordedEvents) {
  throw new Error(
    `the measured basis and the live counter must be the same quantity: recordedEvents ${measured.recordedEvents} against events ${live.events}`,
  );
}
if (measured.events === measured.recordedEvents) {
  throw new Error("the fixture must contain records Pi emits no message for, or it proves nothing");
}
for (const [live_, measured_] of [
  [live.turns, measured.turns],
  [live.assistantMessages, measured.assistantMessages],
  [live.compactions, measured.compactions],
]) {
  if (live_ !== measured_) throw new Error(`class totals must agree: ${live_} against ${measured_}`);
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/basis-output")
  expect_code 0 "$status" "the measured event basis must match the live counter: $out"
  pass "the measured recorded-event basis counts exactly what the live breaker counts"
}

test_thresholds_match_the_measured_baseline
test_triggers_fire_in_a_fixed_order_and_only_when_crossed
test_quota_pressure_is_read_not_invented
test_the_quota_provider_binding_comes_from_quota_axi_itself
test_thresholds_are_env_overridable_and_survive_bad_input
test_rotation_only_happens_at_a_settled_quiet_boundary
test_a_session_without_the_helm_never_acts
test_the_kill_switch_stops_every_breaker
test_soft_warnings_are_delivered_once_and_carry_the_operational_marker
test_a_dispatch_nothing_acts_on_stands_down_once_and_loudly
test_the_rotation_command_refuses_waits_and_records
test_a_failed_operator_rotation_still_leaves_the_capture_owed
test_a_cancelled_rotation_stands_down_and_a_failed_one_keeps_walking
test_taking_the_helm_mid_conversation_is_noticed
test_the_measured_event_basis_is_what_the_breaker_counts
