---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates, after checking the public upstream firstmate repo.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Checks canonical public upstream first, reconciles any genuinely new public commits through an isolated branch and a private pull request, then updates this firstmate repo's default branch and every local or remote secondmate through its guarded convergence path (never forced, never disruptive), re-reads AGENTS.md, and restarts every live second mate through the persist-gated restart, with a fallback re-read nudge only where a restart cannot be proven.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches the private default branch and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.

This home has two remotes with different jobs, and the whole skill turns on the distinction:

- `origin` is the **private** repo, and the only push and pull-request target.
- `upstream` is the **public canonical** Firstmate repo, **fetch only**.

"Origin is current" therefore does not mean "we have everything public upstream published".
Every invocation checks upstream first, and only then updates the fleet from origin.
`bin/fm-upstream.sh` is the one owner of that check and of the reconciliation mechanics; read its header for exact flags and output lines.
`bin/fm-private-divergence.sh` owns the inventory of intentional private divergence that the check consults.

Pulling the files is only half of it.
A running agent holds `AGENTS.md` and every skill it has already loaded frozen from the moment it launched, and no verified harness offers a reload, so new bytes on disk change nothing for it until it starts a fresh conversation.
A re-read cannot substitute: it appends a second copy of the mate's own job description with no defined precedence, and it cannot reach a skill that is already loaded.
Replacing the agent is also the only thing that re-resolves the launch-time wiring - turn-end hooks, harness flags, per-harness feature switches - which the mate froze when it started and which nothing on disk describes.

That is why **every live second mate is restarted after a successful update, including one that was already on the target commit.**
Launch-time wiring is not derivable from a file diff, so an unchanged tracked surface is not evidence the running agent is already on the current behavior.
The only live mates that do not restart are the ones whose home the update pass had to skip, and the ones whose runtime cannot prove a restart; the updater keeps both cases honest and neither is reported as a reload.

**One-time rollout note:** the update that carries this change is still executed by the previous release, which restarts only the mates whose `AGENTS.md` or `.agents/skills/` moved on that pass. After it completes, run `bin/fm-secondmate-restart.sh <fm-id>...` once with every live second mate ID, not only the ones that release named; later updates follow the normal flow below.

The primary update is fast-forward only, while each secondmate uses the same guarded convergence path plus one narrow recovery for squash-merged local history.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, and never stashes.
A clean secondmate divergence advances with `reset --keep` only when a three-way tree proof shows its complete local result is already present at the target, which recognizes squash-merged contributions without discarding unique content.
Every other dirty, diverged, offline, or wrong-branch target is skipped and reported, and a genuine divergence leaves a durable `state/.secondmate-update-reconcile/<id>.pending` record that future bootstrap and update passes surface until convergence clears it.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## 1. Check public upstream

```sh
bin/fm-upstream.sh check
```

It reports the comparison's answer on its `upstream-status:` line - the three real classifications are reported separately - and you act on exactly that one line:

| `upstream-status:` | Meaning | Do |
| --- | --- | --- |
| `current` | Public upstream has no commit origin lacks | Go to step 3 |
| `contained` | Every upstream commit origin lacks is already patch-equivalent to work origin carries | Go to step 3, and tell the captain nothing needed replaying |
| `diverged` | At least one genuinely new public commit | Go to step 2 |
| `not-compared` | Public upstream was unavailable, so no public comparison ran | Go to step 3, and tell the captain the public check did not happen |

Route on the state that table reports, never on the `upstream-topology:` line alone.

`upstream-status: not-compared` comes with `upstream-check: degraded: <reason>` and exit 0, and it is the one answer that does not stop the fleet update.
It covers every way public upstream can be unavailable rather than unsafe: this home has no `upstream` remote, the bounded fetch failed because the public repo was unreachable, or the fetch succeeded onto a public repo that has no branch matching this home's default.
None of those is a broken setup, so the ordinary origin-only update still runs; the reason on the `upstream-check: degraded:` line, and the `upstream-fetch: failed:` line when there is one, is what you tell the captain.
Report it as "the public project could not be checked, and here is why", never as "the public project had nothing new" and never as current.

