#!/usr/bin/env bash
# fm-quota-unmetered.sh - report the credentialed agent providers `quota-axi`
# does not meter, in quota-axi's own schema v3 provider shape.
#
# `quota-axi` compiles its provider adapters in and exposes no plugin, config,
# or discovery surface, so its provider set is fixed at claude, codex, cursor,
# copilot, grok, and kimi. A dispatch intake that also routes to Z.ai GLM,
# DeepSeek, or Gemini (agy) therefore reads no quota at all for those providers
# and only learns it is out of room when a worker takes an HTTP 429. This
# script closes exactly that gap and nothing else: it is a companion report,
# never a replacement, and it never re-reads, wraps, or contradicts
# `quota-axi`.
#
# The output is deliberately byte-compatible with `quota-axi --json` (schema
# version 3, the same `providers[]` record shape) so one consumer can read both
# with one parser. The `zai`, `deepseek`, and `gemini` provider ids are outside
# quota-axi's own closed `ProviderId` union, which is what identifies these
# records as coming from here rather than from quota-axi.
#
# This script reports observed provider data and renders no verdict. It ranks
# nothing, routes nothing, and never decides whether a dispatch candidate is
# eligible; the dispatching first mate owns that judgment through
# .agents/skills/quota-array-dispatch/SKILL.md.
#
# What each provider can and cannot report is a provider fact, not a choice made
# here, and an unreadable provider is reported as unknown rather than filled in:
#
#   zai       Z.ai GLM coding plan. `GET /api/monitor/usage/quota/limit` returns
#             real usage windows (a 5-hour cycle and a weekly cycle) with a
#             provider-reported percent used and a reset time, so this provider
#             gets genuine `windows[]` and a computed effective remaining
#             percentage.
#   deepseek  `GET /user/balance` returns account balance ONLY. DeepSeek
#             publishes no usage-window, quota-cycle, or rate-limit query
#             endpoint; its limits are per-account concurrency ceilings that are
#             observable only as an HTTP 429 at request time. So this provider
#             reports `credits` with an EMPTY `windows[]` and `quotaSemantics`
#             status `unknown`. Balance is not quota, and it is never presented
#             as one.
#   gemini    agy (Google's Gemini CLI, branded Antigravity CLI) authenticates
#             via OAuth, not an API key, and publishes no usage-quota or
#             billing-query endpoint at all yet, so this provider makes no
#             network call. It reports an EMPTY `windows[]` and `quotaSemantics`
#             status `unknown`, the same honest-unknown shape as DeepSeek's.
#             `state.authStatus` reflects the captain's confirmed OAuth login
#             (2026-08-19) rather than a live read, and says so in `state.error`.
#             This changes the moment a Cloud Billing export is wired.
#
# No provider's percentages, windows, resets, or plan are ever synthesized,
# defaulted, or carried over from a previous run: there is no cache. For zai and
# deepseek, a missing credential, a failed call, a non-200 status, or an
# unparseable body each produce an explicit unavailable/auth_required/error
# provider record with empty windows, exactly as quota-axi reports a signed-out
# provider. gemini makes no call at all, so it is reported from record instead;
# see its bullet above.
#
# Credential handling: the zai/deepseek API key is read inside the reporting
# process and is never placed in an argv, an environment variable passed to a
# child, a temporary file, or any output. No raw provider response is printed.
# The credential is read from the first source that has it:
#   1. `ZAI_API_KEY` / `Z_AI_API_KEY`, `DEEPSEEK_API_KEY` in the environment
#   2. the Pi agent credential store, `~/.pi/agent/auth.json`
# gemini has no credential to resolve and reaches none of this handling.
#
# Every network call is hard-bounded, so a hung provider endpoint cannot wedge a
# dispatch intake.
#
# Output: one JSON document on stdout. Exit status 0 whenever a report is
# printed - including when every provider is unavailable, because an
# unavailable provider is a reported result and not a script failure, the same
# contract as `quota-axi --json`. Exit 2 on a usage error, 3 when no report
# could be produced at all.
#
# Usage:
#   fm-quota-unmetered.sh [<provider>...]
#
# Environment:
#   FM_QUOTA_UNMETERED_TIMEOUT     hard per-request bound in seconds; must be a
#                                  positive integer, otherwise the default 20 is
#                                  used. Zero is rejected because it would mean
#                                  no deadline.
#   FM_QUOTA_UNMETERED_AUTH_FILE   Pi agent credential store to read instead of
#                                  ~/.pi/agent/auth.json
#   FM_QUOTA_UNMETERED_ZAI_URL     override the Z.ai quota endpoint
#   FM_QUOTA_UNMETERED_DEEPSEEK_URL  override the DeepSeek balance endpoint
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPORTER="$SELF_DIR/fm-quota-unmetered-report.mjs"

