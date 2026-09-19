# Pi primary session growth and circuit breakers

Audience: maintainer architecture.

A primary Pi session re-sends its whole conversation on every turn.
Firstmate deliberately keeps that conversation long-lived so the re-send stays cached, which is cheap.
What the measurement in [`docs/verification/pi-primary-growth-baseline.md`](verification/pi-primary-growth-baseline.md) shows is that the cheapness has a cliff: past a point the conversation is compacted, the cached prefix stops matching, and the session pays to re-read a transcript that is no longer helping it.
This document owns how firstmate watches for that cliff and what it does when a session crosses it.

The equivalent policy for the supervision branch is a separate mechanism with its own thresholds; see [`docs/pi-supervision-branch.md`](pi-supervision-branch.md) "Rotation".
The two do not share code and are not meant to: a branch conversation and a primary conversation grow for different reasons and are safe to replace at different moments.

## Ownership

| Concern | Owner |
| --- | --- |
| The measurement, and the privacy boundary on reading transcripts | `bin/fm-pi-session-metrics.sh`, with `bin/fm-pi-session-metrics.mjs` as its core |
| The measured baseline the thresholds come from | [`docs/verification/pi-primary-growth-baseline.md`](verification/pi-primary-growth-baseline.md) |
| The thresholds and the decision | `.pi/extensions/lib/fm-primary-growth.ts` |
| Every side effect: warnings, knowledge capture, rotation | `.pi/extensions/fm-primary-growth.ts` |
| Whether this session is the primary at all | `.pi/extensions/lib/fm-primary-session-lock.ts` |
| Quota windows, resets, remaining percentages, and runway projections | `quota-axi` |
| Choosing an eligible model or provider | [`.agents/skills/quota-array-dispatch/SKILL.md`](../.agents/skills/quota-array-dispatch/SKILL.md) |

## Levels

Two levels, and they do different jobs.

A **soft** level is a warning.
It changes nothing, requires nothing of the turn it arrives in, and is delivered once per conversation per reason so it stays a notice rather than a nag.

- `cache_reread` fires when cumulative cache-read tokens per assistant message cross the measured top decile. It is a top-decile alarm rather than a guarantee of early arrival: the measured median for a session compacted once is below the threshold, so half of that population reaches its first compaction unwarned, and the hard compaction trigger is what actually guards against the runaway class.
- `quota_runway` fires when quota-axi projects a window to run out before it resets. Nothing here recomputes that projection, and it only fires when quota-axi is actually metering this session's provider; see "Attributing quota to this session" below.

A **hard** level asks for a rotation: the conversation is replaced with a fresh one.

- `compaction` fires on the second compaction. The first is ordinary; the second is what the measurement identifies as the runaway class.
- `event_growth` fires above the event ceiling of every ordinary session measured, so a conversation growing without bound is caught even when compaction has not fired.
  It counts the coarse classes this mechanism is actually fed, which is the same `recordedEvents` quantity the measurement reports, so the threshold is applied to the estimator it was derived from.

Hard outranks soft, and within each level the order is fixed, so the same state always produces the same reason.

## Attributing quota to this session

Pi and quota-axi do not share an identifier vocabulary.
Pi calls its xAI subscription login `xai`; quota-axi calls the same subscription `grok`.
Guessing across that gap would be inventing quota evidence, so the binding is read from quota-axi's own `auth` report instead: a credential source of the form `pi:<provider>` is quota-axi stating outright which Pi login that provider meters.
The mapping therefore stays correct as quota-axi gains providers, rather than drifting against a table copied here.

Verified on 2026-09-01 against quota-axi's published sources, `grok` binds to Pi's `xai`, `zai` to `zai`, `deepseek` to `deepseek`, and `kimi` to `kimi-coding`.

A Pi provider quota-axi does not publish a `pi:` source for resolves to no binding and therefore to no quota warning, even when a similarly-named quota-axi provider exists.
Pi's `openai-codex` and quota-axi's `codex` are the case worth naming: quota-axi reads the Codex CLI's own credential at `~/.codex/auth.json`, which nothing local proves is the same ChatGPT account as Pi's login.
Pi's `anthropic` provider is a second case, and its own documentation is the reason: third-party harness usage on an Anthropic subscription draws from extra usage billed per token rather than against the Claude plan windows quota-axi reports, so those windows would not bound it.
In both cases a warning derived from the wrong account is worse than no warning, so the mechanism stays quiet.

`FM_PI_GROWTH_QUOTA_PROVIDER` names a quota-axi provider explicitly for an operator who can confirm a binding the tools do not publish.
It is deliberately manual: only the operator knows whether two separate logins are the same account.

## The two safety properties

**A rotation can never split a bounded action.**
The decision is consulted only at `agent_settled`, which Pi fires once the agent has stopped streaming with no tool call in flight.
It is then refused again unless the extension context still reports idle with nothing queued, so a wake that arrived during the settle defers the rotation rather than being discarded by it.
The policy module cannot rotate at all - it is pure and has no side effects - so the only place a mid-action rotation could originate is the extension, and there it is gated twice.

