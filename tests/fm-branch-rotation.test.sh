#!/usr/bin/env bash
# Tests for the Pi supervision branch's rotation policy
# (.pi/extensions/lib/fm-branch-rotation.ts): the deterministic trigger check,
# threshold overrides, the durable record, and the safe-boundary contract that
# a mid-action session is never rotated.
#
# The policy module is pure and imports nothing, so it runs directly under
# node with no Pi SDK. The boundary rule is exercised here against a scripted
# stand-in for the extension's serialized branch chain; the real extension's
# behavior at that boundary is owned by
# tests/fm-pi-branch-extension.test.sh's rotation regression.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-rotation)
LIB="$ROOT/.pi/extensions/lib/fm-branch-rotation.ts"
export NODE_NO_WARNINGS=1

test_triggers_fire_in_a_fixed_order_and_only_when_crossed() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const {
  ROTATION_DEFAULTS,
  newRotationState,
  recordCompaction,
  recordMilestone,
  recordWake,
  rotationDecision,
} = await import(pathToFileURL(process.env.LIB).href);

const now = 1_000_000;
const fresh = newRotationState(now);

const quiet = rotationDecision(fresh, ROTATION_DEFAULTS, now);
if (quiet.rotate) throw new Error("a brand-new conversation must not rotate");

// Many handled wakes alone are not a boundary: only compaction, age, and
// milestones are triggers, so a busy but young session keeps its cache.
let busy = fresh;
for (let i = 0; i < 50; i += 1) busy = recordWake(busy);
if (rotationDecision(busy, ROTATION_DEFAULTS, now + 60).rotate) {
  throw new Error("wake count alone must never trigger a rotation");
}

const compacted = rotationDecision(recordCompaction(fresh), ROTATION_DEFAULTS, now + 1);
if (!compacted.rotate || compacted.reason !== "compaction") {
  throw new Error(`the first compaction must rotate: ${JSON.stringify(compacted)}`);
}

const oneDay = rotationDecision(fresh, ROTATION_DEFAULTS, now + ROTATION_DEFAULTS.maxAgeSeconds);
if (!oneDay.rotate || oneDay.reason !== "age") {
  throw new Error(`the one-day age boundary must rotate: ${JSON.stringify(oneDay)}`);
}
if (rotationDecision(fresh, ROTATION_DEFAULTS, now + ROTATION_DEFAULTS.maxAgeSeconds - 1).rotate) {
  throw new Error("a session below the age boundary must not rotate");
}

let milestoned = fresh;
for (let i = 0; i < ROTATION_DEFAULTS.milestones; i += 1) milestoned = recordMilestone(milestoned);
const byMilestone = rotationDecision(milestoned, ROTATION_DEFAULTS, now + 1);
if (!byMilestone.rotate || byMilestone.reason !== "milestones") {
  throw new Error(`the milestone boundary must rotate: ${JSON.stringify(byMilestone)}`);
}

// Whichever comes first, deterministically: compaction outranks age outranks
// milestones, so the same state always logs the same reason.
const all = recordMilestone(recordCompaction(milestoned));
const ranked = rotationDecision(all, ROTATION_DEFAULTS, now + ROTATION_DEFAULTS.maxAgeSeconds * 3);
if (ranked.reason !== "compaction") throw new Error(`trigger order is not deterministic: ${ranked.reason}`);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "rotation triggers must be deterministic: $out"
  pass "rotation fires on first compaction, one-day age, and milestones, in a fixed order"
}

test_thresholds_are_env_overridable_and_survive_bad_input() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const { ROTATION_DEFAULTS, newRotationState, recordMilestone, readRotationThresholds, rotationDecision } =
  await import(pathToFileURL(process.env.LIB).href);

const defaults = readRotationThresholds({});
if (JSON.stringify(defaults) !== JSON.stringify(ROTATION_DEFAULTS)) {
  throw new Error(`an empty environment must yield the documented defaults: ${JSON.stringify(defaults)}`);
}

const tuned = readRotationThresholds({
  FM_BRANCH_ROTATE_MAX_AGE_SECONDS: "3600",
  FM_BRANCH_ROTATE_COMPACTIONS: "2",
  FM_BRANCH_ROTATE_MILESTONES: "10",
});
if (tuned.maxAgeSeconds !== 3600 || tuned.compactions !== 2 || tuned.milestones !== 10) {
  throw new Error(`thresholds must be env-overridable: ${JSON.stringify(tuned)}`);
}

// Malformed input never silently disables rotation and never throws inside a
// supervision turn.
const junk = readRotationThresholds({ FM_BRANCH_ROTATE_MAX_AGE_SECONDS: "soon", FM_BRANCH_ROTATE_MILESTONES: "-3" });
if (junk.maxAgeSeconds !== ROTATION_DEFAULTS.maxAgeSeconds || junk.milestones !== ROTATION_DEFAULTS.milestones) {
  throw new Error(`malformed thresholds must fall back to the defaults: ${JSON.stringify(junk)}`);
}

const off = readRotationThresholds({ FM_BRANCH_ROTATE: "0" });
if (off.enabled) throw new Error("FM_BRANCH_ROTATE=0 must disable rotation");
const now = 500;
let state = newRotationState(now);
for (let i = 0; i < 99; i += 1) state = recordMilestone(state);
if (rotationDecision(state, off, now + 999_999).rotate) {
  throw new Error("a disabled policy must never rotate on any axis");
}

