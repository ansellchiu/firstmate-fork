// Whether THIS Pi process is the primary firstmate session for a home.
//
// Everything under .pi/extensions auto-loads for any Pi session started in a
// firstmate checkout, including a crewmate working in a disposable task
// worktree of the firstmate repo. Extensions that act on the fleet must
// therefore be able to tell "I am the session that took the helm" from "I am a
// worker that happens to be inside this repo", and the home's session lock is
// the only signal that answers it structurally: exactly one session holds it,
// and bin/fm-lock.sh writes the owning harness pid into it.
//
// This is the single owner of that determination. The callers
// (.pi/extensions/fm-primary-pi-watch.ts, .pi/extensions/fm-primary-growth.ts)
// decide what to do with the answer; they must not re-derive it.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

/**
 * "owned"   this process, or an ancestor of it, holds the home's session lock.
 * "other"   a different live process holds it.
 * "missing" no readable lock, or its recorded owner is gone.
 */
export type LockOwnership = "owned" | "missing" | "other";

/** Ancestors to walk before giving up. A harness sits a few levels above node. */
const MAX_ANCESTORS = 8;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

/** Whether a recorded pid is still a live process. Exported because callers
 * that reason about a recorded owner need the same liveness test the ownership
 * walk uses, and two copies of it would be free to disagree. */
export function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * The pid recorded in `<stateDir>/.lock`, or null when there is nothing
 * readable there. Exported because a caller that caches an ownership answer
 * needs a cheap way to notice the recorded owner has changed - one file read,
 * no ancestry walk - rather than caching across a hand-over it never saw.
 */
export function readLockPid(stateDir: string): string | null {
  try {
    return readFileSync(`${stateDir}/.lock`, "utf8").trim();
  } catch {
    return null;
  }
}

/**
 * Read ownership of `<stateDir>/.lock`. An unreadable or malformed lock is
 * never reported as owned: a caller that acts on the fleet must fail toward
 * doing nothing, not toward acting on someone else's home.
 */
export function lockOwnership(stateDir: string): LockOwnership {
  const lockPid = readLockPid(stateDir);
  if (lockPid === null) return "missing";
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < MAX_ANCESTORS; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}
