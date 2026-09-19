#!/usr/bin/env bash
# tests/fm-rate-limit.test.sh - cross-model rate-limit (HTTP 429 / the GLM
# usage-limit code family) detection and the stalled-on-rate-limit
# classification: the pure
# signature table (bin/fm-rate-limit-lib.sh, the ONE owner), then the
# always-on watcher's behavior - a rate-limited pane surfaces once with the
# signal named (never as a possible wedge), absorbs on the long cadence while
# the signal persists, and resumes ordinary wedge aging once the pane clears.
# Away-mode (daemon) classification lives in fm-daemon.test.sh; the crew-state
# paused-with-reason read is covered in fm-crew-state.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-rate-limit-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-rate-limit-tests)

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure signature table (bin/fm-rate-limit-lib.sh) ------------------------

test_rate_limit_signal_glm() {
  # The 2026-08 GLM-5.3 incident's exact shape: model=default, HTTP 429 with
  # code 1308 Usage - the generic code-1308 rule must catch it without a model
  # family hint.
  [ "$(fm_rate_limit_signal pi default $'HTTP/1.1 429 Too Many Requests\n{"error":{"code":"1308","message":"Usage"}}')" = glm-1308 ] \
    || fail "GLM code 1308 Usage not detected under model=default"
  # Same line under an explicit glm model name.
  [ "$(fm_rate_limit_signal pi glm-5.3 $'429 code 1308 Usage')" = glm-1308 ] \
    || fail "GLM code 1308 Usage not detected under glm-5.3"
  # A loose 1308 is not evidence, even beside a usage phrase: only the vendor's
  # envelope - the code word joined to its digits - names a window.
  [ -z "$(fm_rate_limit_signal pi glm-4.6 $'err: 1308 usage limit reached')" ] \
    || fail "a loose 1308 beside a usage phrase named a window"
  # 429 + usage phrase under glm.
  [ "$(fm_rate_limit_signal pi glm-5.3 $'HTTP 429\nusage exceeded for this period')" = glm-429 ] \
    || fail "GLM 429 + usage phrase not detected"
  # 429 + Chinese rate-limit phrase under glm.
  [ "$(fm_rate_limit_signal pi glm-4.5 $'429\n请求过于频繁，请稍后重试')" = glm-429 ] \
    || fail "GLM 429 + Chinese rate phrase not detected"
  # A bare 1308 without any usage/rate phrase is NOT a signal.
  [ -z "$(fm_rate_limit_signal pi glm-4.6 'line 1308 of output')" ] \
    || fail "bare 1308 without a usage/rate phrase false-matched"
  pass "GLM signals: the 1308 envelope (incident shape, explicit model), 429+phrase, Chinese; a loose 1308 never names a window"
}

