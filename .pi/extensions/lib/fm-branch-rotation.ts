// Deterministic rotation policy for the persistent Pi supervision branch
// (.pi/extensions/fm-branch-supervision.ts).
//
// The branch conversation is deliberately long-lived so its byte-stable
// prefix stays cached (docs/pi-supervision-branch.md "Cost model and the
// byte-stable prefix"). What that persistence also accumulates is turn
// history: every wake the branch handles is re-sent as growing context on the
// next one, so a session that lives long enough eventually pays more for its
// own transcript than the cache ever saved. Rotation replaces that
// conversation with a fresh one at a boundary that is safe to cross.
//
// This module owns ONLY the decision - it is pure, imports nothing, touches
// no file, and reads no clock. The extension owns every side effect: durable
// record I/O, knowledge capture before rotation, disposal, and the catch-up
// that the replacement session must run before it acts. Keeping the policy
// separable is what makes it testable without the Pi SDK
// (tests/fm-branch-rotation.test.sh).
//
// Safety boundary: a decision is only ever CONSULTED between completed
// branch actions. Nothing here can rotate mid-turn, because nothing here
// performs the rotation at all.

/** Rotation triggers, in the fixed order they are evaluated. */
export type RotationReason = "compaction" | "age" | "milestones";

export interface RotationThresholds {
  /** False disables rotation entirely; the branch then behaves as before. */
  enabled: boolean;
  /** Rotate once the session is at least this old, in seconds. */
  maxAgeSeconds: number;
  /** Rotate once the session has been compacted this many times. */
  compactions: number;
  /** Rotate once this many meaningful milestones have landed. */
  milestones: number;
}

export interface RotationState {
  /** Epoch seconds when this branch conversation was started. */
  startedAt: number;
  /**
   * Branch wakes this conversation has spent. A wake counts once its prompt
   * turn has genuinely settled, whether or not that turn went on to produce a
   * durable outcome, because a settled turn is context this conversation
   * carries either way. Observational only - it appears in the rotation log
   * line and in a no-rotate decision's detail, and triggers no rotation.
   */
  wakes: number;
  /** Meaningful milestones recorded by this conversation. */
  milestones: number;
  /** Compactions this conversation has been through. */
  compactions: number;
  /** Rotations this home has performed, across conversations. */
  rotations: number;
  /**
   * True from the moment a rotation is committed until the replacement
   * conversation has been told to re-run session start. It is durable so an
   * interrupted rotation still produces a catching-up successor rather than a
   * fresh branch that acts on a fleet it never looked at.
   */
  pendingCatchUp: boolean;
}

export const ROTATION_DEFAULTS: RotationThresholds = {
  enabled: true,
  // One day: long enough that an ordinary working session never rotates
  // mid-day, short enough that a session left running over a weekend does not
  // carry a week of transcript.
  maxAgeSeconds: 86_400,
  // The first compaction is the signal that the conversation has already
  // outgrown its window; a compacted branch has lost fidelity AND still pays
  // to re-send the summary, so rotating beats compacting again.
  compactions: 1,
  // Milestones are the cheap proxy for "this conversation has done enough
  // distinct work that its history is no longer helping it".
  milestones: 3,
};

function positiveInteger(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const trimmed = raw.trim();
  if (!/^\d+$/.test(trimmed)) return fallback;
  const value = Number(trimmed);
  // 0 means "never trigger on this axis"; the other axes still apply.
  return Number.isSafeInteger(value) ? value : fallback;
}

function booleanFlag(raw: string | undefined, fallback: boolean): boolean {
  if (raw === undefined) return fallback;
  const trimmed = raw.trim().toLowerCase();
  if (trimmed === "0" || trimmed === "false" || trimmed === "off" || trimmed === "no") return false;
  if (trimmed === "1" || trimmed === "true" || trimmed === "on" || trimmed === "yes") return true;
  return fallback;
}

/**
 * Thresholds from the environment, falling back to ROTATION_DEFAULTS for any
 * variable that is absent or malformed. Malformed input never disables
 * rotation silently and never throws inside a supervision turn.
 */
