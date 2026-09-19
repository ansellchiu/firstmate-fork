// Firstmate primary-session circuit breakers for Pi.
//
// A primary Pi session re-sends its whole conversation every turn. This
// extension measures that growth as it happens, warns once when it looks
// abnormal, and asks for a rotation when the measured runaway thresholds are
// crossed. The thresholds themselves, and the evidence behind them, belong to
// ./lib/fm-primary-growth.ts; the operating contract belongs to
// docs/pi-primary-growth.md. This file owns only the side effects.
//
// THE TWO SAFETY PROPERTIES THIS FILE IS RESPONSIBLE FOR.
//
// 1. A rotation can never split a bounded action. Every decision is taken in
//    `agent_settled`, which fires only once the agent has stopped streaming and
//    no tool call is in flight, and the rotation itself is refused unless the
//    context still reports idle with nothing queued. The policy module cannot
//    rotate at all - it has no side effects - so the only place a mid-action
//    rotation could originate is here, and here it is gated on settled.
//
// 2. A rotation can never drop supervision. Rotation goes through Pi's own
//    session replacement (`newSession`), which is the same path `/new` takes.
//    ./fm-primary-pi-watch.ts already owns that path: it binds one watcher
//    generation per session activation and re-arms on the replacement's
//    `session_start`, and ./fm-primary-turnend-guard.ts already re-emits the
//    session-start context into the replacement. This file deliberately adds no
//    second mechanism for either; it only refuses to rotate when it is not the
//    session those two are supervising.
//
// It is inert in any session that does not hold the home's session lock, which
// is what keeps it out of the way of a crewmate working in a firstmate
// worktree - everything under .pi/extensions auto-loads there too.

import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";
import { lockOwnership, readLockPid } from "./lib/fm-primary-session-lock.ts";
import {
  type GrowthDecision,
  type GrowthState,
  type QuotaPressure,
  type SoftReason,
  UNKNOWN_QUOTA,
  growthDecision,
  growthLogLine,
  newGrowthState,
  quotaPressure,
  quotaProviderForPiProvider,
  readGrowthThresholds,
  recordAssistantMessage,
  recordCompaction,
  recordEvent,
  recordNotified,
  recordTurn,
} from "./lib/fm-primary-growth.ts";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const stateDir = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const record = `${stateDir}/.pi-primary-growth`;

const thresholds = readGrowthThresholds(process.env);

// An operator-confirmed binding for a Pi provider quota-axi does not publish a
// `pi:` credential source for. It is deliberately explicit: only the operator
// knows whether two separate logins are the same account, and the code must
// not assume it. See docs/pi-primary-growth.md.
const quotaProviderOverride = (process.env.FM_PI_GROWTH_QUOTA_PROVIDER || "").trim();

// How long a quota reading stays usable. quota-axi reads local credential
// state, so this is only about not spawning it on every settle; the number is
// a cadence, not a threshold, and nothing is decided from a stale reading
// because a stale reading is discarded rather than reused.
const QUOTA_TTL_MS = 5 * 60 * 1000;
const QUOTA_TIMEOUT_MS = 10_000;

// How many settled boundaries a rotation request may be re-issued for before
// this extension stands down. A circuit breaker that nags forever is worse
// than one that gives up loudly: standing down leaves the session exactly as
// it was, which is the safe direction.
const ROTATION_ATTEMPT_LIMIT = 3;

type RotationPhase = "idle" | "capture-requested" | "rotation-dispatched" | "stood-down";

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