test_rate_limit_signal_glm_weekly_wall() {
  # The 2026-09-11 fleet incident's exact shape: five GLM workers walled on the
  # weekly/monthly limit. The refusal carries code 1310 inside a 429 envelope,
  # and the pane wraps the message across lines.
  local wall=$'Error: 429: {"code":"1310","message":"Weekly/Monthly Limit\nExhausted. Your limit will reset at 2026-09-11 22:50:01"}'
  [ "$(fm_rate_limit_signal pi glm-5.3-flash "$wall")" = glm-1310 ] \
    || fail "GLM code 1310 weekly wall not detected under glm-5.3-flash"
  # model=default carries no provider hint, so the code rule must catch it too.
  [ "$(fm_rate_limit_signal pi default "$wall")" = glm-1310 ] \
    || fail "GLM code 1310 weekly wall not detected under model=default"
  # The retry-exhausted variant the same panes emitted.
  [ "$(fm_rate_limit_signal pi glm-5.3-flash $'Error: Retry failed after 3 attempts: 429:\n{"code":"1310","message":"Weekly/Monthly Limit Exhausted.\nYour limit will reset at 2026-09-11 22:50:01"}')" = glm-1310 ] \
    || fail "GLM retry-exhausted 1310 variant not detected"
  # The envelope names the window on its own, with no 429 beside it.
  [ "$(fm_rate_limit_signal pi glm-5.3-flash $'{"code":"1310","message":"Weekly/Monthly Limit Exhausted.\nYour limit will reset at 2026-09-11 22:50:01"}')" = glm-1310 ] \
    || fail "the 1310 envelope without an adjacent 429 not detected"
  # A tail scrolled past the envelope names no window: the refusal's prose is
  # not evidence of WHICH window, so such a pane keeps the bare-429 rule (here,
  # with the 429 still visible) or the ordinary stale path (without it).
  [ "$(fm_rate_limit_signal pi glm-5.3-flash $'Error: 429:\nWeekly/Monthly Limit\nExhausted. Your limit will reset at 2026-09-11 22:50:01')" = glm-429 ] \
    || fail "the wall's message beside a 429 lost its bounded-wait classification"
  [ -z "$(fm_rate_limit_signal pi glm-5.3-flash $'Weekly/Monthly Limit\nExhausted. Your limit will reset at 2026-09-11 22:50:01')" ] \
    || fail "wall prose with no envelope and no 429 named a window anyway"
  # The weekly wall reports a DIFFERENT token from the 5-hour window, so a
  # consumer can tell a multi-day wait from a rolling one.
  [ "$(fm_rate_limit_signal pi glm-5.3-flash "$wall")" \
      != "$(fm_rate_limit_signal pi glm-5.3-flash '429 code 1308 Usage')" ] \
    || fail "the weekly wall and the 5-hour window report the same token"
  # Prose about an exhausted window names no window, whichever window it is.
  [ -z "$(fm_rate_limit_signal pi glm-5.3 $'daily quota exhausted for tool calls\nthe counter will reset at midnight')" ] \
    || fail "an exhausted daily quota was reported as the weekly wall"
  [ -z "$(fm_rate_limit_signal pi glm-5.3 'Usage limit exhausted for the 5-hour window. Your limit will reset at 14:00')" ] \
    || fail "an exhausted 5-hour window was reported as the weekly wall"
  # Ordinary worker output: a compiler error at line 1310 and a harness retry
  # message are two common tokens, not a multi-day provider wall.
  [ -z "$(fm_rate_limit_signal pi glm-5.3 $'src/a.ts:1310:2 error TS2345: bad argument\nexhausted all retries')" ] \
    || fail "a compiler error at line 1310 plus a retry message named the weekly wall"
  # A bare 1310 with no usage/limit vocabulary is NOT a signal.
  [ -z "$(fm_rate_limit_signal pi glm-4.6 'line 1310 of output')" ] \
    || fail "bare 1310 without a usage/limit phrase false-matched"
  # Code 1311 (model not included in your plan) rides the same 429 envelope but
  # never resets on its own, so it must stay on the ordinary escalation path.
  [ -z "$(fm_rate_limit_signal pi glm-5.3-flash $'Error: 429: {"code":"1311","message":"Model not included in your plan"}')" ] \
    || fail "GLM code 1311 (not a bounded wait) was classified as a rate limit"
  # ...including when its own message carries the shared usage vocabulary, which
  # would otherwise fall through to the bare-429 gate and be absorbed as a wait.
  [ -z "$(fm_rate_limit_signal pi glm-5.3-flash $'HTTP/1.1 429\n{"code":"1311","message":"Model not included in your plan: quota exceeded for this model"}')" ] \
    || fail "GLM code 1311 with usage prose fell through to the bare-429 gate"
  # Only the 1311 refusal's own lines are discounted: a worker that hit 1311,
  # switched models, and is NOW genuinely walled is still a bounded wait.
  [ "$(fm_rate_limit_signal pi glm-5.3-flash $'{"code":"1311","message":"Model not included in your plan"}\nswitching model...\nHTTP 429 Too Many Requests: usage limit')" = glm-429 ] \
    || fail "a genuine 429 beside an older 1311 was suppressed"
  # ...and a GLM-specific code never silences another family's own refusal.
  [ "$(fm_rate_limit_signal pi deepseek-chat $'code 1311 nope\n当前分组上游负载已饱和')" = deepseek-rate-limit ] \
    || fail "code 1311 suppressed DeepSeek's own saturation refusal"
  [ "$(fm_rate_limit_signal claude opus $'Error: 429: {"code":"1311","message":"Model not included in your plan"}\n429 rate limit exceeded')" = claude-429 ] \
    || fail "code 1311 suppressed a genuine Claude 429"
  # A tail is chronological: a worker that exhausts the rolling window and then
  # hits the weekly wall is walled, so the LAST family code names the window.
  [ "$(fm_rate_limit_signal pi glm-5.3-flash $'Error: 429: {"code":"1308","message":"Usage"}\nError: 429: {"code":"1310","message":"Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-09-11 22:50:01"}')" = glm-1310 ] \
    || fail "a tail carrying 1308 then 1310 did not report the newer weekly wall"
  pass "GLM weekly wall: the 1310 envelope with or without an adjacent 429, distinct from glm-1308; the newest envelope wins; loose digits, wall prose alone, and the 1311 envelope (even with usage prose) name no window"
}