export function readRotationThresholds(env: Record<string, string | undefined>): RotationThresholds {
  return {
    enabled: booleanFlag(env.FM_BRANCH_ROTATE, ROTATION_DEFAULTS.enabled),
    maxAgeSeconds: positiveInteger(env.FM_BRANCH_ROTATE_MAX_AGE_SECONDS, ROTATION_DEFAULTS.maxAgeSeconds),
    compactions: positiveInteger(env.FM_BRANCH_ROTATE_COMPACTIONS, ROTATION_DEFAULTS.compactions),
    milestones: positiveInteger(env.FM_BRANCH_ROTATE_MILESTONES, ROTATION_DEFAULTS.milestones),
  };
}

export function newRotationState(now: number, rotations = 0, pendingCatchUp = false): RotationState {
  return { startedAt: now, wakes: 0, milestones: 0, compactions: 0, rotations, pendingCatchUp };
}

export function recordWake(state: RotationState): RotationState {
  return { ...state, wakes: state.wakes + 1 };
}

export function recordMilestone(state: RotationState): RotationState {
  return { ...state, milestones: state.milestones + 1 };
}

export function recordCompaction(state: RotationState): RotationState {
  return { ...state, compactions: state.compactions + 1 };
}

export interface RotationDecision {
  rotate: boolean;
  reason?: RotationReason;
  /** Human-readable evidence for the one-line rotation log. */
  detail: string;
}

/**
 * The whole trigger check. Evaluated ONLY at a completed-action boundary by
 * the caller, so "never split a turn" is structural rather than a rule this
 * function has to enforce.
 *
 * Order is fixed - compaction, then age, then milestones - so the same state
 * always produces the same reason, which is what makes the log and the tests
 * meaningful.
 */
export function rotationDecision(
  state: RotationState,
  thresholds: RotationThresholds,
  now: number,
): RotationDecision {
  if (!thresholds.enabled) return { rotate: false, detail: "rotation disabled" };
  if (thresholds.compactions > 0 && state.compactions >= thresholds.compactions) {
    return {
      rotate: true,
      reason: "compaction",
      detail: `compactions=${state.compactions}>=${thresholds.compactions}`,
    };
  }
  const age = Math.max(0, now - state.startedAt);
  if (thresholds.maxAgeSeconds > 0 && age >= thresholds.maxAgeSeconds) {
    return { rotate: true, reason: "age", detail: `age=${age}s>=${thresholds.maxAgeSeconds}s` };
  }
  if (thresholds.milestones > 0 && state.milestones >= thresholds.milestones) {
    return {
      rotate: true,
      reason: "milestones",
      detail: `milestones=${state.milestones}>=${thresholds.milestones}`,
    };
  }
  return { rotate: false, detail: `age=${age}s wakes=${state.wakes} milestones=${state.milestones}` };
}

/** The state the replacement conversation starts from, once rotation commits. */
export function rotatedState(state: RotationState, now: number): RotationState {
  return newRotationState(now, state.rotations + 1, true);
}

/** One loud line per rotation, by contract (never more than one). */
export function rotationLogLine(decision: RotationDecision, state: RotationState): string {
  return `firstmate: supervision branch rotated (reason=${decision.reason ?? "unknown"} ${decision.detail} wakes=${state.wakes} rotation=${state.rotations + 1})`;
}

/**
 * Durable record parsing. Any unreadable or partial record degrades to a
 * fresh state anchored at `now` rather than throwing: losing the rotation
 * counters costs one delayed rotation, while throwing would break a wake.
 */
export function parseRotationState(raw: string, now: number): RotationState {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return newRotationState(now);
  }
  if (!parsed || typeof parsed !== "object") return newRotationState(now);
  const record = parsed as Record<string, unknown>;
  const number = (key: string, fallback: number): number => {
    const value = record[key];
    return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fallback;
  };
  return {
    startedAt: number("startedAt", now),
    wakes: number("wakes", 0),
    milestones: number("milestones", 0),
    compactions: number("compactions", 0),
    rotations: number("rotations", 0),
    pendingCatchUp: record.pendingCatchUp === true,
  };
}

export function serializeRotationState(state: RotationState): string {
  return `${JSON.stringify(state)}\n`;
}
