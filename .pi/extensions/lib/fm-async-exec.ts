import { spawn } from "node:child_process";

// Pi runs extensions, their tools, and their event handlers on the single
// JavaScript thread that also draws the TUI and reads the keyboard, and it
// starts no worker for them. A spawnSync call from an extension therefore
// stops repaint and key echo for the child's whole lifetime, which a
// supervision outcome made visible as a subsecond freeze every time one
// arrived (docs/pi-supervision-branch.md "Off-thread delivery").
//
// This is the one owner of that replacement: the status, UTF-8 stdout, and
// UTF-8 stderr fields these callers consumed from spawnSync, produced by an
// awaited spawn so the event loop keeps running while the child does. Callers
// keep their own ordering guarantees - awaiting here
// yields the thread, so anything that must not interleave belongs behind a
// serializing queue in the caller.
//
// Like spawnSync, a spawn that never starts and a child killed by a signal
// both report a null status rather than throwing, so a caller's existing
// "status !== 0" failure branch keeps its meaning unchanged.

export interface AsyncExecResult {
  /** Exit code, or null when the child was signalled or never started. */
  status: number | null;
  stdout: string;
  stderr: string;
}

export interface AsyncExecOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Written to the child's stdin, which is closed either way. */
  input?: string;
  /**
   * Upper bound on each captured output stream, mirroring spawnSync's
   * maxBuffer. Defaults to 1 MiB.
   */
  maxBuffer?: number;
  /**
   * Upper bound on the child's whole lifetime, mirroring spawnSync's timeout:
   * a child still running at the deadline is killed and reported with a null
   * status, the same answer a signalled child already gives. Unbounded when
   * omitted, so a caller that must not wait forever has to say so.
   */
  timeoutMs?: number;
}

const DEFAULT_MAX_BUFFER = 1024 * 1024;

export function runCommandAsync(
  command: string,
  args: readonly string[],
  options: AsyncExecOptions = {},
): Promise<AsyncExecResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    const maxBuffer = options.maxBuffer ?? DEFAULT_MAX_BUFFER;
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const finish = (status: number | null, detail = ""): void => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({ status, stdout, stderr: detail ? `${stderr}${detail}` : stderr });
    };
    let child;
    // A bounded child leads its own process group, so a wedged GRANDCHILD
    // (a `ps` liveness fallback, say) cannot outlive the kill still holding
    // the inherited stdout/stderr pipes: the whole group goes. Only a caller
    // that asked for a bound gets that group - an unbounded child keeps the
    // caller's group, where a group-directed signal still reaches it. Windows
    // has no process groups to lead and would give a detached child its own
    // console, so it keeps the plain spawn and the direct kill.
    const bounded = options.timeoutMs !== undefined && options.timeoutMs > 0;
    const ownsGroup = bounded && process.platform !== "win32";
    try {
      child = spawn(command, [...args], {
        cwd: options.cwd,
        env: options.env,
        stdio: ["pipe", "pipe", "pipe"],
        detached: ownsGroup,
      });
    } catch (error) {
      finish(null, error instanceof Error ? error.message : String(error));
      return;
    }
    const kill = (signal?: NodeJS.Signals): void => {
      if (ownsGroup && child.pid !== undefined) {
        try {
          process.kill(-child.pid, signal ?? "SIGTERM");
          return;
        } catch {
          // The group is already gone, or was never ours to signal.
        }
      }
      child.kill(signal);
    };
    if (bounded) {
      timer = setTimeout(() => {
        kill("SIGKILL");
        finish(null, `timed out after ${options.timeoutMs}ms`);
      }, options.timeoutMs);
      timer.unref?.();
    }
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stdoutBytes + bytes > maxBuffer) {
        kill();
        finish(null, `stdout exceeded ${maxBuffer} bytes`);
        return;
      }
      stdout += chunk;
      stdoutBytes += bytes;
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stderrBytes + bytes > maxBuffer) {
        kill();
        finish(null, `stderr exceeded ${maxBuffer} bytes`);
        return;
      }
      stderr += chunk;
      stderrBytes += bytes;
    });
    // "close" rather than "exit": it fires once the captured stdio streams are
    // drained, so no output is lost the way an early "exit" would lose it.
    child.on("close", (code) => finish(code));
    child.on("error", (error: Error) => finish(null, error.message));
    if (child.stdin) {
      // A child that exits before reading stdin makes the write fail with
      // EPIPE, which is its answer, not this helper's failure.
      child.stdin.on("error", () => {});
      child.stdin.end(options.input ?? "");
    }
  });
}