# This library is edited inside the fleet it supervises, so a GLM worker's pane
# tail realistically shows a diff or a cat of it. Its own source text - the
# vocabulary it documents and the patterns it matches with - must therefore
# never be read as a usage-limit window. (The generic 429/rate_limit_error
# vocabulary the header documents is a known, accepted residual: a line naming
# both a 429 and a rate-limit phrase still reports a generic signal.)
test_rate_limit_signal_does_not_match_its_own_source() {
  local lib="$ROOT/bin/fm-rate-limit-lib.sh" line got
  while IFS= read -r line; do
    got=$(fm_rate_limit_signal pi glm-5.3-flash "$line")
    case "$got" in
      glm-1308|glm-1310)
        fail "the library's own source named a GLM window ($got): $line" ;;
    esac
  done < "$lib"
  pass "no line of the detector's own source is read as a GLM usage-limit window"
}

test_rate_limit_signal_deepseek() {
  # DeepSeek's documented 429: "Rate limit reached. Please retry later."
  [ "$(fm_rate_limit_signal pi deepseek-v4-flash $'429\n{"error":{"message":"Rate limit reached. Please retry later.","type":"rate_limit_error"}}')" = deepseek-429 ] \
    || fail "DeepSeek 429 rate_limit_error not detected"
  [ "$(fm_rate_limit_signal pi deepseek-v4-pro $'HTTP/1.1 429\nupstream load too high')" = deepseek-429 ] \
    || fail "DeepSeek 429 upstream phrase not detected"
  # The chat API's upstream-load saturation refusal stands alone.
  [ "$(fm_rate_limit_signal pi deepseek-v4-flash '当前分组上游负载已饱和，请稍后重试')" = deepseek-rate-limit ] \
    || fail "DeepSeek upstream-load saturation refusal not detected"
  # The OpenAI-compatible error type matches for any model family.
  [ "$(fm_rate_limit_signal pi some-other-model '{"type":"rate_limit_exceeded"}')" = rate-limit ] \
    || fail "generic rate_limit_exceeded type not detected"
  pass "DeepSeek signals: 429 rate_limit_error, 429 upstream, standalone load-saturation refusal; generic type token"
}

test_rate_limit_signal_claude_and_generic() {
  [ "$(fm_rate_limit_signal claude opus $'429\nrate_limit_error: too many requests')" = claude-429 ] \
    || fail "Claude 429 rate_limit_error not detected"
  [ "$(fm_rate_limit_signal claude opus $'HTTP 429\n{"type":"overloaded_error"}')" = claude-429 ] \
    || fail "Claude 429 overloaded_error not detected"
  # Generic families (codex/gpt, grok, kimi, unknown) use the generic 429 rule.
  [ "$(fm_rate_limit_signal codex gpt-5 $'429 rate limit reached')" = 429-rate-limit ] \
    || fail "codex/gpt 429 rate limit not detected"
  [ "$(fm_rate_limit_signal pi grok-4 $'429\nToo Many Requests')" = 429-rate-limit ] \
    || fail "grok 429 too many requests not detected"
  [ "$(fm_rate_limit_signal pi kimi-k2 $'429 please retry later')" = 429-rate-limit ] \
    || fail "kimi 429 please retry not detected"
  # Family isolation: a DeepSeek-specific phrase must not match a glm model.
  [ -z "$(fm_rate_limit_signal pi glm-5.3 '当前分组上游负载已饱和')" ] \
    || fail "DeepSeek-specific phrase leaked onto the glm family"
  pass "Claude and generic 429 signals detected; vendor phrases stay family-scoped"
}