The check refuses, with a non-zero exit and no `upstream-status:` answer, only when the setup itself is unsafe or unusable.
That is exactly four cases: `upstream-topology: missing-origin-remote` (or `no-default-branch` or `not-a-git-repo`), `upstream-topology: same-repo-as-origin`, `upstream-topology: upstream-push-enabled`, and `inventory: invalid`.
On any of those, stop and tell the captain the concrete missing requirement, and do not treat it as "nothing new".
When the line is `upstream-topology: upstream-push-enabled`, the fix is the one command on the `upstream-topology-fix:` line; public upstream must be fetch-only before any upstream work runs.
`upstream-topology: missing-upstream-remote` is not in that list: it is a degraded state that reports `upstream-status: not-compared`, so it goes to step 3 with the rest of the degraded cases.

The check also passes through the private-divergence inventory's `inventory:` lines.
Treat `inventory: attention` as reconciliation input, never as a failure: each `inventory-entry:` and `inventory-uncovered:` line names something a reconciliation must decide about rather than silently drop.
Treat `inventory: invalid` as a hard stop, and do not continue to step 2 or step 3.
The inventory is what tells intentional private behavior apart from accidental drift, so an unparseable one leaves every later decision unsafe: tell the captain the reason on that line and stop.

## 2. Reconcile the new public commits

```sh
bin/fm-upstream.sh reconcile
```

It builds the merge in a fresh worktree on a new branch based on `origin/<default>`, so every private commit is preserved by construction and the running default branch is never moved by unmerged work.
Its `reconcile:` line is the whole decision:

- **`reconcile: ready`** - the merge is clean on the branch and worktree it names, with `private-commits: preserved` and `active-checkout: unchanged` proving both invariants.
  Ship it through the project's ordinary no-mistakes delivery path from that worktree, exactly like any other firstmate-repo change, opening the pull request against `origin` and nothing else.
  Reconcile the inventory in the same change: for every `inventory-entry:` line reporting `upstream-unreviewed-change`, `upstream-equivalent-unconfirmed`, `superseded`, or `needs-review`, and for every `inventory-uncovered:` path, either update the entry's disposition or add the missing entry, then record the review with `bin/fm-private-divergence.sh --refresh-reviewed <upstream-sha> --entry <id>` inside that worktree.
  Leaving one of those lines unaddressed is how intentional private behavior gets replayed away, so account for every one.
- **`reconcile: conflict`** - the merge needs semantic judgement, on the paths its `reconcile-conflict-path:` lines name.
  The merge was already aborted and nothing was changed, and the scratch branch and worktree were discarded unless a `reconcile-scratch: kept` line says otherwise.
  Escalate to the captain with the `reconcile-conflict-path:` list and what each side wants, and stop.
- **`reconcile: failed:`** - an invariant that reconciliation depends on did not hold, or the merge could not start at all because git refused it outright (`reconcile: failed: the merge could not start: <git's reason>`).
  Nothing was landed, and the scratch branch and worktree were discarded unless a `reconcile-scratch: kept` line says otherwise.
  Stop and escalate to the captain with the stated reason; never retry over it.
  A merge that never started owes no semantic judgement, so report it as the mechanical refusal it is rather than as conflicting work.

On either of those two, a `reconcile-scratch: kept` line means something really was left behind, and its `reconcile-recovery:` line is the next step that makes a retry possible.
Act on it rather than telling the captain nothing was left behind: the scratch branch name is derived from the upstream tip, so a leftover refuses every retry until it is cleared.
- **`reconcile: skipped:`** or **`reconcile: not-required:`** - act on the stated reason.
  When a `reconcile-recovery:` line is present, it is the exact next step that makes a retry possible without forcing anything.
- **`inventory: invalid`** - stop, exactly as in step 1.

Anything that would need forcing, stashing, resetting away work, rewriting history, or discarding a private commit is a captain decision, never something to work around.

When the pull request is ready but merge approval is still the captain's, stop there.
Tell the captain the full `https://...` pull-request URL and say plainly that `/updatefirstmate` must be run again after it lands to actually update the fleet.

Once the pull request has landed, continue to step 3 in the same session or the rerun.

## 3. Update the fleet from the private origin

```sh
bin/fm-update.sh
```

It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
It prints one status line per target (`updated <old>..<new>` / `reconciled redundant divergence <old>..<new>` / `already current` / `skipped: <reason>`), followed by three action lines:

- `reread-firstmate: yes|no`
- `restart-secondmates: fm-<id>...|none`
- `nudge-secondmates: fm-<id>...|none`

