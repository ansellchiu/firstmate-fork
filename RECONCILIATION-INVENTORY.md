# Route B reconciliation inventory

This branch is the Route B seed and reconciliation series for `ansellchiu/firstmate-fork`,
built in a disposable worktree of `firstmate-private` and never pushed anywhere.

Route B, its mechanism and its scoping rule are owned by
`data/fm-fork-migration-scout-s1/report.md` sections 3.1, 3.2, 4 and 5.1 in the firstmate home.
This file is the per-reconciliation record that section 3.2 requires: what each one carries,
why it diverges from upstream, and the evidence behind it.

## The seed

The seed is the Admiral's latest upstream tip, taken whole and unmodified:

```
upstream  https://github.com/kunchenguid/firstmate   main = 2bcb88c38921030033a37d67ae4f5d82cea90eb4
          "ci: standardize workflow timeouts into three tiers (#4910)"
```

The branch is rooted on that commit itself, so upstream's history IS this branch's history:

| Property | Value |
| --- | --- |
| `git merge-base --is-ancestor upstream/main HEAD` | true |
| `git merge-base HEAD upstream/main` | `2bcb88c3` - the current upstream tip, not a superseded one |
| commits on top of the seed | 57 (46 reconciliations, then the integration and repair commits the suites drove) |
| upstream files added since the divergence base, present here | **73 / 73** |
| private-only files, present here | **71 / 71** |
| files differing from upstream | 198 (the honest private footprint) |

For contrast, the published fork (`1c676346`) reports a merge base of `9bc051ff`, carries 10 of those
73 upstream files, and hides 89 upstream commits behind a single squashed tree overwrite. Nothing on
this branch does that: every upstream commit is a real ancestor and every private change is a
separate, attributable commit on top.

The divergence base used throughout is `40c50ea8` (`git merge-base origin/main upstream/main`).
Against it, `origin/main` carries 117 commits and upstream carries 94; 381 paths differ between the
two tips. Of those, 63 are upstream additions and 96 are upstream-only edits - both inherited
untouched from the seed - and the remaining **222 paths** are what the series below carries.

## How the series was built

Per report section 3.2, one reconciliation per inventory entry, or per group of previously uncovered
paths that share an area. `docs/private-divergence.json`'s 34 entries claimed 136 of the 222 carried
paths; the other 86 belonged to no entry, and are claimed here by 14 new entries rather than being
carried anonymously. A path is owned by exactly one reconciliation - the first entry whose globs
match it - and a shared file such as `AGENTS.md` is therefore resolved whole inside its owning
commit, which each entry below states.

Each reconciliation applies that entry's own private patch, `git diff 40c50ea8 origin/main -- <its paths>`,
onto the growing tree with a three-way merge, so every conflict raised is a real collision between the
private behavior and upstream's own work on the same lines. The series is ordered by that measured
conflict count, lowest first: 13 reconciliations applied cleanly, and the remaining 193 conflict
hunks across 66 files were resolved one entry at a time with that entry's recorded intent in hand.

Four dispositions appear below:

- **retained** - the private behavior is real, upstream has nothing equivalent, and it is carried.
- **retained, partly superseded** - part of the entry is carried and a named part is dropped because
  upstream now implements the same invariant, usually better placed.
- **superseded** - upstream carries the whole invariant; the entry produces no commit and is retired.
  This is the only mechanism, per report section 3.2, by which the divergence footprint actually shrinks.
- Nothing is carried on the strength of "private wins" or "upstream wins" alone.

A short run of integration and repair commits closes the series, for the seams only the whole series
exposes and the defects its own suites then caught; they are listed at the end.

## Verification

Everything below was run on the final reconciled tip, in this disposable worktree.

| Check | Command | Result |
| --- | --- | --- |
| upstream ancestry | `git merge-base --is-ancestor upstream/main HEAD` | true |
| merge base is the upstream tip | `git merge-base HEAD upstream/main` | `2bcb88c3` |
| upstream-added files present | census against `40c50ea8..2bcb88c3` | **73 / 73** |
| private-only files present | census against `40c50ea8..origin/main` | **71 / 71** |
| shell lint, full canonical set | `CI=true bin/fm-lint.sh` | **clean** (ShellCheck 0.11.0, actionlint 1.7.12, 3 workflows valid) |
| test coverage guard | `bin/fm-test-run.sh --check-coverage` | **ok** - 243 scripts, all mapped; 24 parallel, 202 serial over 9 shards, 17 Herdr |
| portable parallel lane 1 | `bin/fm-test-run.sh --lane portable-parallel-1` | **11 suites, 0 failed** |
| portable parallel lane 2 | `bin/fm-test-run.sh --lane portable-parallel-2` | **13 suites, 0 failed** |
| portable serial lane | `bin/fm-test-run.sh --lane portable-serial` | 202 suites, 30 gate-skipped, **15 failed - none of them caused by this series** (below) |
| publish script dry run | `./push-route-b.sh` | **clean**, one ref planned, nothing pushed |

The real-Herdr family is deliberately not run here: it needs a live Herdr server, and the fork's CI
is where it belongs.

### The 15 serial failures, each accounted for

None is introduced by this reconciliation. Every one was checked by running the same suite against a
real `git clone` of `firstmate-private` main (`db19959e`) in a scratch directory, or is a live-harness
suite that drives a real binary on the host.

**Already failing on `firstmate-private` main** (reproduced there, same assertion):

| Suite | What it reports |
| --- | --- |
| `fm-findings` | cleanup of a task with a findings file refuses - no completion receipt |
| `fm-gate-refuse` | cleanup of landed work refuses - no completion receipt |
| `fm-backlog-atomicity` | Beads completion cleanup refuses - no completion receipt |
| `fm-backend-orca` | Orca ship cleanup fails on a matching worktree id |
| `fm-on` | the trusted doctor does not print `mode=check` with git unavailable |
| `fm-secondmate-liveness` | a Herdr pane state of `unknown` maps to `missing` on a host whose herdr answers `stopped` |
| `fm-watch-triage` | the auto-standdown case's loud wake line |
| `fm-secondmate-sync` | spawn does not fast-forward the secondmate worktree |
| `fm-shared-captain-inheritance` | spawn convergence does not copy shared captain preferences |
| `fm-voice-relay` | credential reuse |
| `fm-calm-pi-extension` | `render_export_dom` retries against a Chrome that never finishes |
| `fm-remote-secondmate-lifecycle-e2e` | remote retirement does not remove the remote home |