export default function activate(pi: ExtensionAPI): void {
  let growth: GrowthState = newGrowthState(nowSeconds());
  let phase: RotationPhase = "idle";
  let attempts = 0;
  let rotations = 0;
  let deciding = false;
  let quota: QuotaPressure = UNKNOWN_QUOTA;
  let quotaReadAt = 0;
  let quotaInFlight = false;
  let provider: string | null = null;

  const isPrimary = (): boolean => lockOwnership(stateDir) === "owned";

  // The home's lock can change hands inside a conversation - bin/fm-lock.sh
  // reclaims it whenever it runs, and ./fm-primary-pi-watch.ts tells the agent
  // to do exactly that - so the answer is cached against the lock file's own
  // contents rather than against the conversation. The settle path costs one
  // file read, the ancestry walk it used to do on every settle is redone only
  // when the recorded owner changes, and a session that becomes the owner
  // later is picked up without waiting for a session boundary. An absent or
  // unreadable lock still resolves toward inert, and is still re-read next
  // time rather than latching.
  let cachedLockPid: string | null = null;
  let ownershipCached = false;
  let primary = false;
  const isPrimaryThisSession = (): boolean => {
    const lockPid = readLockPid(stateDir);
    if (!ownershipCached || lockPid !== cachedLockPid) {
      cachedLockPid = lockPid;
      ownershipCached = true;
      primary = isPrimary();
    }
    return primary;
  };

  // Observational only. It exists so an interrupted rotation is visible after
  // the fact; nothing reads it back into a decision, which is why losing it
  // costs nothing and deleting it is safe. A record identical to the one
  // already on disk is not news, so the signature covers every field the body
  // serializes: the record either changes or is not rewritten, and it never
  // reports a counter it has stopped keeping current. The record lives in the
  // shared home, so only the session that holds the home's lock may write it:
  // a session that does not hold the helm stays inert here too, rather than
  // overwriting the primary conversation's evidence with its own counters.
  let lastRecord = "";
  const writeRecord = (decision: GrowthDecision | null): void => {
    if (!isPrimaryThisSession()) return;
    const signature = [
      phase,
      attempts,
      rotations,
      decision?.level ?? "",
      decision?.reason ?? "",
      growth.turns,
      growth.events,
      growth.compactions,
      growth.assistantMessages,
      growth.cacheReadTokens,
    ].join("|");
    if (signature === lastRecord) return;
    lastRecord = signature;
    try {
      mkdirSync(stateDir, { recursive: true });
      writeFileSync(
        record,
        `${JSON.stringify({
          rotations,
          phase,
          attempts,
          lastLevel: decision?.level ?? null,
          lastReason: decision?.reason ?? null,
          lastAt: new Date().toISOString(),
          turns: growth.turns,
          events: growth.events,
          compactions: growth.compactions,
          assistantMessages: growth.assistantMessages,
          cacheReadTokens: growth.cacheReadTokens,
        })}\n`,
      );
    } catch {
      // A record this extension cannot write never blocks the decision it was
      // describing: the breaker matters, the note about it does not.
    }
  };

  // One bounded quota-axi read. It never blocks a turn and never throws into
  // one: a failed, slow, or unparseable read resolves to undefined, and the
  // caller treats undefined as unknown rather than as pressure.
  const readQuotaAxi = (args: string[]): Promise<unknown> =>
    new Promise((resolve) => {
      let child;
      try {
        child = spawn("quota-axi", args, { stdio: ["ignore", "pipe", "ignore"] });
      } catch {
        resolve(undefined);
        return;
      }
      let out = "";
      const timer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // Already gone.
        }
      }, QUOTA_TIMEOUT_MS);
      // A pending quota read must never hold Pi's event loop open at exit.
      timer.unref?.();
      child.stdout?.on("data", (chunk: Buffer) => {
        // Bounded so a runaway report cannot grow this process.
        if (out.length < 4_000_000) out += chunk.toString("utf8");
      });
      const settle = (value: unknown): void => {
        clearTimeout(timer);
        resolve(value);
      };
      child.on("error", () => settle(undefined));
      child.on("close", (code) => {
        if (code !== 0 || !out.trim()) return settle(undefined);
        try {
          settle(JSON.parse(out));
        } catch {
          settle(undefined);
        }
      });
    });

  // Refresh the quota reading in the background. Two reads: the quota report
  // itself, and the auth report that says which quota-axi provider actually
  // meters this session's Pi provider. Without the second one the first cannot
  // be attributed to this session, and an unattributable reading is discarded
  // rather than applied to whichever provider looks closest.
  const refreshQuota = (): void => {
    // Before the first assistant message there is no provider to attribute a
    // reading to, and caching an unattributable one here would suppress the
    // real read for a whole window.
    if (!provider) return;
    if (quotaInFlight || Date.now() - quotaReadAt < QUOTA_TTL_MS) return;
    quotaInFlight = true;
    const forPi = provider;
    void Promise.all([readQuotaAxi(["--json"]), readQuotaAxi(["auth", "--json"])])
      .then(([report, auth]) => {
        const target = quotaProviderOverride || quotaProviderForPiProvider(auth, forPi);
        quota = target ? quotaPressure(report, target) : UNKNOWN_QUOTA;
      })
      .catch(() => {
        quota = UNKNOWN_QUOTA;
      })
      .finally(() => {
        quotaReadAt = Date.now();
        quotaInFlight = false;
      });
  };

  const notify = (kind: "growth-guard", body: string): boolean => {
    try {
      pi.sendUserMessage(encodeFirstmateOperationalInput(kind, body), { deliverAs: "followUp" });
      return true;
    } catch {
      return false;
    }
  };

  pi.registerCommand("fm-primary-rotate", {
    description: "Replace this primary session's conversation with a fresh one (firstmate growth breaker)",
    handler: async (_args, ctx) => {
      // A refusal or a failure here must leave `phase` somewhere the settled
      // ladder can still act on, so a rotation that does not happen ends at
      // the bounded stand-down rather than leaving the breaker silent for the
      // rest of the conversation. An operator can also invoke this command
      // directly, while the ladder is still idle and no capture was ever
      // requested; demoting only from a phase past idle keeps that case
      // starting at phase one. The lock is re-read rather than taken from the
      // per-session answer: this is the check the replacement itself hangs
      // off, and it is worth one file read.
      const demoteToCapture = (): void => {
        if (phase !== "idle") phase = "capture-requested";
      };
      if (!isPrimary()) {
        demoteToCapture();
        ctx.ui.notify("firstmate: not the primary session for this home; rotation refused", "warning");
        return;
      }
      try {
        // The turn that dispatched this command is still settling. Waiting for
        // idle here is the second half of the never-split-an-action guarantee:
        // the boundary check chose the moment, and this makes sure the moment
        // has actually arrived before the conversation is replaced.
        await ctx.waitForIdle();
        const result = await ctx.newSession();
        if (result.cancelled) {
          // A cancel is an answer, not an unacknowledged request. Re-asking a
          // human who has already spoken is worse than staying quiet, so this
          // ends the ladder for this conversation instead of spending the rest
          // of the budget on a second capture request.
          phase = "stood-down";
          ctx.ui.notify("firstmate: primary session rotation cancelled; the conversation is unchanged", "warning");
          writeRecord(null);
          return;
        }
        rotations += 1;
        writeRecord(null);
        // The replacement's own session_start resets the accumulator and
        // re-arms both supervision extensions; nothing further is needed here.
      } catch {
        demoteToCapture();
        ctx.ui.notify("firstmate: primary session rotation failed; the conversation is unchanged", "warning");
        writeRecord(null);
      }
    },
  });

  pi.on?.("session_start", () => {
    // A replacement conversation starts at zero on every axis. That is what
    // makes a rotation loop structurally impossible rather than merely
    // unlikely: no counter survives into the session a rotation produced.
    growth = newGrowthState(nowSeconds());
    phase = "idle";
    attempts = 0;
    ownershipCached = false;
    primary = false;
    lastRecord = "";
  });

  pi.on?.("session_compact", () => {
    growth = recordCompaction(growth);
  });

  pi.on?.("message_end", (event) => {
    const message = (event as {
      message?: {
        role?: string;
        provider?: string;
        usage?: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number };
      };
    }).message;
    const role = message?.role;
    if (role === "assistant") {
      if (typeof message?.provider === "string") provider = message.provider;
      growth = recordAssistantMessage(growth, message?.usage);
      return;
    }
    if (role === "user") {
      growth = recordTurn(growth);
      return;
    }
    // Coarse class only. The role is the whole classification: no tool name,
    // no argument, and no message text is read here or anywhere in this file.
    growth = recordEvent(growth, role === "toolResult" ? "toolResult" : "otherMessage");
  });

  pi.on("agent_settled", async (_event, ctx: ExtensionContext) => {
    if (!thresholds.enabled) return;
    // Re-entrancy guard: this handler sends messages, and those messages end
    // in another settle.
    if (deciding) return;
    if (!isPrimaryThisSession()) return;

    deciding = true;
    try {
      refreshQuota();
      const decision = growthDecision(growth, thresholds, quota);

      if (decision.level === "hard") {
        await handleHard(ctx, decision);
        return;
      }

      if (decision.level === "soft" && decision.reason) {
        const reason = decision.reason as SoftReason;
        // Marked as delivered BEFORE sending, so a send that fails halfway
        // cannot turn one warning into a warning on every future turn.
        growth = recordNotified(growth, reason);
        const advice = decision.modelChangeAdvice
          ? "\n\nA different model may be the right answer. This is a recommendation only: firstmate chooses the destination through its quota-array-dispatch skill, which applies the eligibility gates. Nothing here has changed the model, and no work has been routed anywhere."
          : "";
        notify(
          "growth-guard",
          `PRIMARY SESSION GROWTH WARNING - ${decision.detail}\n\n` +
            "Nothing has been changed and no action is required this turn. " +
            "Carry on; this is one notice, not a repeating one." +
            advice,
        );
        writeRecord(decision);
        return;
      }

      writeRecord(decision);
    } finally {
      deciding = false;
    }
  });

  async function handleHard(ctx: ExtensionContext, decision: GrowthDecision): Promise<void> {
    if (phase === "stood-down") {
      writeRecord(decision);
      return;
    }

    // A queued wake or a non-idle context means the boundary this handler was
    // called at is not the quiet moment it looked like. Deferring costs one
    // settle; rotating anyway could discard a wake this session was about to
    // handle.
    if (!ctx.isIdle() || ctx.hasPendingMessages()) {
      writeRecord(decision);
      return;
    }

    attempts += 1;
    if (attempts > ROTATION_ATTEMPT_LIMIT) {
      phase = "stood-down";
      process.stderr.write(
        `${growthLogLine(decision)} - stood down after ${ROTATION_ATTEMPT_LIMIT} attempts; the conversation is unchanged\n`,
      );
      writeRecord(decision);
      return;
    }

    // A dispatch that produced a replacement never reaches here at all: the
    // replacement's session_start resets the phase. Still being dispatched at
    // a later settled boundary therefore means the request was not acted on,
    // so it keeps spending the attempt budget above and ends at that loud
    // stand-down rather than going quiet forever. It does not re-dispatch:
    // one unacknowledged request in flight is enough.
    if (phase === "rotation-dispatched") {
      writeRecord(decision);
      return;
    }

    if (phase === "idle") {
      // Phase one: ask for durable knowledge capture and say plainly what
      // happens next. The capture is the agent's own work in its own words,
      // which is the point - this extension cannot write what the session
      // learned, only make room for it to be written before it is lost.
      process.stderr.write(`${growthLogLine(decision)}\n`);
      const requested = notify(
        "growth-guard",
        `PRIMARY SESSION ROTATION - ${decision.detail}\n\n` +
          "This conversation has outgrown its window and now costs more to re-send than it is worth. " +
          "Capture durable knowledge NOW with /stow: file anything this session learned, and persist the open work you are holding. " +
          "Do not start new work in this conversation.\n\n" +
          "When that finishes, this conversation is replaced with a fresh one automatically. " +
          "Supervision and the fleet records carry across unchanged, and the replacement re-runs session start before it acts, " +
          "so nothing durable is lost - only the transcript.",
      );
      // Only advance once the request is actually on its way. A send that
      // failed must be retried as phase one, not silently skipped into a
      // rotation the session was never told about.
      if (requested) phase = "capture-requested";
      writeRecord(decision);
      return;
    }

    // Phase two: the capture turn requested above has now settled, so replace
    // the conversation. Dispatching the registered command is what reaches Pi's
    // session-control surface, which is only available to a command handler.
    phase = "rotation-dispatched";
    writeRecord(decision);
    try {
      pi.sendUserMessage("/fm-primary-rotate", { deliverAs: "followUp", expandPromptTemplates: true });
    } catch {
      phase = "capture-requested";
    }
  }
}
