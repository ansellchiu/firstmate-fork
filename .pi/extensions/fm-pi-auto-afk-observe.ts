// Default-off, observe-only detector for a Pi-local idle period.
//
// CONSENT BOUNDARY - read before extending this file.
//
// This extension OBSERVES. It never enters the away posture. It does not write
// state/.afk-contract or state/.afk, does not call bin/fm-afk-launch.sh or
// bin/fm-afk-contract.sh, does not send a model message, and does not invoke
// /afk. The away-mode entry contract is unchanged by this file: the posture is
// written only after the captain hears a read-back of their own away words and
// confirms it (bin/fm-afk-contract.sh, .agents/skills/afk/SKILL.md).
//
// The reason is not caution about the mechanism, it is what the signal means.
// Pi reports that input arrived through the interactive terminal path; it does
// not report that a human typed it, and it cannot see the captain working in
// another window. Timer expiry is therefore evidence of ABSENCE, and the entry
// contract requires CONSENT. Absence is not consent, so expiry here records an
// observation and nothing else.
//
// Turning this into automatic entry is a captain product decision that must
// first add an explicit advance-consent grant and a new validated transition in
// the posture's record owner. Do not close that gap from inside this file.
// data/fm-auto-afk-idle-detect-s1/report.md holds the full investigation, the
// Pi-source evidence for the signals used below, and the acceptance tests.
// docs/configuration.md owns the config/pi-auto-afk contract.

import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { lockOwnership } from "./lib/fm-primary-session-lock.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || resolve(fmHome, "state");
const config = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");

const STATUS_KEY = "firstmate-auto-afk";
const OBSERVATION_LOG = resolve(state, ".pi-auto-afk-observations");

/** Production thresholds from the investigation; the overrides exist for tests. */
function seconds(variable: string, fallback: number): number {
  const raw = Number(process.env[variable]);
  return Number.isFinite(raw) && raw > 0 ? raw : fallback;
}
const idleSeconds = seconds("FM_PI_AUTO_AFK_IDLE_SECONDS", 1740);
const countdownSeconds = seconds("FM_PI_AUTO_AFK_COUNTDOWN_SECONDS", 60);

/** Away posture, legacy flag, or an unfinished return: stand down for all three. */
function awayStateExists(): boolean {
  return (
    existsSync(resolve(state, ".afk-contract")) ||
    existsSync(resolve(state, ".afk")) ||
    existsSync(resolve(state, ".afk-return-catchup"))
  );
}

// A secondmate is deliberately idle with no captain in its pane, so idleness
// there means nothing. Lock ownership only separates the helm-owning primary
// from a worker in another worktree; it does not separate main from a
// secondmate primary, which is why both checks are required.
function enabled(ctx: ExtensionContext): boolean {
  if (ctx.mode !== "tui") return false;
  if (existsSync(resolve(fmHome, ".fm-secondmate-home"))) return false;
  if (lockOwnership(state) !== "owned") return false;
  if (awayStateExists()) return false;
  try {
    return readFileSync(resolve(config, "pi-auto-afk"), "utf8").trim() === "observe";
  } catch {
    return false;
  }
}

