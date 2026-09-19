// Calibrated growth policy for a Pi PRIMARY session
// (.pi/extensions/fm-primary-growth.ts).
//
// A primary Pi session re-sends its whole conversation on every turn. While
// that re-send stays cached it is cheap, and the deliberate answer to a long
// supervision day is to let it stay cached rather than churn it. What the
// measurement in docs/verification/pi-primary-growth-baseline.md shows is that
// the cheapness has a cliff: past a point the conversation is compacted, the
// cached prefix stops matching, and the session starts paying to re-read a
// transcript that is no longer helping it. This module decides where that
// cliff is.
//
// Every number below came from that measurement, over the local Pi transcript
// corpus, and re-running bin/fm-pi-session-metrics.sh is how they are
// re-checked rather than re-guessed. None of them is a round number chosen
// because it looked reasonable.
//
// This module owns ONLY the decision. It is pure: it imports nothing, touches
// no file, reads no clock, and performs no rotation. The extension owns every
// side effect - durable knowledge capture, starting the replacement
// conversation, and the supervision handoff across it. That separation is what
// makes "a circuit breaker can never split a turn" structural rather than a
// rule this file has to remember: a function that cannot act cannot act
// mid-action. It is also what makes the policy testable with no Pi SDK
// (tests/fm-primary-growth.test.sh).
//
// The two-level shape is deliberate. A soft level is a warning that changes
// nothing and is delivered once per conversation per reason; a hard level asks
// for a rotation. Nothing here ever changes a model, names a provider, or
// routes work, for the reason stated at ModelChangeAdvice.

/** Soft levels warn. Hard levels ask for a rotation. */
export type GrowthLevel = "ok" | "soft" | "hard";

/** Warnings, in the fixed order they are evaluated. */
export type SoftReason = "cache_reread" | "quota_runway";

/** Rotation triggers, in the fixed order they are evaluated. */
export type HardReason = "compaction" | "event_growth";

export type GrowthReason = SoftReason | HardReason;

export interface GrowthThresholds {
  /** False disables the whole policy; the session then behaves as before. */
  enabled: boolean;
  /**
   * Soft. Cumulative cache-read tokens per assistant message. The measured
   * corpus put the median at 75,501 and the 90th percentile at 191,405, so
   * 200,000 is a deliberate top-decile alarm: high enough that an ordinary
   * working session never sees it.
   *
   * It does NOT promise to arrive before a session's first compaction. The
   * measured median for sessions that compacted exactly once is 177,107, which
   * is below this threshold, so half of that population reaches its first
   * compaction unwarned - and the cumulative estimator lags a sudden change by
   * design besides. The hard compaction trigger, not this warning, is the real
   * guard; this one is an early notice when it does arrive in time.
   */
  cacheReadPerAssistantMessage: number;
  /**
   * Hard. The SECOND compaction, not the first. In the measured corpus a
   * session's median total cache-read cost was 3.7M with no compaction, 54M
   * with one, and 1.32B with two or more: one compaction is ordinary (8 of 81
   * sessions) and survivable, while the step from one to two multiplies the
   * bill by roughly 25x again and marks the runaway class (3 of 81). Rotating
   * on the first compaction would churn a tenth of all ordinary sessions for
   * no measured benefit.
   */
  compactions: number;
  /**
   * Hard. Events of the coarse classes this policy is actually fed - every
   * record Pi emits `message_end` for, which is the message roles and the
   * custom messages extensions append, plus compaction. That is the same
   * quantity `recordedEvents` measures in bin/fm-pi-session-metrics.mjs, and
   * the threshold is derived from it rather than from a whole-transcript record
   * count that also carries setting changes and the session header, which the
   * live counter has no event for.
   *
   * On that basis the largest session in the measured corpus that had NOT
   * reached two compactions carried 4,150 recorded events; the two clear
   * runaways carried 5,920 and 11,265. 5,000 sits above every ordinary session
   * observed and below both runaways, so it catches a session growing without
   * bound even when compaction has not fired yet.
   */
  events: number;
}

/**
 * Growth accumulated by ONE conversation. It is reset whenever a new session
 * activates, which is what makes a rotation loop structurally impossible: a
 * replacement conversation starts at zero on every axis and cannot inherit a
 * counter that would immediately rotate it again.
 */
