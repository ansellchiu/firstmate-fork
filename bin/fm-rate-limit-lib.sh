#!/usr/bin/env bash
# fm-rate-limit-lib.sh - the ONE owner of firstmate's cross-model rate-limit
# detection contract.
#
# Why this exists: workers on GLM-5.3 hit HTTP 429 usage-limit refusals (the
# 1308 code, message "Usage") and stalled on retry/backoff while every existing
# classifier read the pane as wedged (an idle pane sits static; a busy pane
# outlives its turn-age bound), so firstmate paged false "possible wedge"
# escalations. quota-axi covers claude/codex/cursor/copilot/grok/kimi but not
# GLM or DeepSeek. A rate limit is a BOUNDED external wait - the model API
# refuses calls until the window resets - so the stall belongs to the
# declared-external-wait vocabulary (the same class as a `paused:` line), never
# the wedge path.
#
# Detection source: the worker's own pane tail, which every backend already
# captures (fm_backend_capture, 40 lines, in the watcher, the away-mode daemon,
# and fm-crew-state.sh). No quota tool is consulted: the pane is the only
# evidence that crosses all harnesses, and this home does not call another
# harness's CLI just to judge quota.
#
# Consumers classify a detected signal as stalled-on-rate-limit: surface it
# once with the signal named (NOT a wedge), then absorb it on the long
# declared-pause cadence (PAUSE_RESURFACE_SECS) so it never pages a false
# wedge and cannot rot invisibly. A missed signal degrades to the ordinary
# stale/wedge path; a false positive costs one mislabeled surface. Bias is
# toward what vendors actually emit, per model family:
#
#   glm      the usage-limit code family, named ONLY from the vendor's own
#            error envelope - the word for an error code joined to the digits
#            by punctuation or whitespace alone, which is the JSON shape the
#            API returns and the plain shape a harness echoes. 1308 is the
#            rolling 5-hour window (the 2026-08 GLM-5.3 incident) and 1310 the
#            weekly/monthly wall (the 2026-09-11 fleet incident's
#            Weekly/Monthly Limit Exhausted refusal). Structured evidence is
#            the WHOLE of it: a loose 1308/1310 elsewhere in the tail is a line
#            number, and prose about exhausted limits names no window at all,
#            so neither classifies a window on its own. A pane whose envelope
#            has scrolled out of the 40-line tail therefore does not name a
#            window: it falls to the bare-429 rule if the refusal is still
#            visible, else to the ordinary stale/wedge path - the pre-existing
#            behaviour, and the accepted cost of never mislabelling a wedged
#            worker as a multi-day wall. Independently of the envelope, a bare
#            429 ANDed with usage|rate limit|too many|quota|exceeded|exhausted
#            or the Chinese 限流/频繁/繁忙 still reports glm-429; the wall's own
#            message and reset time ride that rule when the digits are gone.
#            The 1311 refusal (model not included in your plan) rides the same
#            envelope but is deliberately NOT a signal: it never resets on its
#            own, so absorbing it as a bounded wait would rot invisibly, which
#            is the one failure this vocabulary exists to prevent. Its own
#            envelope LINES are dropped before the remaining rules read the
#            tail, so its 429 and its usage-shaped prose cannot fall through to
#            the bare-429 rule, while any OTHER refusal in the same tail (the
#            worker switched models and is now genuinely walled, or a DeepSeek
#            pane that merely quotes 1311) still matches normally. Being
#            line-scoped, that holds only while the pair lands on one captured
#            line: a pane that wraps mid-token can still read as a bare 429,
#            the residual this line-level filter cannot close.
#   deepseek rate_limit_error / "Rate limit reached. Please retry later."
#            (429), and the chat API's upstream-load saturation refusal
#            (当前分组上游负载已饱和), a quota/rate refusal of its own
#   claude   429 with rate_limit_error / "rate limit" / "too many requests"
#   generic  model=default (the incident's exact launch config) and unknown
#            models: 429 ANDed with rate limit|too many|throttle|quota|
#            exceeded|please retry, plus the GLM usage-limit code line and the
#            OpenAI-compatible rate_limit_error/rate_limit_exceeded types
#
# The model family comes from the model name in state/<id>.meta; the harness
# argument is accepted for signature evolution but does not narrow matching -
# model=default tells us nothing about the provider, so the generic rules must
# carry the GLM and DeepSeek lines by themselves.
#
# Signature policy is deliberately conservative, and each phase carries its own
# burden of proof: the vendor's error envelope is structured evidence and needs
# nothing beside it, while the bare-429 rules are AND-gates (a 429 with no
# rate-limit phrase, or a phrase with no 429, is NOT a signal). Free prose about
# limits is never evidence on its own, so build output that merely mentions
# limits cannot classify a stall.
set -u