test_rate_limit_signal_negatives() {
  # A bare 429 with no rate-limit phrase is not a signal.
  [ -z "$(fm_rate_limit_signal pi default 'HTTP 429 returned by the fetch')" ] \
    || fail "bare 429 without a rate-limit phrase false-matched"
  # A rate-limit phrase without any code is not a signal.
  [ -z "$(fm_rate_limit_signal pi default 'rate limit docs: see README')" ] \
    || fail "rate-limit phrase without a code false-matched"
  [ -z "$(fm_rate_limit_signal pi default 'usage: fm-spawn.sh <task-id>')" ] \
    || fail "the word usage alone false-matched"
  # Ordinary busy/working pane content never matches.
  [ -z "$(fm_rate_limit_signal pi default 'Working... (12.3s)')" ] \
    || fail "busy footer false-matched"
  [ -z "$(fm_rate_limit_signal pi default $'building 429 objects\ntotal lines 1308')" ] \
    || fail "build output mentioning 429/1308 false-matched"
  # Build output that merely mentions the word limit is not a signal, even for
  # the glm family where the weekly-wall phrasing lives.
  [ -z "$(fm_rate_limit_signal pi glm-5.3-flash $'linting: 3 limit checks passed\nbuilt 429 objects')" ] \
    || fail "build output mentioning the word limit false-matched"
  # An unrelated error carrying a reset time is not a signal either: the
  # weekly-wall phrasing needs exhaustion and a limit noun alongside it.
  [ -z "$(fm_rate_limit_signal pi glm-5.3-flash 'Error: session will reset at 2026-09-11 22:50:01')" ] \
    || fail "an unrelated error quoting a reset time false-matched"
  # Nor is ordinary output that merely scatters the three words across the tail:
  # exhaustion and a limit noun must be seen together in one sentence.
  [ -z "$(fm_rate_limit_signal pi glm-5.3-flash $'exhaustive run: 3 limit checks passed\nsession will reset at 22:50')" ] \
    || fail "three scattered words false-matched as the weekly wall"
  # The same exhaustive/exhaustion distinction holds for the shared usage
  # vocabulary that partners the bare-429 gate: a 429ms duration in ordinary
  # test output is not a rate limit.
  [ -z "$(fm_rate_limit_signal pi glm-5.3 $'test took 429ms\nexhaustive sweep complete')" ] \
    || fail "an exhaustive sweep beside a 429ms duration false-matched"
  # The code gate needs the digits to stand alone and to sit next to the word
  # code, so a longer number and prose merely naming a code never match.
  [ -z "$(fm_rate_limit_signal pi default 'error code 13100 while linking')" ] \
    || fail "code 13100 false-matched as code 1310"
  [ -z "$(fm_rate_limit_signal pi glm-5.3-flash 'the error code for the weekly reset window is 1310')" ] \
    || fail "prose merely naming a code false-matched"
  # 4xx codes adjacent to the window must not leak (300/4299 contain 429 only
  # with digit boundaries - verify boundary discipline).
  [ -z "$(fm_rate_limit_signal pi default $'status 4299\nrate limit test')" ] \
    || fail "a non-429 code containing the digits 429 false-matched"
  pass "negatives: bare 429, phrases without codes, busy output, and digit-boundary lookalikes never match"
}

# --- watcher: a rate-limited pane surfaces classified, then absorbs ----------