export default function extension(pi: ExtensionAPI): void {
  // Timers are wakeups, never the authority on elapsed time: each callback
  // recomputes against an absolute deadline so event-loop delay, a slow
  // subprocess in another extension, or laptop sleep cannot make the countdown
  // lie. `revision` invalidates every callback captured before a reset.
  let revision = 0;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let countdownTimer: ReturnType<typeof setInterval> | undefined;
  let expiryTimer: ReturnType<typeof setTimeout> | undefined;
  let countdownDueAt = 0;
  let removeTerminalInput: (() => void) | undefined;
  // Whether OUR status key is currently set. An off home must not touch the
  // status bar at all, not even to clear a key it never wrote, so every clear
  // routes through here and no-ops when there is nothing of ours to clear.
  let statusShown = false;

  function showStatus(ctx: ExtensionContext, text: string): void {
    ctx.ui.setStatus(STATUS_KEY, text);
    statusShown = true;
  }

  function clearStatus(ctx: ExtensionContext): void {
    if (!statusShown) return;
    ctx.ui.setStatus(STATUS_KEY, undefined);
    statusShown = false;
  }

  function record(event: string, detail = ""): void {
    try {
      appendFileSync(
        OBSERVATION_LOG,
        `${new Date().toISOString()}\tobserve\t${event}\tidle=${idleSeconds}\tcountdown=${countdownSeconds}${detail ? `\t${detail}` : ""}\n`,
      );
    } catch {
      // An unwritable log must not break the captain's session: this feature
      // observes, so losing an observation is the correct failure.
    }
  }

  function clearTimers(): void {
    if (idleTimer) clearTimeout(idleTimer);
    if (countdownTimer) clearInterval(countdownTimer);
    if (expiryTimer) clearTimeout(expiryTimer);
    idleTimer = undefined;
    countdownTimer = undefined;
    expiryTimer = undefined;
  }

  function standDown(ctx: ExtensionContext): void {
    revision += 1;
    clearTimers();
    countdownDueAt = 0;
    clearStatus(ctx);
  }

  function tick(ctx: ExtensionContext, generation: number): void {
    if (generation !== revision) return;
    if (!enabled(ctx)) {
      standDown(ctx);
      return;
    }
    const remaining = Math.ceil((countdownDueAt - Date.now()) / 1000);
    if (remaining > 0) {
      showStatus(ctx, `Auto-AFK in ${remaining}s - any Pi input cancels; /afk enters now`);
      return;
    }
    // Expiry. Observe only: clear the UI, say what WOULD have happened, and
    // record it. Nothing here enters or proposes the away posture.
    standDown(ctx);
    record("would-enter");
    ctx.ui.notify("Auto-AFK would enter now (observe mode; no away posture entered)", "info");
  }

  function arm(ctx: ExtensionContext): void {
    revision += 1;
    clearTimers();
    countdownDueAt = 0;
    clearStatus(ctx);
    if (!enabled(ctx)) return;
    const generation = revision;
    idleTimer = setTimeout(() => {
      if (generation !== revision) return;
      if (!enabled(ctx)) {
        standDown(ctx);
        return;
      }
      countdownDueAt = Date.now() + countdownSeconds * 1000;
      record("countdown-start");
      // The interval only repaints the remaining seconds; the deadline gets its
      // own wakeup so the recorded observation carries the real expiry time
      // rather than whenever the next repaint happened to land. tick() is
      // idempotent, so whichever arrives first is the one that counts.
      countdownTimer = setInterval(() => tick(ctx, generation), 1000);
      expiryTimer = setTimeout(() => tick(ctx, generation), countdownSeconds * 1000);
      // Unreferenced so a pending observation can never be the reason Pi's
      // process stays alive; session_shutdown clears them on the ordinary path.
      countdownTimer.unref();
      expiryTimer.unref();
      tick(ctx, generation);
    }, idleSeconds * 1000);
    idleTimer.unref();
  }

  /** Observed Pi-local interaction: reset synchronously, before returning. */
  function observedInput(ctx: ExtensionContext): void {
    if (countdownDueAt > 0) {
      record("cancelled", `remaining=${Math.max(0, Math.ceil((countdownDueAt - Date.now()) / 1000))}`);
    }
    arm(ctx);
  }

  pi.on("session_start", (_event, ctx) => {
    removeTerminalInput?.();
    removeTerminalInput = undefined;
    // A replacement session starts a fresh observation generation; no deadline
    // is persisted across reload, so stale state cannot trigger a countdown.
    arm(ctx);
    if (!enabled(ctx)) return;
    removeTerminalInput = ctx.ui.onTerminalInput((data) => {
      // Every nonempty byte counts, including terminal protocol replies and
      // anything written to the PTY by another process. Cancelling on
      // ambiguous activity is the safe direction. The data is returned
      // unchanged so this listener never alters what Pi sees.
      if (data.length > 0) observedInput(ctx);
      return undefined;
    });
  });

  // Backup for a submitted message when the raw listener is unavailable.
  // `extension` is Firstmate's own pi.sendUserMessage traffic (watcher wakes,
  // growth, turn-end follow-ups) and must never count as the captain. `rpc`
  // cannot say whether its caller is a human, so it is not counted either.
  pi.on("input", (event, ctx) => {
    if (event.source === "interactive") observedInput(ctx);
    return undefined;
  });

  pi.on("session_shutdown", (_event, ctx) => {
    removeTerminalInput?.();
    removeTerminalInput = undefined;
    standDown(ctx);
  });
}