# fm_rate_limit_signal <harness> <model> <tail> -> one canonical signal token,
# or empty. <tail> is the captured pane tail (any line count; consumers pass
# the same 40-line capture they already read for hashing/busy classification).
# Prints:
#   glm-1308            the 1308 envelope, the rolling 5-hour usage window
#                       (with or without the 429 nearby)
#   glm-1310            the 1310 envelope, the weekly/monthly wall - a
#                       multi-hour to multi-day wait, distinct from glm-1308
#                       (with or without the 429 nearby)
#   glm-429             GLM HTTP 429 with a usage/rate phrase
#   deepseek-429        DeepSeek HTTP 429 with a rate-limit phrase
#   deepseek-rate-limit DeepSeek-specific rate refusal without a bare 429
#   claude-429          Claude HTTP 429 with a rate-limit phrase
#   rate-limit          OpenAI-compatible rate_limit_error/exceeded type
#   429-rate-limit      generic HTTP 429 with a rate-limit phrase
# Exit 0 with the token on a match, 1 with empty output otherwise.
fm_rate_limit_signal() {  # <harness> <model> <tail>
  # shellcheck disable=SC2034 # harness is accepted for signature evolution and
  # call-site symmetry; model=default tells us nothing about the provider, so
  # matching must not narrow on it.
  local harness=${1:-} model=${2:-} tail=${3:-}
  local family m
  family=generic
  m=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
  case "$m" in
    *glm*|*zhipu*|*bigmodel*)         family=glm ;;
    *deepseek*)                       family=deepseek ;;
    *claude*|*opus*|*sonnet*|*haiku*) family=claude ;;
    *grok*)                           family=grok ;;
    *kimi*|*moonshot*)                family=kimi ;;
    *codex*|*gpt*)                    family=codex ;;
  esac

  # The GLM usage-limit code family, each window carrying its own token so a
  # consumer can tell a multi-hour weekly wall from a rolling 5-hour one. 1311
  # (model not included in your plan) is excluded on purpose - see the header.
  local glm_codes='1308|1310'
  # Punctuation or whitespace, and nothing else, may join the code word to its
  # digits: that join is what makes the envelope structured evidence rather
  # than two tokens that happen to share a line.
  local glm_code_join='[^0-9A-Za-z]{0,4}'
  # The GLM usage vocabulary for the bare-429 rule. An inflection that only
  # describes thoroughness (exhaustive) is not exhaustion.
  local glm_usage='usage|rate[ _-]?limit|too many|quota|exceeded|exhaust(ed|ion|s|ing)?([^a-z]|$)|限流|频繁|繁忙'
  local glm_code scan

  # Phase 1: the vendor's error envelope, the only evidence that names a
  # window. GLM's incident lines carry the pair verbatim, as JSON and as plain
  # text; match them for every model family (model=default was the 2026-08
  # incident's actual launch config). Only punctuation or whitespace may sit
  # between the code word and its digits, and the digits must stand alone, so
  # neither prose that merely names a code nor a longer number containing one
  # is evidence. A pane tail is chronological, so when a tail carries more than
  # one family code the LAST one names the current window: a worker that
  # exhausts the rolling window and then hits the weekly wall is walled, not
  # throttled.
  glm_code=$(printf '%s\n' "$tail" \
    | grep -oE "code$glm_code_join($glm_codes)([^0-9]|\$)" \
    | grep -oE "$glm_codes" | tail -1)
  if [ -n "$glm_code" ]; then
    printf 'glm-%s\n' "$glm_code"
    return 0
  fi
  # Code 1311 (model not included in your plan) is not a bounded wait - see the
  # header. Its own lines carry a 429 envelope and usage-shaped prose, so drop
  # them from what the remaining gates read; every other line in the tail is
  # still evidence, so an unrelated refusal beside a 1311 still matches.
  scan=$(printf '%s\n' "$tail" | grep -vE "code${glm_code_join}1311([^0-9]|\$)") || true
  case "$family" in
    deepseek)
      # DeepSeek chat API's upstream-load saturation refusal: a quota/rate
      # refusal even when a proxy layer reports a non-429 code.
      if printf '%s\n' "$scan" | grep -q '当前分组上游负载已饱和'; then
        printf 'deepseek-rate-limit\n'
        return 0
      fi
      ;;
  esac
  # Phase 2: a bare HTTP 429 ANDed with an explicit rate-limit phrase.
  if printf '%s\n' "$scan" | grep -qE '(^|[^0-9])429([^0-9]|$)'; then
    case "$family" in
      glm)
        printf '%s\n' "$scan" | grep -qiE "$glm_usage" \
          && { printf 'glm-429\n'; return 0; }
        ;;
      deepseek)
        printf '%s\n' "$scan" | grep -qiE 'rate[ _-]?limit|please retry|upstream|负载|限流|繁忙|quota|exceeded' \
          && { printf 'deepseek-429\n'; return 0; }
        ;;
      claude)
        printf '%s\n' "$scan" | grep -qiE 'rate[ _-]?limit|too many|overload|quota' \
          && { printf 'claude-429\n'; return 0; }
        ;;
      *)
        printf '%s\n' "$scan" | grep -qiE 'rate[ _-]?limit|too many|throttl|quota|exceeded|please retry' \
          && { printf '429-rate-limit\n'; return 0; }
        ;;
    esac
  fi

  # Phase 3: the OpenAI-compatible error type tokens on their own (no bare 429
  # in the tail). Runs after the family rules so a tail that also carries a
  # bare 429 reports the more specific family token.
  if printf '%s\n' "$scan" | grep -qiE 'rate_limit_error|rate_limit_exceeded'; then
    printf 'rate-limit\n'
    return 0
  fi
  return 1
}