export interface GrowthState {
  /** Epoch seconds when this conversation started. */
  startedAt: number;
  /** Context-visible user turns handled by this conversation. */
  turns: number;
  /** Assistant messages produced by this conversation. */
  assistantMessages: number;
  /** All recorded events, of every coarse class. */
  events: number;
  /** Compactions this conversation has been through. */
  compactions: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  /** Counts per coarse event class. Never a message, a tool name, or a path. */
  eventClasses: Record<string, number>;
  /** Soft reasons already delivered, so a warning is sent once, not per turn. */
  notified: SoftReason[];
}

export const GROWTH_DEFAULTS: GrowthThresholds = {
  enabled: true,
  cacheReadPerAssistantMessage: 200_000,
  compactions: 2,
  events: 5_000,
};

/**
 * The quota facts a growth decision is allowed to use, reduced from a
 * quota-axi report. quota-axi owns the projection itself, including whether a
 * window is projected to run out before it resets; this module never
 * recomputes it, never second-guesses it, and treats an unreadable report as
 * unknown rather than as pressure.
 */
export interface QuotaPressure {
  status: "unknown" | "through_reset" | "projected_exhaustion";
  /** Seconds of projected usable runway, when quota-axi supplied one. */
  usableRunwaySeconds: number | null;
  /** The window quota-axi named as limiting, for the warning's evidence line. */
  limitingWindowId: string | null;
  effectivePercentRemaining: number | null;
}

export const UNKNOWN_QUOTA: QuotaPressure = {
  status: "unknown",
  usableRunwaySeconds: null,
  limitingWindowId: null,
  effectivePercentRemaining: null,
};

/**
 * A recommendation to reconsider the model, and deliberately nothing more.
 *
 * This module never names a target provider or model, and the extension never
 * calls setModel. That is the enforceable form of two boundaries the captain
 * set: the Harm-or-Duty boundary a model carries must survive any change, and
 * protected material must never be silently routed to a provider that is not
 * eligible to hold it. A recommendation that cannot name a destination cannot
 * route anything anywhere, so neither boundary can be crossed by this code
 * path at all. Choosing an eligible destination stays with its existing owner,
 * .agents/skills/quota-array-dispatch/SKILL.md, which reads current quota
 * evidence and applies the eligibility gates this file has no access to.
 */
export interface ModelChangeAdvice {
  /** Always true. There is no non-advisory form of this. */
  advisory: true;
  /** Always true. A human or the dispatching first mate reviews eligibility. */
  requiresEligibilityReview: true;
  /** Always null. This module is not allowed to name a destination. */
  target: null;
  /** Where the destination decision actually belongs. */
  owner: "quota-array-dispatch";
}

export const MODEL_CHANGE_ADVICE: ModelChangeAdvice = {
  advisory: true,
  requiresEligibilityReview: true,
  target: null,
  owner: "quota-array-dispatch",
};

export interface GrowthDecision {
  level: GrowthLevel;
  reason?: GrowthReason;
  /** Human-readable evidence for the one-line notice. */
  detail: string;
  /** Present only alongside a quota warning; never an instruction. */
  modelChangeAdvice?: ModelChangeAdvice;
}

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
 * Thresholds from the environment, falling back to GROWTH_DEFAULTS for any
 * variable that is absent or malformed. Malformed input never disables the
 * policy silently and never throws inside a supervision turn.
 */
export function readGrowthThresholds(env: Record<string, string | undefined>): GrowthThresholds {
  return {
    enabled: booleanFlag(env.FM_PI_GROWTH, GROWTH_DEFAULTS.enabled),
    cacheReadPerAssistantMessage: positiveInteger(
      env.FM_PI_GROWTH_CACHE_READ_PER_MESSAGE,
      GROWTH_DEFAULTS.cacheReadPerAssistantMessage,
    ),
    compactions: positiveInteger(env.FM_PI_GROWTH_COMPACTIONS, GROWTH_DEFAULTS.compactions),
    events: positiveInteger(env.FM_PI_GROWTH_EVENTS, GROWTH_DEFAULTS.events),
  };
}

export function newGrowthState(now: number): GrowthState {
  return {
    startedAt: now,
    turns: 0,
    assistantMessages: 0,
    events: 0,
    compactions: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    eventClasses: {},
    notified: [],
  };
}

/** The token counts a growth decision reads. Never any message content. */
export interface UsageSample {
  input?: number;
  output?: number;
  cacheRead?: number;
  cacheWrite?: number;
}

function nonNegative(value: number | undefined): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}