The two second-mate sets are disjoint and the script owns the split; do not re-derive it.
`restart-secondmates:` carries every live mate the pass left on the latest commit, whether it advanced or was already there.
A mate reaches neither set only because its home was skipped, because it has no live endpoint recorded here, or because its endpoint was positively classified as dead or missing.
   A skipped genuine divergence still requires attention through its durable reconciliation record; the other two cases need no update action from you.

On `reread-firstmate: yes`, the tracked instruction surface just advanced under you: **read `AGENTS.md` now** before doing anything else, so you act on the new instructions rather than the stale ones you started with.
On `reread-firstmate: no`, nothing changed for you.

Then restart every second mate the updater named, passing the whole `restart-secondmates:` list to one command (skip it entirely when it says `none`):

```sh
FM_HOME=<this-firstmate-home> bin/fm-secondmate-restart.sh <fm-id>...
```

Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` already points at the active firstmate home.
This is automatic and needs no per-mate confirmation from the captain.
Local and remote mates go in the same list; the command owns the transport, the profile each replacement runs on, and the wait.

It asks every listed mate first to write down the open work it holds only in its conversation, and restarts one only after that mate's own answer comes back.
A mate that is mid-turn queues the request behind that turn.
That is the whole point of the step, so do not work around it: it is what keeps a captain call the mate had formed but never registered from being lost with the conversation.
Its header owns the request, the bound, and the two knobs that change them.

Read its per-mate lines and its closing `summary:` line as the outcome:

- `restarted: <id>` - that mate is now genuinely running the current instructions and launch-time settings.
- `nudged: <id>: <reason>` - the restart was not safe, so the mate got the older re-read message instead and is still running the conversation and launch-time settings it started with.
  Never report one of these as a clean reload.
- `unreached: <id>: <reason>` - no safe running outcome could be confirmed, including an ambiguous relaunch result.

Finally, for every target on the `nudge-secondmates:` line (do nothing when it says `none`), send the one-line re-read steer:

```sh
FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
```

These are the mates that are on the latest bytes but could not be restarted provably, so the steer is the most this pass can honestly do for them.
It is a gentle steer, not an interruption: the mate already got a safe tracked-files fast-forward, and the steer never forces, tears down, or discards its work.
Never describe one of these as reloaded; its agent is still running the wiring it launched with.

## 4. Report to the captain in plain outcomes

Summarize under `AGENTS.md` section 9 without firstmate's internal vocabulary.
Cover three things: whether the public project had anything new, what landed, and what was left as-is and why.
For example: "Captain, the public project had nothing new, and firstmate and both second mates are now on the latest."
Or: "Captain, the public project has 4 new changes. They merge cleanly, and the combined change is ready for your review at <full URL>; say the word and I will land it, then update the fleet."

Say plainly when a mate got the message rather than a clean reload, and why - never let a partial reload read as a full one.
Surface any skipped target whose reason needs the captain's attention - a home with its own unlanded changes or local edits, which were left untouched on purpose.

## Safety

- **Public upstream is fetch-only.** No step here pushes to it or opens a pull request against it; the only pull-request target is the private origin.
  The check refuses outright when the `upstream` remote still carries a push url to the public repo, so an accidental push has nowhere to land.
- **Reconciliation is isolated.** The merge happens on a new branch in its own worktree; the running default branch is only ever advanced afterwards, by the ordinary guarded fast-forward, from work that already landed on origin.
- **Guarded convergence only.**
  A dirty, offline, non-default, or uniquely diverged target is skipped and reported, never forced or stashed.
  Only a clean secondmate divergence whose complete local result is already present upstream may move without ancestry, and `reset --keep` still refuses conflicting working-tree changes.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Nothing with work in it is disrupted.**
  A local or remote second mate gets a tracked-files fast-forward only when its own checkout is safe to advance, and a mate whose home was skipped is not restarted either.
  A restart replaces that mate's agent in the same home and endpoint after its open work is written down; it is never a teardown and never forced.
  Its crewmates keep running in their own endpoints, and every durable record - backlog, held captain calls, unread status, unhandled instructions - is re-presented to the replacement at startup.
  A restart refused before it is attempted leaves that mate on the re-read path; once a relaunch is attempted, any failed or ambiguous result is reported as unknown rather than attributed to either incarnation.