KNOWN_PROVIDERS="zai deepseek gemini"

usage() {
  cat <<'EOF'
fm-quota-unmetered.sh - report the credentialed agent providers `quota-axi` does
not meter, in quota-axi's own schema v3 provider shape.

It is a companion to `quota-axi --json`, never a replacement: quota-axi's
adapter set is compiled in and has no plugin surface, so providers outside it
are otherwise invisible to a dispatch intake until a worker takes an HTTP 429.

Usage:
  fm-quota-unmetered.sh [<provider>...]

Providers (all of them when none is named):
  zai       Z.ai GLM coding plan - reports real 5-hour and weekly usage windows
  deepseek  DeepSeek - reports account BALANCE only; it publishes no usage
            window or rate-limit query, so its quota stays `unknown` rather
            than being inferred from balance
  gemini    Gemini (agy) - authenticates via OAuth, not an API key, and
            publishes no usage or billing endpoint yet, so it makes no network
            call and its quota stays `unknown` until a Cloud Billing export is
            wired; `state.authStatus` reflects the captain's confirmed OAuth
            login rather than a live read

Output is one JSON document on stdout, schema version 3, with the same
`providers[]` record shape as `quota-axi --json`, so one parser reads both.

This script reports observed data and renders no verdict: it ranks nothing and
never decides dispatch eligibility. A missing credential or a failed call is
reported as an explicit unavailable provider with empty windows, never as
invented usage.

Exit status: 0 whenever a report is printed, including an all-unavailable one.
2 on a usage error, 3 when no report could be produced.

Environment:
  FM_QUOTA_UNMETERED_TIMEOUT       hard per-request bound in seconds (default 20)
  FM_QUOTA_UNMETERED_AUTH_FILE     credential store to read instead of
                                   ~/.pi/agent/auth.json
  FM_QUOTA_UNMETERED_ZAI_URL       override the Z.ai quota endpoint
  FM_QUOTA_UNMETERED_DEEPSEEK_URL  override the DeepSeek balance endpoint
EOF
}

die_usage() {
  printf 'fm-quota-unmetered: %s\n' "$1" >&2
  printf 'usage: fm-quota-unmetered.sh [<provider>...]   (providers: %s)\n' "$KNOWN_PROVIDERS" >&2
  exit 2
}

REQUESTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die_usage "unknown option: $1" ;;
    *)
      case " $KNOWN_PROVIDERS " in
        *" $1 "*) ;;
        *) die_usage "no report is registered for provider '$1'" ;;
      esac
      # A repeated provider would emit two records for one provider, which no
      # schema v3 consumer expects.
      case " ${REQUESTED[*]-} " in
        *" $1 "*) die_usage "provider '$1' requested more than once" ;;
      esac
      REQUESTED+=("$1")
      shift
      ;;
  esac
done
[ $# -eq 0 ] || die_usage "unexpected argument: $1"

# A non-positive bound is not a bound, so an unparseable or zero value falls
# back to the default rather than disabling the deadline.
TIMEOUT=${FM_QUOTA_UNMETERED_TIMEOUT:-20}
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=20 ;;
esac

if ! command -v node >/dev/null 2>&1; then
  printf 'fm-quota-unmetered: node is required to produce a report\n' >&2
  exit 3
fi
if [ ! -f "$REPORTER" ]; then
  printf 'fm-quota-unmetered: reporter is missing: %s\n' "$REPORTER" >&2
  exit 3
fi

FM_QUOTA_UNMETERED_TIMEOUT="$TIMEOUT" \
  exec node "$REPORTER" ${REQUESTED[@]+"${REQUESTED[@]}"}