# Non-terminal stale pane whose tail carries the GLM incident's 429/code-1308
# line: surfaced at once (before any wedge wall) with the signal named and
# "not a wedge" explicit - never the possible-wedge phrasing.
test_rate_limited_stale_surfaces_classified_once() {
  local dir state fakebin out drain_out capture_file window key pane_hash pid
  dir=$(make_case rate-limited-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-glmstalled"
  printf 'HTTP/1.1 429 Too Many Requests\n{"error":{"code":"1308","message":"Usage"}}' > "$capture_file"
  fm_write_meta "$state/glmstalled.meta" "window=$window" "kind=ship" "harness=pi" "model=default"
  printf 'working: implementing\n' > "$state/glmstalled.status"
  prime_status_seen "$state" "$state/glmstalled.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a rate-limited stale at once"
  grep -F "stale: $window" "$out" >/dev/null || fail "rate-limited wake did not carry the stale reason"
  grep -F "stalled on rate limit: glm-1308" "$out" >/dev/null \
    || fail "rate-limited wake did not name the signal: $(cat "$out")"
  grep -F "NOT a wedge" "$out" >/dev/null \
    || fail "rate-limited wake did not classify the stall as not-a-wedge: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a rate-limited stall was mislabeled a possible wedge"
  [ "$(cat "$state/.rate-limited-$key" 2>/dev/null || true)" = glmstalled ] \
    || fail "rate-limited episode marker was not recorded for the task"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || fail "stale suppressor was not advanced on the rate-limited surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "rate-limited surface must not start a wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the rate-limited stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "rate-limited wake was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a rate-limited stale surfaces at once, named and classified as not a wedge"
}

# The 2026-09-11 weekly wall, driven by the bytes a walled worker's pane
# actually carried (captured from glm-chinalane-policy-mech-s1, wrapping and
# all): the watcher must surface it classified, never as a possible wedge, and
# never start a wedge timer for it.
test_rate_limited_weekly_wall_surfaces_classified() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case rate-limited-weekly); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-glmweekly"
  cat > "$capture_file" <<'WALL'
 Exhausted. Your limit will reset at 2026-09-11 22:50:01"}

 Error: 429: {"code":"1310","message":"Weekly/Monthly Limit
 Exhausted. Your limit will reset at 2026-09-11 22:50:01"}

 Error: Retry failed after 3 attempts: 429:
 {"code":"1310","message":"Weekly/Monthly Limit Exhausted.
 Your limit will reset at 2026-09-11 22:50:01"}
WALL
  fm_write_meta "$state/glmweekly.meta" "window=$window" "kind=ship" "harness=pi" "model=glm-5.3-flash"
  printf 'working: implementing\n' > "$state/glmweekly.status"
  prime_status_seen "$state" "$state/glmweekly.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface the weekly wall at once"
  grep -F "stalled on rate limit: glm-1310" "$out" >/dev/null \
    || fail "weekly-wall wake did not name the glm-1310 signal: $(cat "$out")"
  grep -F "NOT a wedge" "$out" >/dev/null \
    || fail "weekly-wall wake did not classify the stall as not-a-wedge: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "the weekly wall was mislabeled a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the weekly wall started a wedge timer"
  unset FM_FAKE_CREW_STATE
  pass "a pane on the GLM weekly wall surfaces classified as stalled on glm-1310, never as a possible wedge"
}

# The same episode on later polls absorbs silently (no wake, no exit) while the
# signal persists - the false-wedge paging this feature exists to stop.
test_rate_limited_episode_absorbs_after_first_surface() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case rate-limited-absorb); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-stilllimited"
  printf '429 code 1308 Usage\n(backoff retry pending)' > "$capture_file"
  fm_write_meta "$state/stilllimited.meta" "window=$window" "kind=ship" "harness=pi" "model=default"
  printf 'working: implementing\n' > "$state/stilllimited.status"
  prime_status_seen "$state" "$state/stilllimited.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf 'stilllimited' > "$state/.rate-limited-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a rate-limited episode past its first surface re-woke the watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "an absorbed rate-limited poll printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an absorbed rate-limited poll enqueued a durable wake"
  [ -e "$state/.rate-limited-$key" ] || fail "absorbed poll dropped the rate-limited episode marker"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "an already-classified rate-limited episode absorbs silently on later polls"
}