function countClass(state: GrowthState, eventClass: string): Record<string, number> {
  return { ...state.eventClasses, [eventClass]: (state.eventClasses[eventClass] || 0) + 1 };
}

/**
 * Record one event of a coarse class. `eventClass` is a fixed vocabulary
 * chosen by the caller from the record's own type and role - never a tool
 * name, a command, or anything derived from message content.
 */
export function recordEvent(state: GrowthState, eventClass: string): GrowthState {
  return { ...state, events: state.events + 1, eventClasses: countClass(state, eventClass) };
}

export function recordTurn(state: GrowthState): GrowthState {
  return { ...recordEvent(state, "user"), turns: state.turns + 1 };
}

export function recordAssistantMessage(state: GrowthState, usage: UsageSample | undefined): GrowthState {
  const next = recordEvent(state, "assistant");
  return {
    ...next,
    assistantMessages: next.assistantMessages + 1,
    inputTokens: next.inputTokens + nonNegative(usage?.input),
    outputTokens: next.outputTokens + nonNegative(usage?.output),
    cacheReadTokens: next.cacheReadTokens + nonNegative(usage?.cacheRead),
    cacheWriteTokens: next.cacheWriteTokens + nonNegative(usage?.cacheWrite),
  };
}

export function recordCompaction(state: GrowthState): GrowthState {
  const next = recordEvent(state, "compaction");
  return { ...next, compactions: next.compactions + 1 };
}

export function recordNotified(state: GrowthState, reason: SoftReason): GrowthState {
  if (state.notified.includes(reason)) return state;
  return { ...state, notified: [...state.notified, reason] };
}

export function cacheReadPerAssistantMessage(state: GrowthState): number {
  if (state.assistantMessages <= 0) return 0;
  return Math.round(state.cacheReadTokens / state.assistantMessages);
}

/**
 * Which quota-axi provider, if any, actually meters what a given Pi provider
 * spends.
 *
 * The two tools do not share an identifier vocabulary - Pi says `xai` where
 * quota-axi says `grok` - and guessing across that gap would be inventing
 * quota evidence. quota-axi already publishes the answer: its `auth` report
 * names each provider's credential sources, and a source of the form
 * `pi:<provider>` states outright that this quota-axi provider is metering
 * that Pi login. This function reads exactly that and nothing else, so the
 * mapping stays correct as quota-axi gains providers instead of drifting
 * against a table copied here.
 *
 * A Pi provider with no such source resolves to null and therefore to no quota
 * warning, even when a similarly-named quota-axi provider exists. Two logins
 * that look related are not evidence that one meters the other, and a warning
 * derived from the wrong account is worse than no warning at all. An operator
 * who can confirm a binding the tools do not publish supplies it explicitly
 * through FM_PI_GROWTH_QUOTA_PROVIDER.
 */
export function quotaProviderForPiProvider(authReport: unknown, piProvider: string | null): string | null {
  if (!piProvider) return null;
  if (!authReport || typeof authReport !== "object") return null;
  const entries = (authReport as { auth?: unknown }).auth;
  if (!Array.isArray(entries)) return null;
  const wanted = `pi:${piProvider}`;
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") continue;
    const provider = (entry as { provider?: unknown }).provider;
    if (typeof provider !== "string") continue;
    const sources = (entry as { sources?: unknown }).sources;
    if (!Array.isArray(sources)) continue;
    for (const source of sources) {
      if (source && typeof source === "object" && (source as { source?: unknown }).source === wanted) {
        return provider;
      }
    }
  }
  return null;
}

/**
 * Reduce a parsed quota-axi report to the pressure facts a decision may use.
 * Anything unrecognized degrades to UNKNOWN_QUOTA: a report this function
 * cannot read is never treated as evidence of pressure, because warning on a
 * parse failure would train the reader to ignore the warning.
 */