**A rotation can never drop supervision.**
Rotation goes through Pi's own session replacement, the same path `/new` takes.
That path is already owned: `.pi/extensions/fm-primary-pi-watch.ts` binds one watcher generation per session activation and re-arms on the replacement's `session_start`, and `.pi/extensions/fm-primary-turnend-guard.ts` re-emits the session-start context into the replacement so it re-reads the durable records before it acts.
This mechanism deliberately adds no second path for either.
Pi exposes session replacement only to a command handler, which is why the extension registers `fm-primary-rotate` and dispatches it rather than replacing the session from an event handler.

## The rotation sequence

1. At a settled, quiet boundary with a hard decision, the extension asks the session to capture durable knowledge now with `/stow` and states plainly that the conversation is about to be replaced.
   The capture is the session's own work in its own words; an extension cannot write what a session learned.
2. At the next settled boundary - so the capture turn has completed - the extension dispatches `/fm-primary-rotate`.
3. The command handler re-checks that this session still holds the home's helm, waits for idle, and replaces the conversation.
4. The replacement's `session_start` resets every counter to zero.

Step 4 is what makes a rotation loop structurally impossible rather than merely unlikely: no counter survives into the session a rotation produced.
If the request is not acted on, the extension re-issues it for a bounded number of settled boundaries and then stands down with one loud line, leaving the conversation exactly as it was.
A dispatch that never produces a replacement is the same case and ends the same way: a refused or failed handler leaves the request re-issuable, and a dispatch nothing ever acts on keeps spending that same bounded budget rather than leaving the breaker silent.
A rotation the operator cancels is not that case: a cancel is an answer, so the extension stands down for that conversation immediately rather than spending the rest of the budget re-asking someone who has already replied.
A circuit breaker that nags forever is worse than one that gives up loudly.

## Model-change recommendations

A quota warning carries a recommendation to reconsider the model, and deliberately nothing more.
The policy module cannot name a target provider or model - the field is structurally `null` - and the extension never changes the model.

That is the enforceable form of two boundaries.
The Harm-or-Duty boundary a model carries must survive any change, and protected material must never be silently routed to a provider that is not eligible to hold it.
A recommendation that cannot name a destination cannot route anything anywhere, so neither boundary can be crossed by this code path.
Choosing an eligible destination stays with `quota-array-dispatch`, which reads current quota evidence and applies the eligibility gates this mechanism has no access to.

## Scope

`quota-axi` and Codeburn are visibility inputs here, not enforcement owners.
They report what has been spent and what remains; nothing in this mechanism asks them to cap anything, and their numbers are read rather than re-derived.

An API gateway such as LiteLLM is outside this mechanism entirely.
The usage being bounded here rides Pi, Claude, Codex, and Gemini OAuth subscriptions, which a gateway sitting on API-key traffic cannot see or cap.
A gateway becomes worth adding when direct metered API-key traffic is materially active and lacks an existing hard or prepaid cap, which is a different problem from this one.

## Inertness and configuration

Everything under `.pi/extensions` auto-loads for any Pi session started in a firstmate checkout, including a crewmate working in a disposable worktree of the firstmate repo.
This mechanism is inert in any session that does not hold the home's session lock, which is the only signal that structurally distinguishes the session that took the helm from a worker that happens to be inside the repo.

There is no configuration file.
Thresholds are environment variables, and malformed input always falls back to the measured default rather than silently disabling a breaker.

| Variable | Effect |
| --- | --- |
| `FM_PI_GROWTH` | `0` disables every breaker; the session then behaves as it did before. |
| `FM_PI_GROWTH_CACHE_READ_PER_MESSAGE` | Soft cache-read threshold. `0` disables that axis only. |
| `FM_PI_GROWTH_COMPACTIONS` | Hard compaction threshold. `0` disables that axis only. |
| `FM_PI_GROWTH_EVENTS` | Hard event-count threshold. `0` disables that axis only. |
| `FM_PI_GROWTH_QUOTA_PROVIDER` | An operator-confirmed quota-axi provider for this session, when the tools publish no binding. Unset means no quota warning for an unbound provider. |

`state/.pi-primary-growth` is an observational record of the last decision and the rotation count.
Nothing reads it back into a decision, so it is safe to delete.

## Re-measuring

```sh
bin/fm-pi-session-metrics.sh --summary          # the calibration baseline
bin/fm-pi-session-metrics.sh --summary --quota  # the same, with a quota snapshot
bin/fm-pi-session-metrics.sh                    # per-session aggregate rows as well
```

The report keeps aggregates only.
Prompts, replies, tool names, tool arguments, tool results, compaction summaries, file paths, project names, the working directory, and the session directory name are read past and never emitted, and `tests/fm-pi-session-metrics.test.sh` asserts that by measuring a transcript stuffed with all of them.