# When the pane clears (the limit reset and the worker moved on), the episode
# marker drops and ordinary wedge aging resumes.
test_rate_limited_signal_cleared_resumes_wedge_aging() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case rate-limited-cleared); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-recovered"
  printf 'back to normal work output' > "$capture_file"
  fm_write_meta "$state/recovered.meta" "window=$window" "kind=ship" "harness=pi" "model=deepseek-v4-flash"
  printf 'working: implementing\n' > "$state/recovered.status"
  prime_status_seen "$state" "$state/recovered.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf 'recovered' > "$state/.rate-limited-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited when a cleared rate-limit signal resumed wedge aging: $(cat "$out")"
  fi
  [ ! -e "$state/.rate-limited-$key" ] || fail "cleared rate-limit signal kept the episode marker"
  [ -s "$state/.stale-since-$key" ] || fail "cleared rate-limit signal did not resume wedge aging (no timer)"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane whose rate-limit signal cleared drops the classification and resumes wedge aging"
}

# A busy pane past its completed-turn bound normally escalates as a possible
# wedge; a rate-limit signal in its tail reclassifies the stall instead.
test_rate_limited_busy_pane_surfaces_classified_not_wedge() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case rate-limited-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-busylimited"
  printf 'retrying after 429 rate limit (attempt 4)...\n' > "$capture_file"
  fm_write_meta "$state/busylimited.meta" "window=$window" "kind=ship" "harness=pi" "model=deepseek-v4-flash"
  record_pi_busy "$state" busylimited
  printf 'working: setup complete\n' > "$state/busylimited.status"
  prime_status_seen "$state" "$state/busylimited.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded: age the spawn record itself.
  touch -t 200001010000 "$state/busylimited.meta"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a rate-limited busy pane past the turn-age bound"
  grep -F "stalled on rate limit: deepseek-429" "$out" >/dev/null \
    || fail "rate-limited busy wake did not name the signal: $(cat "$out")"
  grep -F "NOT a wedge" "$out" >/dev/null \
    || fail "rate-limited busy wake did not classify the stall as not-a-wedge: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "rate-limited busy stall was mislabeled a possible wedge"
  [ "$(cat "$state/.rate-limited-$key" 2>/dev/null || true)" = busylimited ] \
    || fail "rate-limited busy episode marker was not recorded"
  pass "a rate-limited busy pane past its turn-age bound surfaces classified, never as a wedge"
}

# A pane whose tail merely mentions a 429 without a rate-limit phrase keeps the
# ordinary non-terminal path (immediate unclassified surface) - the lib's
# conservative AND-gate must not change existing behavior.
test_non_rate_limited_stale_keeps_ordinary_path() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case non-rate-limited); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-plainstale"
  printf 'HTTP 429 returned while fetching docs\n' > "$capture_file"
  fm_write_meta "$state/plainstale.meta" "window=$window" "kind=ship" "harness=pi" "model=default"
  printf 'working: implementing\n' > "$state/plainstale.status"
  prime_status_seen "$state" "$state/plainstale.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a plain (non-rate-limited) stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "plain stale wake was not the ordinary immediate surface"
  grep -F "rate limit" "$out" >/dev/null && fail "a non-rate-limit pane was classified as rate-limited"
  [ ! -e "$state/.rate-limited-$key" ] || fail "a non-rate-limit pane recorded a rate-limited episode"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a bare-429 pane without a rate-limit phrase keeps the ordinary stale surface"
}

test_rate_limit_signal_glm
test_rate_limit_signal_glm_weekly_wall
test_rate_limit_signal_does_not_match_its_own_source
test_rate_limit_signal_deepseek
test_rate_limit_signal_claude_and_generic
test_rate_limit_signal_negatives
test_rate_limited_stale_surfaces_classified_once
test_rate_limited_weekly_wall_surfaces_classified
test_rate_limited_episode_absorbs_after_first_surface
test_rate_limited_signal_cleared_resumes_wedge_aging
test_rate_limited_busy_pane_surfaces_classified_not_wedge
test_non_rate_limited_stale_keeps_ordinary_path