The first three are one defect: the completion-receipt gate landed in `3b1ef065` without updating the
fixtures that stamp a landed ship task by hand. It is recorded as an incidental finding against this
task rather than fixed here, because it is this home's, not the migration's. The same class of
fixture gap in upstream-owned suites WAS fixed here, because those failures only appear once this
series puts the gate and those fixtures in one tree.

**Live-harness suites, failing on this host rather than in the code:**

| Suite | What it needs |
| --- | --- |
| `fm-pi-branch-responsiveness-live-e2e` | a real Pi that draws its TUI (0.85.1 never did here) |
| `fm-pi-working-composer-live-e2e` | the same, plus a ready composer under Calm |
| `fm-composer-codex-idle-live-e2e` | a real codex-cli whose idle screen classifies empty |

### What the suites caught in this series

Worth stating plainly, because it is the argument for running them rather than reasoning about the
diff: three of the repairs above were real product defects this reconciliation introduced, not test
noise. `fm_merge_outcome_report` lost the receipt helpers its retained body calls; the watcher lost
`FM_STALE_AUTO_STANDDOWN_THRESHOLD`'s default, so every wedge escalation died at that line under
`set -u` and a wedged worker would have gone unreported; and one `wedge_timer_check` call site still
passed five arguments after the signature took a sixth, aborting the rate-limit resume path.

## The reconciliation series

Ordered exactly as applied - by measured conflict count, lowest first - so the risky merges sit at
the end of the series and not under the easy ones.

### 1. `token-spend-view` - Cost reporting

- **Commit:** `8c97cd66` (2 files changed, 299 insertions(+))
- **Inventory entry:** `docs/private-divergence.json`; provenance `f9266d3`
- **Invariant it protects:** Per-task token spend is readable without leaving the home, so cost stays a courtesy report rather than a blocking gate.
- **Carries:** 2 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-spend.sh`, `tests/fm-spend.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 2. `wake-batch-coalescing` - Wake classification

