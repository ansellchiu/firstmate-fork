# Pi primary session growth baseline

Audience: maintainer verification.

This record is the measurement the Pi primary-session circuit breakers are calibrated from.
`.pi/extensions/lib/fm-primary-growth.ts` owns the thresholds and `docs/pi-primary-growth.md` owns the operating contract; this file owns only the evidence that the numbers in them are measured rather than chosen.

Re-running the command below reproduces the report.
When it produces materially different percentiles, the thresholds are re-derived from the new report and this record is replaced, rather than the thresholds being adjusted on their own.

## Command

Measured on 2026-09-02 against Pi 0.84.4 on macOS, over the local Pi transcript corpus at `~/.pi/agent/sessions`.

```sh
bin/fm-pi-session-metrics.sh --summary
```

## Observed output

```json
{
  "sessionsRead": 110,
  "sessionsMeasured": 81,
  "assistantMessageFloor": 20,
  "cacheReadPerAssistantMessage": {
    "p50": 75501,
    "p75": 139970,
    "p90": 191405,
    "p95": 256570,
    "max": 460159
  },
  "eventsPerHour": {
    "p50": 322,
    "p90": 722,
    "max": 1363
  },
  "events": {
    "p50": 142,
    "p90": 934,
    "p99": 11298,
    "max": 11298
  },
  "recordedEvents": {
    "p50": 136,
    "p90": 914,
    "p99": 11265,
    "max": 11265
  },
  "byCompaction": {
    "0": {
      "sessions": 70,
      "medianCacheReadTokens": 3664896,
      "medianCacheReadPerAssistantMessage": 73159,
      "maxEvents": 2109,
      "maxRecordedEvents": 2092
    },
    "1": {
      "sessions": 8,
      "medianCacheReadTokens": 53687232,
      "medianCacheReadPerAssistantMessage": 177107,
      "maxEvents": 4158,
      "maxRecordedEvents": 4150
    },
    "2+": {
      "sessions": 3,
      "medianCacheReadTokens": 1316054205,
      "medianCacheReadPerAssistantMessage": 434556,
      "maxEvents": 11298,
      "maxRecordedEvents": 11265
    }
  }
}
```

## What the measurement establishes

Cache re-reads dominate the bill.
Across the measured corpus, cache-read tokens outweigh fresh input tokens by roughly two orders of magnitude, so a session's cost is mostly the cost of re-sending itself, and how far the conversation has grown is the variable worth watching.
That ratio is not in the summary either; it is `cacheReadTokens` against `inputTokens` summed over the measured per-session rows of a full run, which came to 140x.

Compaction count separates ordinary sessions from runaway ones, and the separation is at the second compaction, not the first.
A session's median total cache-read cost was 3,664,896 tokens with no compaction, 53,687,232 with one, and 1,316,054,205 with two or more.
The step from zero to one multiplies it by about 15; the step from one to two or more multiplies it by about 25 again.
One compaction is also common - 8 of 81 measured sessions - while two or more is rare at 3 of 81.
Rotating on the first compaction would therefore churn a tenth of all ordinary sessions to avoid a cost that had not yet arrived.

Cache-read per assistant message tracks the same separation more smoothly: 73,159 at the median for sessions that never compacted, 177,107 for those compacted once, and 434,556 for the runaway class.
It separates the classes well enough to warn on, but it does not arrive before compaction reliably.
A top-decile threshold sits above the 177,107 median of the once-compacted class, so half of that population reaches its first compaction without crossing it.
That is why it is a warning and the compaction count is the trigger, rather than the other way round.