// A zero threshold retires that one axis without touching the others.
const noAge = readRotationThresholds({ FM_BRANCH_ROTATE_MAX_AGE_SECONDS: "0", FM_BRANCH_ROTATE_COMPACTIONS: "0" });
const aged = rotationDecision(newRotationState(now), noAge, now + 10_000_000);
if (aged.rotate) throw new Error("a zero age threshold must retire the age axis");
if (!rotationDecision(state, noAge, now + 1).rotate) {
  throw new Error("retiring one axis must leave the others live");
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "rotation thresholds must be env-overridable: $out"
  pass "rotation thresholds are env-overridable and degrade safely on bad input"
}

test_durable_record_round_trips_and_survives_corruption() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const { newRotationState, parseRotationState, recordMilestone, recordWake, rotatedState, serializeRotationState } =
  await import(pathToFileURL(process.env.LIB).href);

const now = 42;
const state = recordMilestone(recordWake(newRotationState(now)));
const round = parseRotationState(serializeRotationState(state), 999);
if (JSON.stringify(round) !== JSON.stringify(state)) {
  throw new Error(`the durable record must round-trip: ${JSON.stringify(round)}`);
}

// A truncated or garbage record costs at most one delayed rotation; it must
// never throw inside a supervision turn.
for (const raw of ["", "{", "null", "[]", '{"startedAt":"soon","wakes":-4}']) {
  const recovered = parseRotationState(raw, now);
  if (recovered.startedAt !== now || recovered.wakes !== 0 || recovered.pendingCatchUp) {
    throw new Error(`a corrupt record must degrade to a fresh state: ${raw} -> ${JSON.stringify(recovered)}`);
  }
}

// The successor starts clean, counts the rotation, and OWES a catch-up: the
// replacement conversation must re-run session start before it acts.
const next = rotatedState(state, now + 100);
if (next.wakes !== 0 || next.milestones !== 0 || next.compactions !== 0) {
  throw new Error(`a rotated conversation must start with clean counters: ${JSON.stringify(next)}`);
}
if (next.rotations !== state.rotations + 1) throw new Error("rotations must be counted across conversations");
if (!next.pendingCatchUp) throw new Error("a rotated conversation must owe a session-start catch-up");
if (!parseRotationState(serializeRotationState(next), 0).pendingCatchUp) {
  throw new Error("the catch-up obligation must be durable across a restart");
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the rotation record must be durable: $out"
  pass "the rotation record round-trips, survives corruption, and makes the catch-up durable"
}

test_rotation_only_happens_at_a_completed_action_boundary() {
  local out status
  LIB="$LIB" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const { newRotationState, recordCompaction, recordWake, rotatedState, rotationDecision, rotationLogLine, readRotationThresholds } =
  await import(pathToFileURL(process.env.LIB).href);

// Stand-in for the extension's serialized branch chain: actions run one at a
// time, and the policy is consulted only after an action has RETURNED. This
// mirrors enqueueWake, where maybeRotateAtBoundary runs after the wake's
// prompt resolves and its wake-row grant is released.
const thresholds = readRotationThresholds({ FM_BRANCH_ROTATE_MILESTONES: "0", FM_BRANCH_ROTATE_MAX_AGE_SECONDS: "0" });
const log = [];
let state = newRotationState(0);
let conversation = 1;
let inAction = false;
let chain = Promise.resolve();

const runAction = (name, body) => {
  chain = chain.then(async () => {
    if (inAction) throw new Error("actions must be serialized; the chain overlapped");
    inAction = true;
    log.push(`start:${name}:c${conversation}`);
    await body();
    log.push(`end:${name}:c${conversation}`);
    inAction = false;
    // The boundary.
    state = recordWake(state);
    const decision = rotationDecision(state, thresholds, 1);
    if (!decision.rotate) return;
    log.push(`capture:c${conversation}`);
    log.push(rotationLogLine(decision, state));
    state = rotatedState(state, 1);
    conversation += 1;
  });
};

// A compaction arrives in the MIDDLE of a long action. It is recorded, but
// the action must run to completion before anything rotates.
runAction("long-wake", async () => {
  state = recordCompaction(state);
  await new Promise((resolve) => setTimeout(resolve, 5));
  if (conversation !== 1) throw new Error("the conversation rotated while an action was still running");
});
runAction("next-wake", async () => {});
await chain;

const expected = [
  "start:long-wake:c1",
  "end:long-wake:c1",
  "capture:c1",
  "start:next-wake:c2",
  "end:next-wake:c2",
];
const rotations = log.filter((line) => line.startsWith("firstmate: supervision branch rotated"));
if (rotations.length !== 1) throw new Error(`exactly one loud line per rotation: ${JSON.stringify(rotations)}`);
if (!rotations[0].includes("reason=compaction") || !rotations[0].includes("rotation=1")) {
  throw new Error(`the rotation line must name its reason: ${rotations[0]}`);
}
const withoutLog = log.filter((line) => !line.startsWith("firstmate:"));
if (JSON.stringify(withoutLog) !== JSON.stringify(expected)) {
  throw new Error(`rotation crossed an action boundary: ${JSON.stringify(withoutLog)}`);
}
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "a mid-action session must not rotate: $out"
  pass "rotation waits for the current action to finish, captures first, and logs one loud line"
}

test_triggers_fire_in_a_fixed_order_and_only_when_crossed
test_thresholds_are_env_overridable_and_survive_bad_input
test_durable_record_round_trips_and_survives_corruption
test_rotation_only_happens_at_a_completed_action_boundary
