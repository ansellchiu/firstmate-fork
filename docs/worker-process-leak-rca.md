# Root-cause analysis: the 2026-09-30 worker process leak

On 2026-09-30 at 22:05 SGT a ship worker (`fm-ci-suite-green-s1`, repairing the public fork's test suite) started a load probe under `/tmp/hangprobe`.
Twelve parallel shell loops never exited.
They reparented to `launchd` (PID 1), burned twelve cores for 1h06m, and, with the rest of the fleet backing up behind them, this Mac's load average reached 237.
Every lane on the machine was starved: watcher cycles exited non-zero and restarted, wake handling timed out behind a lock, and the worker's own suite assertions flaked.
The worker reaped all twelve by pid and removed `/tmp/hangprobe`, and load recovered.
Nothing in the fleet detected it; supervision only noticed because a separate run happened to report the load.

This document answers what the probe was, why its children outlived it, why nothing caught it, what made it harmful, and what was changed.

## 1. What the probe was, and why twelve shells

The probe was recovered verbatim from the supervision branch transcript (`state/branch-session/2026-09-30T15-12-48-841Z_*.jsonl`); it is not reconstructed:

```sh
cd /tmp/hangprobe && for j in 1 2 3 4 5 6 7 8 9 10 11 12; do (while :; do :; done) & done >/dev/null 2>&1
loadpids=$(jobs -p)
for i in 1 2 3 4 5 6; do
  : >attempts
  bash -c '
    cd /Users/achiu/.treehouse/firstmate-4122da/2/firstmate
    eval "$(sed -n "93,150p" tests/fm-calm-pi-extension.test.sh)"
    TMP_ROOT=/tmp/hangprobe FM_FAKE_CHROME_ATTEMPTS=/tmp/hangprobe/attempts FM_CHROME_RENDER_WAIT_TICKS=3 \
      render_export_dom /tmp/hangprobe/chrome-hang /tmp/hangprobe/src.html /tmp/hangprobe/out.html 9.9.9 >/dev/null 2>&1
  '
  printf "loaded run %s attempts=%s\n" "$i" "$(wc -l < attempts | tr -d ' ')"
done
kill $loadpids 2>/dev/null; echo "load stopped"
```

The purpose is legible from the command itself: the worker was chasing a timing-dependent assertion in `tests/fm-calm-pi-extension.test.sh`, where `render_export_dom` retries a hanging fake Chrome for a bounded number of wait ticks and the test counts the attempts.
It wanted to know whether that retry count was load-sensitive, so it saturated the machine and re-ran the same function six times, comparing `attempts` each round.
That is a reasonable question to ask about a flaky timing assertion.

The twelve is the core count: `sysctl -n hw.ncpu` reports 12 on this machine, and the probe started exactly one unbounded spinner per core, which is the standard way to make a machine fully CPU-bound.
So the deliberate design target was "fully saturated", and nothing about the measurement needed the spinners to persist beyond the six runs.
No finding is needed against the intent; the defect is entirely in how the load was bounded.

## 2. Why the shells outlived the command that started them

The cleanup is the trailing `kill $loadpids` on the last line: it runs only if the launching shell reaches that line.
It never did.
The probe's own output froze at 22:05 (`/tmp/hangprobe/attempts` mtime), which is when the launching shell stopped - the harness ends a tool call by killing the shell it spawned, and a Claude Code Bash call is hard-capped at ten minutes.
Once the parent is gone, each `( ... ) &` subshell is orphaned, reparented to PID 1, and spins forever, because `while :; do :; done` has no deadline of its own.

Reproduced on the same machine with the same shape (two spinners instead of twelve, each self-capped at 20s so the reproduction cannot itself leak):

```
$ /bin/zsh leak.zsh &        # for j in 1 2; do ( spin ) & done; loadpids=$(jobs -p); sleep 30; kill $loadpids
--- parent 5923, children before kill:
 5923  5915  5915   0.0 /bin/zsh leak.zsh
 5929  5923  5915  85.8 /bin/zsh leak.zsh
 5930  5923  5915  84.9 /bin/zsh leak.zsh
 5932  5923  5915   0.0 sleep 30
$ kill -TERM 5923            # stands in for the harness ending the tool call
--- after parent death:
 5929     1  5915  91.8       00:04 /bin/zsh leak.zsh
 5930     1  5915  92.2       00:04 /bin/zsh leak.zsh
```

That is the incident's signature exactly: PPID 1, ~90% CPU each, and a command line that still shows the launching wrapper - which is why the leak read in `ps` as "twelve orphaned shell wrappers".

**The missing primitive is a self-bound on the child.**
Two weaker candidates were tested and both fail under the incident's real conditions:

- A `trap` that reaps the recorded pids does not fire promptly while the shell blocks in a foreground command. With `trap 'reap; exit 143' TERM` and the shell inside `sleep 30`, the TERM was accepted and queued, and the reap only ran ~30s later when the foreground command returned. A SIGKILL, or destruction of the tool call's shell, skips it entirely.
- A process-group kill by the parent has the same dependency: the parent must still be alive to send it.

A deadline inside the child needs no live parent and no signal delivery at all.
In the reproduction above, the orphans died on their own 20s deadline while nothing was left to reap them:

```
$ ps -eo pid,ppid,%cpu,etime,command | grep -E "zsh (leak|reaped)"
(all reproduction processes gone - self-bound deadline held)
```

This repo already owns that primitive: `fm_run_timed` in `bin/fm-timeout-lib.sh` runs a command under a hard bound and terminates the whole process group on expiry.
The probe hand-rolled background work instead of using it.

## 3. Why nothing caught it for 66 minutes

Every detector that should have noticed is scoped to one crew's pane, and the leak was machine-wide.

| Detector | Owner | Why it was blind |
| --- | --- | --- |
| Busy-state record | `bin/fm-busy-event.sh`, `bin/fm-busy-lib.sh` | Written from the harness's own hook and pane events for one task. The orphans had no harness, no hooks, and no task binding, so they produced no busy event; the worker's own record stayed correctly `busy`. |
| Turn-end record | `state/<id>.turn-ended` | Touched by the worker's turn-end hook. The worker kept completing turns normally throughout, so this record was healthy - and accurate. |
| Stale / wedge detector | `bin/fm-watch.sh` | Reads pane hash staleness for one window. It did fire - five `stale: default:wAF:p2 (possible wedge, escalation 1)` rows in that hour - and was correctly dismissed: the pane was churning and the crew was provably working, which is the absorb-only-when-provably-working contract working as designed. A load starving every lane is not what that detector measures. |
| Wake drain | `bin/fm-wake-drain.sh` | A victim, not a detector: under the load, presentation burned its whole 10s bound and the unbounded acknowledgement path blocked behind a live lock holder. That is tracked separately as `fm-wake-drain-lock-bound-s1` and is out of scope here. |

**Finding: nothing in the fleet watched machine load at all.**
Before this change the only load reading anywhere under `bin/` was `fm_lint_load_average` in `bin/fm-lint.sh:707`, which records a load number as lint telemetry and never compares it to anything.
No supervision path read load average, core count, aggregate CPU, or orphaned-process count.
So the class of failure "a worker starves the whole machine" had no detector of any kind, and the 66 minutes were bounded only by when a human happened to look.

## 4. What made it harmful rather than merely wasteful

Twelve unbounded spinners on a 12-core machine leave no core for anything else.
They add only about 12 to the load average themselves: one runnable process each.
The recorded 235-267 came from everything else backing up behind them - watcher cycles, wake handling, and the worker's own nine-shard suite all queued for CPU that the spinners held.
So load average measures the aftermath of a leak, not the leak: a fresh twelve-spinner leak on top of an ordinary 19-28 baseline reads around 30-40, with every lane already starved.
Beyond the wasted hour of CPU, the concrete downstream damage was:

- Watcher cycles exited non-zero and restarted, so fleet supervision itself was degraded during the window.
- Wake handling timed out behind the status-presentation lock, so events queued instead of reaching firstmate.
- The worker's own nine-shard suite run produced flaky assertions, which the worker recorded on its status log - so the load corrupted the very measurement the probe was serving, and the shard-1 run had to be discarded and re-run.

A load probe that had been bounded to its six measurement runs would have cost about a minute of saturation and none of this.

## 5. Root cause

The mechanism gap is real but narrow: the probe used a trailing `kill` where only a self-bound works, in a harness that can end a tool call at any moment, with the bounded-execution primitive already available in the repo and unused.
Underneath it, the cause is worker judgement - an unbounded `while :; do :; done` was written on the assumption that the launching shell would live to clean up.

The fleet-level cause is different and sharper: **there was no detector for a leaked process or for machine-wide resource starvation.**
The leak's cost was not that it happened, but that it ran for 66 minutes while every durable record read healthy.

The fix is proportionate to both, and small on each side.

## 6. The fix, and the alternatives it was chosen over

Three candidates were evaluated.

**A. A worker-contract rule in the generated brief (adopted).**
`bin/fm-brief.sh` now emits, in every ship and scout brief:

> 9. Anything you start in the background - a load or hang probe, a watch loop, a server, a parallel sweep - must bound ITSELF: an explicit deadline inside the child, or `fm_run_timed` from `<root>/bin/fm-timeout-lib.sh`. A trailing `kill` or a trap is NOT a bound: your shell can be killed mid-command, the trailing line never runs, a trap queued behind a blocking foreground command never fires, and the children then reparent to init and burn CPU until a human notices. Nothing you start may outlive the tool call that started it; confirm with `ps -eo pid,ppid,%cpu,etime,command` before you move on.

Catches: the cause, at the only place it originates, for every future worker - and it names the primitive so the correct shape is cheaper to write than the broken one.
Misses: a worker that ignores it, and any leak from a path that is not a brief-carrying worker. A rule prevents; it does not detect.

**B. A firstmate-side leak guard, with a load backstop (adopted).**
`bin/fm-watch.sh` checks two machine-wide signals once per poll cycle, before any per-task read.
Each queues one `check:` wake per episode, names the three hungriest processes with their parent pids, and re-arms only after its condition clears.

- **Primary: an orphaned shell burning CPU.** A process whose parent is PID 1, whose command basename is a shell (`sh`, `bash`, `zsh`, `dash`, `ksh`), and whose CPU is at or above 50% is recorded in `state/.orphan-shells`. When the same pid is seen that way on two consecutive polls, the watcher queues `check: leaked worker probe - orphaned shell pid ...`. This is the leak's own signature from section 2, so it fires within about two polls whatever the load is. It is narrowed to shells because PID 1 alone is not a signal: on this machine Google Chrome and `corespotlightd` both run under `launchd` at ~97% CPU legitimately, while an orphaned shell spinning has no legitimate cause. The two-poll requirement keeps a shell that reparents for a moment during ordinary teardown from alarming. Its episode is per pid: `state/.orphan-alarm` lists the pids already reported, pruned to those still hot, so an earlier orphan left running cannot mask a fresh leak.
- **Backstop: sustained machine overload.** When both the one- and five-minute load averages are at or past `cores x FM_LOAD_ALARM_MULTIPLE` (default 4) for `FM_LOAD_ALARM_POLLS` consecutive polls (default 12, about three minutes at the default poll), it queues `check: machine load ...`. It catches a runaway that is not an orphaned shell, but only once other work has piled up behind it (section 4).

It surfaces and attributes; it never kills anything, because reaping another process is destructive and belongs to the captain - the non-destructive route is to steer the owning worker, as supervision did during the incident.

Catches: the incident's exact shape within about two polls, and runaway load of any other shape as a backstop.
Misses: prevention entirely; a leaked non-shell process until it drives the load past the backstop; and precise ownership - it names pids, not the task that spawned them, so the supervisor still has to map a pid to an owner.
Threshold calibration: on this 12-core machine the backstop line is 48. A real watcher-suite run measured `{ 21.97 18.85 27.53 }` while this change was being validated, and sustained 17-27 was seen during an ordinary nine-shard suite run, so `cores x 2` (24) would fire on healthy work. The backstop therefore stays at 4x, which a fresh twelve-spinner leak (about 30-40) does not reach - the incident's 235-267 crossed it only because the fleet had backed up. That gap is why the orphaned-shell signal is the primary detector and the load threshold only a backstop.
Costs: one `sysctl`/`/proc` read and one `ps` per poll, and four small marker files.

**C. A harness launch-wrapper change (rejected).**
Launching each worker in its own process group and sweeping that group would catch orphans at task end.
It was rejected on evidence, not taste: the reproduction above shows orphans keep the launching shell's PGID (`5915`), and `bin/fm-teardown.sh:2017` already does exactly this process-group kill.
The mechanism was therefore already in place during the incident and did not help, because the task was still live - nothing tore it down for another day.
A wrapper change addresses the end of a task; this leak did its damage in the middle of one.

A and B are each small, and they cover different halves of the failure: A removes the cause, B removes the 66 minutes.
Neither alone was sufficient - a rule leaves the next unnoticed leak unnoticed, and a guard leaves the probe shape in place.

Deliberately not built: any new daemon, watch service, per-process accounting, or automatic reaping.

## 7. Evidence

- Probe command, verbatim: `state/branch-session/2026-09-30T15-12-48-841Z_*.jsonl` in the operating home.
- Incident record: `state/fm-ci-suite-green-s1.status` line 6, the steer in `state/fm-ci-suite-green-s1.inbox/handled/002.msg`, and `data/learnings.md` (2026-09-30 entries).
- Leak mechanism reproduced, and the self-bound demonstrated holding without a live parent: section 2.
- Detection blindness: `bin/fm-lint.sh:707` was the only load reading under `bin/` before this change.
- Load backstop attribution on the reproduction: with two orphaned spinners from section 2 live on the machine (PPID 1, ~85% CPU each) and only the load number faked, a real watcher cycle of the first version of the backstop produced

  ```
  check: machine load 99999 (5m 99999) on 12 cores is past 48 - every lane on this machine is starved, including this watcher and any running suite.
  Hungriest: pid 1280 (ppid 1, 97.5% cpu) .../corespotlightd; pid 1398 (ppid 1, 97.4% cpu) /Applications/Google Chrome.app/Contents/MacOS/Google Chrome; pid 44467 (ppid 1, 82.3% cpu) /bin/zsh.
  An orphaned shell there (ppid 1, a zsh or bash burning CPU) is a leaked worker probe: find the owning task and steer that worker to reap its own processes (killing them is destructive and needs the captain).
  ```

  `pid 44467 ... /bin/zsh` is the reproduction's own orphan, so the attribution points at the leak. The same list also shows why PID 1 alone is not a leak signal: Chrome and `corespotlightd` are the two hungriest, both legitimately under `launchd`. That is the shape the orphaned-shell signal now matches directly, without needing the load at all.
- Fix under test: `tests/fm-watch-triage.test.sh` drives a real watcher with a faked process sample (`FM_FAKE_PROCS`) and load (`FM_FAKE_LOADAVG`). `test_orphaned_shell_alarm_surfaces_once_then_rearms`, `test_orphaned_shell_single_sample_is_not_an_alarm`, and `test_hot_orphaned_non_shell_is_not_an_alarm` assert the orphaned-shell signal wakes once per episode only after two polls, names exactly the orphaned shell, forgets gone pids, re-arms, and ignores hot PID-1 apps and parented shells. `test_machine_load_alarm_surfaces_once_then_rearms`, `test_machine_load_spike_is_not_an_alarm`, and `test_machine_load_guard_can_be_disabled` assert the backstop waits out its streak, wakes once per episode with process attribution, ignores a one-minute spike, re-arms on recovery, and honours the `off` switch; `tests/fm-brief.test.sh` (`test_background_process_bound_rule`) asserts both generated brief shapes carry the rule.