Total event count does not separate the classes on its own.
One session in the two-or-more class carried only 1,078 recorded events, fewer than several sessions that never compacted at all; like the 5,920 below, that number comes from the per-session rows of a full run rather than from the summary, which reports only a maximum per compaction bucket.
What the corpus does establish is a ceiling.
The event axis is measured as `recordedEvents`, whose membership test is whether Pi emits `message_end` for the record: the message roles, the custom messages Pi emits `message_end` with role `custom` for, and compaction.
The setting-change and session-header records are excluded because Pi emits no message for them, so the live breaker never sees them.
That makes `recordedEvents` the same quantity the live counter accumulates, and the ceiling is therefore derived from exactly the quantity the threshold is applied to.
An earlier revision of this record excluded custom messages from `recordedEvents` on the premise that the breaker had no event for them; that premise was wrong, and correcting it is what moved the recorded figures here.
The move for a session is exactly its `eventClasses.custom` count in the per-session rows of a full run, which across the measured rows is 0 at the median and 94 at most.
No session below the runaway class exceeded 4,150 recorded events (`byCompaction."1".maxRecordedEvents` above, against 2,092 for the never-compacted bucket), and the runaway class reached 11,265 (`byCompaction."2+".maxRecordedEvents`).
The lower of the two runaways carried 5,920, which the summary does not emit; it comes from the per-session rows of a full run, `bin/fm-pi-session-metrics.sh` with no `--summary`, reading `recordedEvents` for the rows with `compactions` of 2 or more.

## Thresholds derived from it

| Level | Trigger | Threshold | Evidence in the report above |
| --- | --- | --- | --- |
| Soft | `cache_reread` | 200,000 cache-read tokens per assistant message | The 90th percentile is 191,405 against a median of 75,501, so this is the top decile and roughly 2.6x an ordinary session. |
| Soft | `quota_runway` | any window quota-axi projects to exhaust before it resets | No constant is invented here. quota-axi computes the projection and reports `runway.status`; the policy reads it. |
| Hard | `compaction` | 2 compactions | The 25x cost step from one compaction to two or more, and the 8-of-81 versus 3-of-81 frequency split. |
| Hard | `event_growth` | 5,000 recorded events | Above the 4,150 ceiling of every ordinary session measured (`byCompaction."1".maxRecordedEvents`), and below the runaway class at 11,265 (`byCompaction."2+".maxRecordedEvents`). The lower runaway at 5,920 comes from the per-session rows of a full run, as noted above. |

The soft cache threshold is applied to the same cumulative estimator this report measures - total cache-read tokens divided by total assistant messages - because a threshold measured on cumulative averages is only meaningful applied to cumulative averages.
That makes the signal lag a sudden change by design; the hard triggers, not this one, are what catch a session that has already gone wrong.

## Provider attribution

Verified on 2026-09-01 against quota-axi 0.1.x and Pi 0.84.4.

```sh
quota-axi auth
```

Observed output, abridged to the rows that establish the binding:

```text
auth[16]{provider,source,path,status,error}:
  claude,oauth-file,~/.claude/.credentials.json,invalid,none
  claude,keychain,none,available,none
  codex,auth-json,~/.codex/auth.json,available,none
  codex,cli-rpc,~/.local/bin/codex,available,none
  grok,auth-json,~/.grok/auth.json,available,none
  grok,"pi:xai",none,available,none
  kimi,"pi:kimi-coding",none,missing,none
  zai,"pi:zai",~/.pi/agent/auth.json,available,none
  deepseek,"pi:deepseek",~/.pi/agent/auth.json,available,none
```

quota-axi publishes the binding itself: a `pi:<provider>` credential source names the Pi login that quota-axi provider meters.
That establishes `grok` for Pi's `xai`, `zai` for `zai`, `deepseek` for `deepseek`, and `kimi` for `kimi-coding`.

It also establishes what is NOT bound.
`codex` reads `~/.codex/auth.json` and the Codex CLI, not a `pi:` source, so quota-axi does not claim to meter Pi's `openai-codex` login and nothing local proves the two are the same ChatGPT account.
`claude` reads the Claude credential file and Keychain, and Pi's own provider documentation states that third-party harness usage on an Anthropic subscription draws from extra usage billed per token rather than against the Claude plan limits, so those windows would not bound Pi's `anthropic` traffic either.

The Pi provider ids observed in the measured corpus were `anthropic`, `deepseek`, `ollama`, `openai-codex`, `xai`, and `zai`.
Under the binding above, three of those six carry quota attribution and three do not, which is why an unbound provider produces silence rather than a warning derived from another account.

## Privacy

The measurement reads transcripts and keeps only aggregates.
`bin/fm-pi-session-metrics.mjs` enforces that against its own declared field list, and `tests/fm-pi-session-metrics.test.sh` asserts it by measuring a transcript stuffed with prompts, replies, tool output, compaction summaries, paths, and project names, then requiring that none of them appear anywhere in the report.