export function quotaPressure(report: unknown, provider: string | null): QuotaPressure {
  if (!report || typeof report !== "object") return UNKNOWN_QUOTA;
  const providers = (report as { providers?: unknown }).providers;
  if (!Array.isArray(providers)) return UNKNOWN_QUOTA;
  const match = providers.find(
    (entry) => entry && typeof entry === "object" && (entry as { provider?: unknown }).provider === provider,
  ) as { quotaSemantics?: { effectiveAvailability?: unknown } } | undefined;
  if (!match) return UNKNOWN_QUOTA;
  const availability = match.quotaSemantics?.effectiveAvailability;
  if (!Array.isArray(availability) || availability.length === 0) return UNKNOWN_QUOTA;

  // The worst scope wins: a model-scoped window that is projected to run out
  // is real pressure even when the account-wide scope is comfortable.
  let worst: QuotaPressure = UNKNOWN_QUOTA;
  for (const entry of availability) {
    if (!entry || typeof entry !== "object") continue;
    const runway = (entry as { runway?: Record<string, unknown> }).runway;
    const status = runway?.status;
    if (status !== "projected_exhaustion" && status !== "through_reset") continue;
    const seconds = typeof runway?.usableRunwaySeconds === "number" ? runway.usableRunwaySeconds : null;
    const candidate: QuotaPressure = {
      status,
      usableRunwaySeconds: seconds,
      limitingWindowId:
        typeof (entry as { limitingWindowIds?: unknown[] }).limitingWindowIds?.[0] === "string"
          ? ((entry as { limitingWindowIds: string[] }).limitingWindowIds[0])
          : null,
      effectivePercentRemaining:
        typeof (entry as { effectivePercentRemaining?: unknown }).effectivePercentRemaining === "number"
          ? (entry as { effectivePercentRemaining: number }).effectivePercentRemaining
          : null,
    };
    if (worst.status !== "projected_exhaustion") {
      worst = candidate;
      continue;
    }
    if (candidate.status !== "projected_exhaustion") continue;
    const a = candidate.usableRunwaySeconds;
    const b = worst.usableRunwaySeconds;
    if (a !== null && (b === null || a < b)) worst = candidate;
  }
  return worst;
}

/**
 * The whole check. Evaluated ONLY at a settled boundary by the caller, so
 * "never split a turn" is structural rather than a rule this function has to
 * enforce - see the module header.
 *
 * Hard outranks soft, so an already-runaway session is asked to rotate rather
 * than merely warned. Within each level the order is fixed - compaction, then
 * event growth; cache re-reads, then quota runway - so the same state always
 * produces the same reason, which is what makes the notices and the tests
 * meaningful.
 */
export function growthDecision(
  state: GrowthState,
  thresholds: GrowthThresholds,
  quota: QuotaPressure,
): GrowthDecision {
  const ratio = cacheReadPerAssistantMessage(state);
  const summary = `turns=${state.turns} events=${state.events} compactions=${state.compactions} cacheReadPerMessage=${ratio}`;
  if (!thresholds.enabled) return { level: "ok", detail: "growth policy disabled" };

  if (thresholds.compactions > 0 && state.compactions >= thresholds.compactions) {
    return {
      level: "hard",
      reason: "compaction",
      detail: `compactions=${state.compactions}>=${thresholds.compactions} (${summary})`,
    };
  }
  if (thresholds.events > 0 && state.events >= thresholds.events) {
    return {
      level: "hard",
      reason: "event_growth",
      detail: `events=${state.events}>=${thresholds.events} (${summary})`,
    };
  }

  if (
    thresholds.cacheReadPerAssistantMessage > 0 &&
    ratio >= thresholds.cacheReadPerAssistantMessage &&
    !state.notified.includes("cache_reread")
  ) {
    return {
      level: "soft",
      reason: "cache_reread",
      detail: `cacheReadPerMessage=${ratio}>=${thresholds.cacheReadPerAssistantMessage} (${summary})`,
    };
  }

  if (quota.status === "projected_exhaustion" && !state.notified.includes("quota_runway")) {
    const runway = quota.usableRunwaySeconds === null ? "unknown" : `${quota.usableRunwaySeconds}s`;
    const window = quota.limitingWindowId ?? "unknown";
    const remaining =
      quota.effectivePercentRemaining === null ? "unknown" : `${quota.effectivePercentRemaining}%`;
    return {
      level: "soft",
      reason: "quota_runway",
      detail: `quota projected to run out before its window resets (window=${window} remaining=${remaining} runway=${runway})`,
      modelChangeAdvice: MODEL_CHANGE_ADVICE,
    };
  }

  return { level: "ok", detail: summary };
}

/** One loud line per fired decision, by contract (never more than one). */
export function growthLogLine(decision: GrowthDecision): string {
  const action = decision.level === "hard" ? "rotation requested" : "warning";
  return `firstmate: primary session ${action} (reason=${decision.reason ?? "unknown"} ${decision.detail})`;
}