- **Commit:** `0638752e` (3 files changed, 997 insertions(+), 4 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `1d5b398`
- **Invariant it protects:** Routine supervision events coalesce into one bounded batch that never becomes a notification on its own - an absorbed batch rolls into local triage telemetry when its window elapses and only rides out with an independently admitted wake - and rehydration diffs only the records that actually changed.
- **Carries:** 3 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-classify-lib.sh`, `bin/fm-push-transition-lib.sh`, `tests/fm-wake-batching.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 3. `auto-standdown` - Supervision triage

- **Commit:** `6e41d0a2` (2 files changed, 50 insertions(+), 3 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `b9d709d`
- **Invariant it protects:** A worker that never started stops escalating forever: the watcher stands the task down once, preserves its brief, and raises one loud check wake instead of an endless stale ladder.
- **Carries:** 2 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `tests/fm-gotmp.test.sh`, `tests/wake-helpers.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 4. `delivery-posture-gate` - Task dispatch

- **Commit:** `29c8c519` (2 files changed, 238 insertions(+), 2 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `1c68a87`
- **Invariant it protects:** A ship spawn or validation trigger more outward-facing than the project registry permits is refused before anything is created, rather than only warning when it drops below the registered rigor.
- **Carries:** 2 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-send.sh`, `tests/fm-task-delivery.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 5. `changed-selection-deletions` - Test selection

- **Commit:** `b9b0319c` (1 file changed, 41 insertions(+), 1 deletion(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `a1b2b24`
- **Invariant it protects:** Changed-test selection treats a deleted path as having no behavior left to select for, so removing a source and its path rule in one commit does not make selection refuse on the removal itself.
- **Carries:** 1 path; 0 conflict hunks resolved at intake
- **Paths it owns:** `tests/fm-test-run.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 6. `away-escalation-delivery` - Away mode

- **Commit:** `6da7f487` (3 files changed, 305 insertions(+), 5 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `b353bf25,3348e080`
- **Invariant it protects:** An away-mode escalation the daemon could not deliver becomes a loud alarm rather than silence, and a repeatedly wedged submit is bounded by a counted circuit breaker whose count is retired with the rest of the away-mode artifacts.
- **Carries:** 3 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-afk-launch.sh`, `bin/fm-afk-return.sh`, `tests/fm-daemon.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 7. `herdr-native-idle-unknown` - Herdr backend

- **Commit:** `1195a46f` (2 files changed, 30 insertions(+), 4 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `a80d6499`
- **Invariant it protects:** Herdr's native idle agent state is read as unknown rather than idle, so a worker whose harness footer is hidden (Calm) is not classified idle mid-turn; only a positive busy record outranks it.
- **Carries:** 2 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `tests/fm-busy-state.test.sh`, `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 8. `findings-plane` - Incidental findings

- **Commit:** `5b1e966b` (3 files changed, 1301 insertions(+))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Ship workers record out-of-scope defects to a per-task findings file that survives teardown.
- **Carries:** 3 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-findings-lib.sh`, `bin/fm-findings.sh`, `tests/fm-findings.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 9. `completion-receipts` - Task receipts

- **Commit:** `c07823de` (2 files changed, 1940 insertions(+))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Teardown refuses without a typed completion receipt; archived receipts survive cleanup in an append-only index.
- **Carries:** 2 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-receipt.sh`, `tests/fm-receipt.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 10. `process-event-sources` - Process events

- **Commit:** `be8f6911` (3 files changed, 675 insertions(+), 1 deletion(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Long-polling process-to-event sources and condition->action watches become durable wakes.
- **Carries:** 7 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `.agents/skills/process-event-sources/SKILL.md`, `bin/fm-procevent-fleet-health.sh`, `bin/fm-procevent-lib.sh`, `bin/fm-procevent.sh`, `docs/verification/process-event-sources.md`, `tests/fm-procevent-fleet-health.test.sh`, `tests/fm-procevent.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 11. `discord-spike` - Discord spike

- **Commit:** `96a135c5` (5 files changed, 1875 insertions(+))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Time-boxed captain-channel mirror for four reach classes only; unarmed homes post nothing.
- **Carries:** 5 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-discord-lib.sh`, `bin/fm-discord-post.sh`, `bin/fm-procevent-discord.sh`, `docs/discord-spike.md`, `tests/fm-discord.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 12. `branch-outcome-store` - Pi supervision branch

- **Commit:** `0fddc2de` (2 files changed, 548 insertions(+), 18 deletions(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Durable per-task branch outcomes with cursors and bounded caches back the supervision branch.
- **Carries:** 2 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-branch-outcome.sh`, `tests/fm-branch-supervision.test.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no loss on either side.

### 13. `home-seeding` - Home seeding

- **Commit:** `73edd251` (7 files changed, 219 insertions(+), 16 deletions(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Local and remote secondmate homes are seeded transactionally and never share a home.
- **Carries:** 8 paths; 0 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-fleet-sync.sh`, `bin/fm-home-seed.sh`, `bin/fm-remote-home-seed.sh`, `docs/remote-secondmates.md`, `docs/verification/secondmate-parent-channel.md`, `tests/fm-fleet-sync.test.sh`, `tests/fm-secondmate-safety.test.sh`, `tests/secondmate-helpers.sh`
- **Disposition:** retained
- **Resolution:** Applied onto upstream with no conflict; the `clone_theta` fixture leftover it carried was made unused-safe so upstream's full-set lint stays clean.

### 14. `unmetered-quota-report` - Dispatch quota

- **Commit:** `b4ef2623` (4 files changed, 1123 insertions(+))
- **Inventory entry:** `docs/private-divergence.json`; provenance `2382d33`
- **Invariant it protects:** Providers quota-axi does not meter still get a quota perspective, so dispatch selection accounts for every candidate instead of silently skipping unmetered ones.
- **Carries:** 4 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `.agents/skills/quota-array-dispatch/SKILL.md`, `bin/fm-quota-unmetered-report.mjs`, `bin/fm-quota-unmetered.sh`, `tests/fm-quota-unmetered.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream added a typed dispatch-resolution pointer to the same paragraph this home extended with the unmetered-provider rule; both sentences kept.

### 15. `daemon-lock-liveness` - Away mode

- **Commit:** `d34c5c11` (2 files changed, 7 insertions(+), 33 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `c3b13aa`
- **Invariant it protects:** Away mode is read from a lock a live daemon actually holds, verified portably, so a stale flag cannot silence the watcher after the daemon is gone.
- **Carries:** 2 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `bin/fm-afk-start.sh`, `tests/fm-wake-daemon-lifecycle-e2e.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream gave `fm_afk_flag_write` a mode parameter at the exact line this home's daemon-liveness helpers were inserted above; upstream's signature kept, the helpers applied around it.

### 16. `pi-primary-growth` - Pi primary conversation

- **Commit:** `2084a92c` (16 files changed, 3998 insertions(+), 121 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `47566fc`
- **Invariant it protects:** The Pi primary conversation is measured for the point where re-sending it stops being cheap, and calibrated circuit breakers rotate it without splitting a bounded action or dropping supervision.
- **Carries:** 16 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `.pi/extensions/fm-primary-growth.ts`, `.pi/extensions/fm-primary-pi-watch.ts`, `.pi/extensions/lib/fm-operational-input.ts`, `.pi/extensions/lib/fm-primary-growth.ts`, `.pi/extensions/lib/fm-primary-session-lock.ts`, `bin/fm-pi-session-metrics.mjs`, `bin/fm-pi-session-metrics.sh`, `docs/pi-primary-growth.md`, `docs/verification/pi-primary-growth-baseline.md`, `tests/fm-calm-pi-extension.test.sh`, `tests/fm-pi-primary-live-e2e.test.sh`, `tests/fm-pi-primary-types.test.sh`, `tests/fm-pi-session-metrics.test.sh`, `tests/fm-pi-watch-extension.test.sh`, `tests/fm-primary-growth.test.sh`, `tests/fm-watch-recovery-loop.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream changed Calm's working-ship glyph in the live e2e probe this home had rewritten to capture styled output; both changes kept.

### 17. `pr-forge-state-classification` - Crew state

- **Commit:** `d87a8274` (2 files changed, 169 insertions(+), 15 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `099dfb5`
- **Invariant it protects:** A closed-unmerged pull request is classified apart from a merged one on GitHub and GitLab alike, so a terminal passed run whose PR was closed without merging reads as failed rather than done.
- **Carries:** 2 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `bin/fm-pr-poll.sh`, `tests/fm-pr-check-security.test.sh`
- **Disposition:** retained
- **Resolution:** Both sides added a test function at the same insertion point in the PR-check security suite; kept as a union.

### 18. `teardown-dedupe-marker-sync` - Teardown

- **Commit:** `f45a668d` (3 files changed, 372 insertions(+), 5 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `16a1a08`
- **Invariant it protects:** A retired task's dedupe and stale markers are synchronized at teardown, so the window it vacates cannot echo its wakes onto whatever occupies that window next.
- **Carries:** 3 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `bin/fm-backend.sh`, `tests/fm-teardown.test.sh`, `tests/fm-wake-drain-unread-status.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream's recovery-classification comment already states both exceptions this home documented, so upstream's wording replaces the private one; the private receipt-attempt cleanup path is kept in teardown's removal list.

### 19. `config-inherit-single-owner` - Secondmate provisioning

- **Commit:** `a8962e9f` (2 files changed, 82 insertions(+), 5 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `a418b46`
- **Invariant it protects:** The inheritable-config allowlist has exactly one owner in bin/fm-config-inherit-lib.sh, and every consumer and document derives from FM_INHERITABLE_CONFIG rather than restating the list.
- **Carries:** 3 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `.agents/skills/secondmate-provisioning/SKILL.md`, `bin/fm-config-inherit-lib.sh`, `tests/fm-secondmate-harness.test.sh`
- **Disposition:** retained
- **Resolution:** Both sides added one key to `FM_INHERITABLE_CONFIG`; the merged default carries `av-inject` and `claude-permission-mode`.

### 20. `rearm-resurface-empty-queue` - Wake queue

- **Commit:** `b090e672` (2 files changed, 68 insertions(+), 50 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `950421c7`
- **Invariant it protects:** Re-arming after watcher downtime with an empty durable queue resolves the downtime marker instead of emitting a synthetic recovery wake, so recovery never invents work that was never queued.
- **Carries:** 2 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `tests/fm-watch-arm.test.sh`, `tests/fm-watcher-lock.test.sh`
- **Disposition:** retained
- **Resolution:** Both sides appended a test function and a runner entry at the same two points; kept as a union.

### 21. `macos-platform-binary-holder` - Remote secondmates

- **Commit:** `b4b836df` (1 file changed, 30 insertions(+), 10 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `0a6e6a7`
- **Invariant it protects:** Darwin socket-owner birth classification is proven with a real holder process whose environment can actually be read: on macOS the Apple-shipped /usr/bin/jq is a platform binary whose marker environment is hidden, so those tests hold the fifo with node instead of silently proving nothing.
- **Carries:** 1 path; 1 conflict hunk resolved at intake
- **Paths it owns:** `tests/fm-remote-herdr-guard.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream's edits in this region only restate jq as the holder process, which is exactly what this home's platform-aware holder generalizes; the private version supersedes them.

### 22. `herdr-relaunch-identity-release` - Runtime backends

- **Commit:** `d08e99a0` (1 file changed, 45 insertions(+), 1 deletion(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `0a6e6a7`
- **Invariant it protects:** The real-herdr relaunch smoke drives a replacement harness that reports and then releases a native Herdr agent identity, and waits for that release before asserting re-homing, so the relaunch path is proven against the native agent registry the private submit and idle classification reads rather than against a pane that never carried an identity.
- **Carries:** 1 path; 1 conflict hunk resolved at intake
- **Paths it owns:** `tests/fm-control-herdr-smoke.test.sh`
- **Disposition:** retained
- **Resolution:** Add/add on the same smoke-test block; the private identity-release assertions are a superset.

### 23. `calm-composer` - Pi Calm and composer

- **Commit:** `86f3133a` (17 files changed, 936 insertions(+), 2 deletions(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Calm presentation and composer-shape detection for Pi panes, with recorded terminal fixtures.
- **Carries:** 17 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `docs/calm-mode-feasibility.md`, `docs/calm.md`, `docs/verification/pi-composer-shapes.md`, `tests/assets/pi-0.85-composer/calm-idle.ansi`, `tests/assets/pi-0.85-composer/calm-idle.cursor`, `tests/assets/pi-0.85-composer/calm-typed-idle.ansi`, `tests/assets/pi-0.85-composer/calm-typed-idle.cursor`, `tests/assets/pi-0.85-composer/calm-typed-working.ansi`, `tests/assets/pi-0.85-composer/calm-typed-working.cursor`, `tests/assets/pi-0.85-composer/calm-working.ansi`, `tests/assets/pi-0.85-composer/calm-working.cursor`, `tests/assets/pi-0.85-composer/modal-eats-enter.ansi`, `tests/assets/pi-0.85-composer/modal-eats-enter.cursor`, `tests/assets/pi-0.85-composer/stock-working.ansi`, `tests/assets/pi-0.85-composer/stock-working.cursor`, `tests/fm-composer-lib.test.sh`, `tests/fm-pi-working-composer-live-e2e.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream rewrote the boat's rendering description while this home added the composer-shape pointer and generalized "working indicator"; both kept.

### 24. `agent-control-plane` - Agent control

- **Commit:** `188cd4de` (4 files changed, 371 insertions(+), 14 deletions(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Lifecycle control is driven through one verified control plane that never tears down or discards.
- **Carries:** 5 paths; 1 conflict hunk resolved at intake
- **Paths it owns:** `docs/agent-control.md`, `tests/fm-agy-control-live-e2e.test.sh`, `tests/fm-backend-herdr-exited-agent-e2e.test.sh`, `tests/fm-control-relaunch.test.sh`, `tests/fm-control.test.sh`
- **Disposition:** retained
- **Resolution:** Both sides replaced the same bullet - upstream with the exit/relaunch boundary note, this home with the Herdr registration exception; both kept as separate bullets.

### 25. `stale-repeat-suppression` - Supervision triage

- **Commit:** `727b3325` (4 files changed, 410 insertions(+), 10 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `636c4ba`
- **Invariant it protects:** An UNDECLARED stale notification firstmate already handled and acknowledged is not re-presented byte-identically inside a bounded horizon, so a churny idle pane cannot spend a full-context turn per poll; a declared external wait is bounded by its own declaration instead, because the bare payload cannot tell one declaration from the next.
- **Carries:** 4 paths; 2 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-teardown.sh`, `bin/fm-wake-drain.sh`, `bin/fm-wake-lib.sh`, `tests/fm-wake-queue.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream added a merge-authority file to teardown's removal list where this home added the receipt-attempt ledger; both kept. The rewake comment keeps the private wording because it states the unbound-generation case the code implements.

### 26. `scout-research-standards` - Crewmate briefs

- **Commit:** `7ebb2468` (2 files changed, 150 insertions(+), 3 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `94d362e`
- **Invariant it protects:** Every scout brief carries a standing, task-agnostic retrieval contract: live web-search with cited queries, an authoritative existence-surface check for every negative claim, and an explicit could-not-check statement when a surface is unreachable.
- **Carries:** 2 paths; 2 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-brief.sh`, `tests/fm-brief.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream added a Lavish-floor line to the same header block and a test to the same runner list; kept as a union.

### 27. `session-lock-harness-case` - Session lock

- **Commit:** `2be5f051` (2 files changed, 111 insertions(+), 4 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `ee2f2a4c`
- **Invariant it protects:** The harness-ancestry match folds the reported command name before testing it, so a macOS app bundle that reports a capitalized executable name is still recognized and the session is not refused its own home lock.
- **Carries:** 2 paths; 2 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-session-lock-lib.sh`, `tests/fm-session-lock-ancestry.test.sh`
- **Disposition:** retained
- **Resolution:** Both sides added independent cases to the same two spots; kept as a union, with the private capitalized-command-name case restored to the runner list.

### 28. `autoarm-actionable-rewake` - Watcher continuity

- **Commit:** `931f82bb` (2 files changed, 85 insertions(+), 6 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `478c974,d0c2d76`
- **Invariant it protects:** An actionable Claude Stop wake always forces its continuation. The rewake commit accepts a handling recovery marker, and commits UNBOUND when the marker is acked or absent, instead of refusing into a silent exit 0 that would discard the banner already printed and stop the session on an unhandled supervision wake; an unbound entry names no recovery generation, so it still never claims mid-turn health.
- **Carries:** 2 paths; 2 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-claude-stop-autoarm.sh`, `tests/fm-claude-stop-autoarm.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream and this home wrote the same binding differently; the private version is kept because it also covers the `handling` and acked/absent marker states the code branches on.

### 29. `mail-plane-input-hardening` - Mail plane

- **Commit:** `7caef261` (2 files changed, 56 insertions(+), 4 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `478c974`
- **Invariant it protects:** Operator-supplied mail input fails safe: a .env line whose trimmed key is not a shell identifier is skipped rather than aborting every subcommand (including the standing poll) through indirect expansion under set -e, and a recipient or subject carrying CR or LF is refused before it can inject SMTP headers.
- **Carries:** 2 paths; 2 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-mail.sh`, `tests/fm-mail.test.sh`
- **Disposition:** retained
- **Resolution:** Add/add over the whole file body; the private side is a strict superset of upstream's (header-injection refusal, .env key validation) so it is taken whole.

### 30. `launch-agent-xml-escaping` - Remote secondmates

- **Commit:** `06b9c2df` (2 files changed, 37 insertions(+), 4 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `d0c2d76`
- **Invariant it protects:** The Aqua launch-agent plist escapes the guard exec command as well as the login shell, so an ampersand or angle bracket in the repo root, the resolved herdr path, or the session name cannot render a malformed plist whose only symptom is an undiagnosable launchctl bootstrap error.
- **Carries:** 2 paths; 2 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-remote-doctor.sh`, `tests/fm-remote-doctor.test.sh`
- **Disposition:** retained
- **Resolution:** The private escape wraps upstream's own `launch_agent_exec_command`, and the private holder rewrite supersedes upstream's jq-holder comments.

### 31. `mail-check-arm` - Mail plane

- **Commit:** `(no commit - nothing left to carry)` (no diff against the seed)
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** The received-mail poll is armed as a registered check rather than run conversationally.
- **Carries:** 2 paths; 2 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-mail-check.sh`, `tests/fm-mail-check.test.sh`
- **Disposition:** superseded
- **Resolution:** Upstream carries `bin/fm-mail-check.sh` and its suite ahead of this home's copy: it replaces `head -n 1`/`grep -q` with pipe-draining `sed`/`grep` so a large poll cannot add a Broken pipe diagnostic. Resolving every hunk to upstream left a zero-byte diff, so this entry produces no commit and is retired rather than re-applied.

### 32. `pi-branch-rotation` - Pi supervision branch

- **Commit:** `6bfe16e2` (6 files changed, 1005 insertions(+), 17 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `6277477`
- **Invariant it protects:** The supervision branch conversation rotates at safe boundaries and carries a durable session-start catch-up obligation across the rotation.
- **Carries:** 6 paths; 4 conflict hunks resolved at intake
- **Paths it owns:** `.pi/extensions/fm-branch-supervision.ts`, `.pi/extensions/lib/fm-branch-rotation.ts`, `docs/pi-supervision-branch.md`, `tests/fm-branch-rotation.test.sh`, `tests/fm-pi-branch-extension.test.sh`, `tests/fm-pi-branch-live-e2e.test.sh`
- **Disposition:** retained
- **Resolution:** Rotation is private; upstream's away-posture tail and its own scoping are independent. Both are in the prompt path and both verification paragraphs were merged.

### 33. `spawn-launch-postcondition` - Task dispatch

- **Commit:** `100cf9f8` (4 files changed, 216 insertions(+), 21 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `b36ef90`
- **Invariant it protects:** A spawn confirms the agent is alive before reporting the task as spawned, so a dead launch is never recorded as dispatched work.
- **Carries:** 4 paths; 4 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-control-lib.sh`, `bin/fm-control.sh`, `tests/fm-spawn-launch-postcondition.test.sh`, `tests/lib.sh`
- **Disposition:** retained
- **Resolution:** Upstream refactored the control plane's supported-harness test into a list walk; this home's agy membership now comes from that list, and its `/exit` verb and resolver note are kept.

### 34. `supervision-surface` - Supervision protocols

- **Commit:** `071d7ab6` (6 files changed, 162 insertions(+), 2 deletions(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Harness supervision protocols, turn-end guards and watcher continuity as this fleet runs them.
- **Carries:** 9 paths; 4 conflict hunks resolved at intake
- **Paths it owns:** `docs/supervision-protocols/claude.md`, `docs/supervision-protocols/pi.md`, `docs/tmux-backend.md`, `docs/turnend-guard.md`, `docs/verification/runtime-backends.md`, `docs/verification/supervision.md`, `docs/watcher-continuity.md`, `tests/fm-tmux-submit-busy.test.sh`, `tests/fm-wake-drain-outcome-backstop.test.sh`
- **Disposition:** retained
- **Resolution:** Upstream's 0.9.0 Herdr measurements supersede this home's 0.8.0 ones for the endpoint-recovery sections; this home's agy control verification block is unique and was kept ahead of them. Upstream's turn-end guard and Claude protocol text is a superset of the private wording; the Pi protocol keeps this home's repeat-suppression sentence.

### 35. `herdr-native-submit-proof` - Herdr backend

- **Commit:** `176a9bb4` (4 files changed, 659 insertions(+), 49 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `0dd04ef`
- **Invariant it protects:** Herdr's native idle-to-busy agent-state transition is an independently sufficient proof that an Enter landed, so a harness whose rendered busy footer is hidden by a presentation setting is not reported as an unconfirmed steer and re-injected.
- **Carries:** 3 paths; 6 conflict hunks resolved at intake
- **Paths it owns:** `bin/backends/herdr.sh`, `docs/herdr-backend.md`, `tests/fm-backend-herdr.test.sh`
- **Disposition:** retained, partly superseded
- **Resolution:** Upstream implemented this home's exited-agent recovery as a first-class `stale-agent` presence state inside the strict classifier, proven from `pane process-info` plus the real process table, and reused by husk detection, rollback and teardown. That is a superset of the private `fm_backend_herdr_pane_agent_exited` probe, which only widened the recovery-grade read, so the private mechanism, its doc section and its portable cases were dropped and the real-Herdr e2e guard was repointed at the upstream classifier. The entry's own native submit-proof behavior is retained.

### 36. `backlog-transitions` - Backlog transitions

- **Commit:** `27e00107` (1 file changed, 21 insertions(+), 2 deletions(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Dispatch and teardown move the work item themselves and refuse rather than report an unrecorded success.
- **Carries:** 3 paths; 6 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-backlog-handoff.sh`, `bin/fm-backlog-transition-lib.sh`, `bin/fm-decision-hold.sh`
- **Disposition:** retained, partly superseded
- **Resolution:** Upstream already carries this home's addressing refactor and adds a bounded per-item read with a wedge latch on top, so `bin/fm-backlog-transition-lib.sh` and `bin/fm-backlog-handoff.sh` resolved entirely to upstream; only `bin/fm-decision-hold.sh` still diverges.

### 37. `residual-private-drift` - Residual

- **Commit:** `f98eee46` (6 files changed, 1352 insertions(+), 5 deletions(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Remaining private-only behavior with no larger area of its own; retained and now inventoried.
- **Carries:** 9 paths; 6 conflict hunks resolved at intake
- **Paths it owns:** `.agents/skills/bearings/SKILL.md`, `.agents/skills/firstmate-coding-guidelines/SKILL.md`, `bin/fm-nm-run-lib.sh`, `bin/fm-operational-input.sh`, `bin/fm-promote.sh`, `docs/verification/dispatch-auth.md`, `tests/fm-bearings-snapshot.test.sh`, `tests/fm-ext-launchwrap.test.sh`, `tests/fm-spawn-packet.test.sh`
- **Disposition:** retained, partly superseded
- **Resolution:** `bin/fm-nm-run-lib.sh`'s private live-over-terminal rule is superseded by upstream's `fm_nm_select_run` for the same reason as `rate-limit-classification`. Everything else in this bucket - the launch-wrap seam's tests, the packet-class suite, the dispatch-auth verification record, `bin/fm-operational-input.sh`, and the findings clause now folded into upstream's `PROMOTION_SHIP_SPEC` - is retained.

### 38. `automic-vault-injection` - Secret injection

- **Commit:** `92863e51` (8 files changed, 1200 insertions(+), 2 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `57868e0,6b936e7`
- **Invariant it protects:** A worker runs one key-dependent tool call through point-of-use injection; worker launches are never wrapped and no worker holds a key in its environment.
- **Carries:** 8 paths; 7 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-av-inject-lib.sh`, `bin/fm-av-run.sh`, `bin/fm-bootstrap.sh`, `bin/fm-vault-lib.sh`, `docs/configuration.md`, `tests/fm-av-inject.test.sh`, `tests/fm-bootstrap.test.sh`, `tests/fm-vault.test.sh`
- **Disposition:** retained
- **Resolution:** Kept; upstream's typed-dispatch harness resolution in `bin/fm-bootstrap.sh` is a superset of the private static list and replaces it.

### 39. `lint-guard-ci` - Repo checks

- **Commit:** `8e193d00` (1 file changed, 1 insertion(+), 1 deletion(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Private lint, guard, and CI lane composition for this repo's own shared tracked material.
- **Carries:** 7 paths; 8 conflict hunks resolved at intake
- **Paths it owns:** `.github/workflows/ci.yml`, `CONTRIBUTING.md`, `bin/fm-guard.sh`, `bin/fm-lint.sh`, `docs/fm-test-portable-shards.md`, `tests/fm-guard-stale-banner.test.sh`, `tests/fm-lint.test.sh`
- **Disposition:** retained, almost entirely superseded
- **Resolution:** Upstream's three-tier CI timeout policy, nine-shard serial layout and canonical lint partitions supersede this home's five-shard, self-hosted-runner evidence, which was measured on `ovh-firstmate` - a runner the public fork does not have. One line survives.

### 40. `extension-contract` - Home extensions

- **Commit:** `168105be` (11 files changed, 2527 insertions(+), 25 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `878d5ff`
- **Invariant it protects:** Private homes install extensions that register their own load triggers and contribute bounded session-start sections; a failing contributor must never block session start.
- **Carries:** 11 paths; 9 conflict hunks resolved at intake
- **Paths it owns:** `.agents/skills/bootstrap-diagnostics/SKILL.md`, `AGENTS.md`, `README.md`, `bin/fm-ext-hook-lib.sh`, `bin/fm-ext.sh`, `bin/fm-session-start.sh`, `docs/scripts.md`, `tests/ext-fixture-helpers.sh`, `tests/fm-ext-hook.test.sh`, `tests/fm-ext.test.sh`, `tests/fm-session-start.test.sh`
- **Disposition:** retained
- **Resolution:** Both sides extended the same bootstrap-diagnostic marker list, the same watcher-internals glob line and the same scripts table; each merged as a union rather than a choice.

### 41. `upstream-reconciliation` - Self-update topology

- **Commit:** `3338ecf4` (9 files changed, 2901 insertions(+), 67 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `ecfcdf0`
- **Invariant it protects:** This home has a private origin and a fetch-only public upstream, so "origin is current" never means "we carry everything public upstream published"; every self-update checks upstream first and reconciles genuinely new public commits through an isolated branch and a private pull request.
- **Carries:** 9 paths; 10 conflict hunks resolved at intake
- **Paths it owns:** `.agents/skills/updatefirstmate/SKILL.md`, `bin/fm-private-divergence.sh`, `bin/fm-update.sh`, `bin/fm-upstream.sh`, `docs/architecture.md`, `docs/private-divergence.json`, `docs/private-divergence.md`, `tests/fm-private-divergence.test.sh`, `tests/fm-upstream.test.sh`
- **Disposition:** retained
- **Resolution:** This home's public-upstream check and private-pull-request reconciliation, and upstream's guarded secondmate convergence for squash-merged history, are independent and both kept; the duplicated safety bullets were folded.

### 42. `portfolio-attention-limit` - Portfolio attention

- **Commit:** `57e89689` (9 files changed, 2605 insertions(+), 23 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `42cd407`
- **Invariant it protects:** The fleet enforces a configurable portfolio attention limit across focused projects and active work, while preserving an explicit off switch and reporting the counted set and reasons through shared projections.
- **Carries:** 9 paths; 11 conflict hunks resolved at intake
- **Paths it owns:** `.agents/skills/project-management/SKILL.md`, `bin/fm-attention-lib.sh`, `bin/fm-attention.sh`, `bin/fm-bearings-snapshot.sh`, `bin/fm-fleet-snapshot.sh`, `bin/fm-fleet-view.sh`, `bin/fm-project-mode.sh`, `tests/fm-attention.test.sh`, `tests/fm-kimi-harness.test.sh`
- **Disposition:** retained
- **Resolution:** The private portfolio attention block and upstream's contributions coverage block are independent features that both sides added at the same points in `bin/fm-fleet-snapshot.sh` and `bin/fm-bearings-snapshot.sh`; both are kept, including both CLI modes and both jq blocks.

### 43. `claims-audit` - Captain calls

- **Commit:** `ba3703f4` (6 files changed, 549 insertions(+), 68 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `c3cbf27,1cc00e2`
- **Invariant it protects:** Completing an origin that filed a report requires attesting how many load-bearing claims were spot-verified, with a higher floor and the offending line quoted when the negative-claim classifier fires, so a false "X does not exist" verdict is not relayed to the captain unchecked.
- **Carries:** 6 paths; 17 conflict hunks resolved at intake
- **Paths it owns:** `.agents/skills/captain-hold-lifecycle/SKILL.md`, `bin/fm-captain-hold.sh`, `docs/captain-hold-lifecycle.md`, `tests/fm-backlog-atomicity.test.sh`, `tests/fm-captain-hold-lifecycle.test.sh`, `tests/fm-cmux-claude-composer-live-e2e.test.sh`
- **Disposition:** retained
- **Resolution:** The private batched-answer `--item` fields and `--claims-checked` gate are kept; upstream's `BD_DUE_REQUIRED=false` captain-row create path is kept alongside them.

### 44. `rate-limit-classification` - Supervision triage

- **Commit:** `0aa816c5` (7 files changed, 1769 insertions(+), 69 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `f7205a1`
- **Invariant it protects:** A worker stalled on a provider rate limit is classified apart from a wedged worker, so a bounded external wait is not escalated as a failure.
- **Carries:** 7 paths; 22 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-crew-state.sh`, `bin/fm-rate-limit-lib.sh`, `bin/fm-supervise-daemon.sh`, `bin/fm-watch.sh`, `tests/fm-crew-state.test.sh`, `tests/fm-rate-limit.test.sh`, `tests/fm-watch-triage.test.sh`
- **Disposition:** retained, partly superseded
- **Resolution:** The private live-over-terminal run-selection heuristic is superseded by upstream's identity-aware `fm_nm_select_run` plus its optional sqlite inventory lookup, which `bin/fm-crew-state.sh` now calls ahead of the coarse ledger. The private forge-state classification survives on the coarse `completed` path; on the `axi status` `passed` path upstream's multi-forge `passed_pr_detail` decides the detail and keeps `done`, matching AGENTS.md section 7's stated mapping. The private stale-signature escalation reset is kept and now runs after upstream's dead-record probe.

### 45. `pr-merge-plane` - PR and merge plane

- **Commit:** `63a7fcd5` (7 files changed, 313 insertions(+), 1 deletion(-))
- **Inventory entry:** new entry, claimed here from previously uncovered drift
- **Invariant it protects:** Merge outcomes are proved and recorded before being reported as landed; forge state is classified, not assumed.
- **Carries:** 7 paths; 24 conflict hunks resolved at intake
- **Paths it owns:** `bin/fm-merge-local.sh`, `bin/fm-merge-outcome-lib.sh`, `bin/fm-pr-check.sh`, `bin/fm-pr-lib.sh`, `bin/fm-pr-merge.sh`, `docs/gitlab-merge-watch.md`, `tests/fm-pr-merge.test.sh`
- **Disposition:** retained, partly superseded
- **Resolution:** Upstream's merge entrypoint, merge-outcome library and merge suite are materially ahead (queue-aware read-back, persisted merge authority, proof-before-report), so they replace the private copies. The private captain-assignment and landing-receipt behavior in `bin/fm-pr-check.sh` is kept and spliced onto them; upstream already honors `FM_PR_ASSIGN_CAPTAIN=0`.

### 46. `agy-harness-preflight` - Harness adapters

- **Commit:** `51d33642` (9 files changed, 1377 insertions(+), 103 deletions(-))
- **Inventory entry:** `docs/private-divergence.json`; provenance `69e375e`
- **Invariant it protects:** Every agy launch is gated on an authentication preflight, because agy has no interrupt or exit control path on tmux to recover a launch that started unauthenticated.
- **Carries:** 10 paths; 30 conflict hunks resolved at intake
- **Paths it owns:** `.agents/skills/harness-adapters/SKILL.md`, `.agents/skills/harness-adapters/references/harness/agy.md`, `bin/fm-agy-lib.sh`, `bin/fm-busy-lib.sh`, `bin/fm-composer-lib.sh`, `bin/fm-spawn.sh`, `bin/fm-test-run.sh`, `docs/documentation-audiences.json`, `tests/fm-agy-preflight.test.sh`, `tests/fm-spawn-dispatch-profile.test.sh`
- **Disposition:** retained (the preflight only), otherwise superseded
- **Resolution:** Both homes wired agy independently and the two adapters disagreed on every axis, so this is the one entry where the whole surface had to be chosen rather than merged. Upstream's adapter wins, because its verification is newer and wider (agy 1.2.0 on Linux, 2026-09-10) and its own suite is the executable contract this seed inherits: `/quit` as the exit verb, the anchored `agy` process name that lets the tmux adapter attribute the pane so `fm-control` no longer refuses there, the rendered-tail busy fallback in place of this home's permanently closed `fm_busy_agy_verified` gate, and `--effort low|medium|high` both at launch and in dispatch-profile validation.
  Retained on top: `bin/fm-agy-lib.sh`'s authentication preflight. agy picks its credential store per process and firstmate's workers are always SSH-detected, so an unauthenticated lane parks a worker on an interactive OAuth prompt forever instead of failing - a concrete failure this home hit and upstream has no answer for. The preflight refuses where upstream launches unvalidated, because an unreachable listing and a signed-out lane are indistinguishable from an exit status and parking a worker is the worse outcome; upstream's three listing cases are re-pointed at that contract in the same commit.
  Consequences recorded rather than hidden: this home's `/exit` verb, its `resolve_agy_binary` PATH-plus-`~/.local/bin` fallback, its Herdr-only control claim in `AGENTS.md`, its tmux-refusal case, and its closed busy gate are all dropped. Two of this home's agy fixtures no longer drive a full launch, because upstream's launch path waits on folder trust and a working indicator that those fixtures do not render; each now asserts the preflight property it actually owns.

## What this series deliberately does NOT carry

Every drop below is a supersession, recorded so a later reader can re-open it rather than rediscover it.

1. **`fm_backend_herdr_pane_agent_exited` and its documentation** (`herdr-native-submit-proof`).
   Upstream's `stale-agent` presence state proves the same thing earlier and in more places. The real-Herdr
   e2e guard that pinned the behavior is kept and now reads it through upstream's classifier.
2. **The live-over-terminal run-selection rule** in `bin/fm-nm-run-lib.sh` and its three portable cases
   (`rate-limit-classification`, `residual-private-drift`). Upstream's identity-aware `fm_nm_select_run`
   answers the same question from run identity rather than from a liveness heuristic, and
   `bin/fm-crew-state.sh` calls it before the coarse ledger.
3. **Forge-state classification on the `axi status` `passed` path** (`pr-forge-state-classification`).
   Upstream's `passed_pr_detail` reads GitHub and GitLab and reports `done` with the PR's real state in
   the detail, which is what AGENTS.md section 7 says a passed run is. The private mapping - closed
   unmerged reads `failed`, open reads `working` - is kept on the coarse `completed` ledger path, where
   upstream has no equivalent, and dropped on the `passed` path. **This is the one drop that changes a
   captain-visible verdict**: on the `axi status` path a PR closed without merging now reports as a passed
   run whose detail says `run passed: PR closed`, not as a failure. Worth re-opening after cutover.
4. **This home's five-shard, self-hosted CI shape and its `ovh-firstmate` timing evidence**
   (`lint-guard-ci`). The fork has no self-hosted runner; upstream's nine-shard hosted layout and
   three-tier timeout policy are the correct baseline for it.
5. **`bin/fm-mail-check.sh` and its suite** (`mail-check-arm`) - superseded whole; see entry 31.
6. **`bin/fm-backlog-transition-lib.sh` and `bin/fm-backlog-handoff.sh`** (`backlog-transitions`) -
   superseded whole; upstream carries this home's refactor plus a bounded read on top.

## The integration and repair commits

Eleven commits are not any one entry's own work. They fix seams no single reconciliation could see -
each one found by running the suites, not by reading the diff:

- `fm_merge_outcome_report` now takes upstream's `[authority]` **and** this home's four receipt anchors,
  and both call sites (`bin/fm-pr-merge.sh`, `bin/fm-watch.sh`) pass them. Upstream's signature and this
  home's receipt body had been merged into one function that referenced parameters it never declared.
- One `agy)` arm in `fm_control_harness_family`; upstream and this home had each added it.
- Two fixture leftovers from superseded reconciliations (`FM_FAKE_GH_STATE`, `clone_theta`), removed so
  upstream's full-set CI lint stays clean.
- `fm_merge_outcome_receipt` and its bounded attempt ledger, restored: resolving that library's header
  to upstream had dropped the private helper definitions its retained receipt body calls. Caught by
  `tests/fm-pr-merge.test.sh`.
- `tests/fm-pr-merge.test.sh`'s private merge-commit case, repointed at upstream's stricter entrypoint.
  Upstream refuses an `--auto` extra argument outright, and reads the pull request's state before
  merging rather than only after; the case now passes `--merge` alone and its fake answers that read.
  The invariant the case exists for - a schema that rejects the `mergeCommit` selection must not lose
  the queue-aware outcome - is one upstream implements explicitly in `github_read_merge_commit`.
- Fixtures the reconciled contracts now bind, in `tests/fm-captain-hold-lifecycle.test.sh` and
  `tests/fm-afk-return.test.sh`: `--claims-checked` where an origin has a filed report, the shared
  fold read with the row's kind, a landing receipt seeded in the three fixtures that stamp a merged
  ship task by hand, and a project registry plus a separate stderr capture for the Bearings read.
- The whole agy surface (entry 46), and with it the calm mod's operational-input port, which had
  fallen a kind behind its shell owner.
- `tests/fm-kimi-harness.test.sh`'s spawn cases, guarded on the same python3 `tomllib` host
  requirement its hook cases already use. Upstream's own tree fails this suite on a host with
  python3 below 3.11; the guard is the suite's own existing pattern, applied where it was missing.
- `fm_merge_outcome_receipt` and its bounded attempt ledger, restored: resolving that library's
  header to upstream had dropped the private helper definitions its retained body calls, so a proved
  merge could not record its receipt.
- `FM_STALE_AUTO_STANDDOWN_THRESHOLD`'s default in the watcher, restored, and the sixth argument at
  one `wedge_timer_check` call site. Without the first, every wedge escalation died at that line
  under `set -u` and a wedged worker went unreported; without the second, the rate-limit resume path
  aborted its poll.
- The landing-receipt writer's own stderr, folded into `bin/fm-pr-check.sh`'s one actionable line
  instead of leaking beside it.
- Landing receipts seeded in the upstream fixtures the receipt gate now binds
  (`fm-public-followup`, `fm-remote-secondmate-parent-binding`, `fm-teardown-endpoint-safety`), and
  this home's `fm_merge_outcome_report` calls in `tests/fm-receipt.test.sh` given the reconciled
  signature's explicit authority argument.
- `tests/fm-backend-herdr.test.sh`'s native-idle case, asserting this home's retained
  `herdr-native-idle-unknown` verdict rather than upstream's idle mapping.
- `tests/fm-spawn-dispatch-profile.test.sh`'s agy case retired to the adapter suite that owns it,
  and that suite's fake `timeout` taught to drop options and the duration before exec'ing.

## Local `main`

Per this task's recorded deviation, no fast-forward onto local `main` is required or performed: the
landing for this work is the public rewrite, not a local merge. At the time of writing, local `main` is
`db19959e`, which is `origin/main`; this branch is rooted on upstream instead and shares no lineage with
it by design.

## Publishing

`push-route-b.sh` performs the rewrite and nothing else. Its default mode is a dry run; push mode needs
both `--push` and a typed confirmation phrase. It re-checks every precondition in both modes - clean tree,
upstream ancestry, merge base equal to the upstream tip, all 73 upstream-added files present, remote
readable - and takes `--force-with-lease` against the exact public SHA it read in the same run, so a
public `main` that moved is refused rather than overwritten.

This branch's worker never ran it in push mode and never contacted `ansellchiu/firstmate-fork`.
