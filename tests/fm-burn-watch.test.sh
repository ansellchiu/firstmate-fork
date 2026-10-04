#!/usr/bin/env bash
# Tests for fm-burn-watch.sh, the lane burn watch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BW="$ROOT/bin/fm-burn-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-burn-watch)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/bin" "$home/stub"
  cat > "$home/bin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "quota-axi stub"; exit 0; }
[ -f "$STUB/quota-fail" ] && exit 1
cat "$STUB/quota.json"
SH
  chmod +x "$home/bin/quota-axi"
  printf '%s\n' "$home"
}

set_quota() { # set_quota <home> <claude-pp> <codex-pp> <agy-pp> <alibaba-pp>
  cat > "$1/stub/quota.json" <<JSON
{"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"seven_day","percentRemaining":$2}]},
  {"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"weekly","percentRemaining":$3}]},
  {"provider":"agy","state":{"status":"fresh"},"windows":[{"id":"gemini_weekly","percentRemaining":$4}]},
  {"provider":"alibaba","state":{"status":"fresh"},"windows":[{"id":"monthly","percentRemaining":$5}]}
]}
JSON
}

bw() { # bw <home> <args...>
  local home=$1; shift
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    STUB="$home/stub" PATH="$home/bin:$PATH" "$BW" "$@"
}

test_arm_registers_and_disarm_removes() {
  local home out
  home=$(make_home arm)
  set_quota "$home" 80 70 60 95
  out=$(bw "$home" arm)
  assert_contains "$out" "armed: state/burn-watch.check.sh" "arm reports"
  assert_present "$home/state/burn-watch.check.sh" "shim written"
  assert_present "$home/state/burn-watch.check-trust" "shim bound"
  assert_equals 700 "$(stat -c %a "$home/state/burn-watch.check.sh" 2>/dev/null || stat -f %Lp "$home/state/burn-watch.check.sh")" "shim mode"
  bw "$home" disarm >/dev/null
  assert_absent "$home/state/burn-watch.check.sh" "shim removed"
  assert_absent "$home/state/burn-watch.check-trust" "binding removed"
  pass "arm writes and binds the byte-static shim and disarm removes it"
}

test_healthy_check_is_silent() {
  local home out
  home=$(make_home healthy)
  set_quota "$home" 80 70 60 95
  out=$(FM_BURN_NOW=1000 bw "$home" check)
  assert_equals "" "$out" "healthy first sample is silent"
  assert_present "$home/state/.burn-watch-prev" "first sample stored"
  out=$(FM_BURN_NOW=1300 bw "$home" check)
  assert_equals "" "$out" "healthy second sample is silent"
  pass "healthy check stays silent"
}

test_drop_threshold_crossing_no_repeat_recovery_and_rearm() {
  local home out
  home=$(make_home drop)
  set_quota "$home" 80 70 60 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null

  # 1. Drop claude by 12 points (80 -> 68)
  set_quota "$home" 68 70 60 95
  out=$(FM_BURN_NOW=1300 bw "$home" check)
  assert_contains "$out" "burn watch: claude dropped 12 points (80% -> 68%)" "drop threshold crossing alerts"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "drop alert is exactly one line"

  # 2. No-repeat: claude drops another 12 points (68 -> 56) while drop alert is active
  set_quota "$home" 56 70 60 95
  out=$(FM_BURN_NOW=1600 bw "$home" check)
  assert_equals "" "$out" "drop alert does not repeat on consecutive breaches"

  # 3. Recovery: claude drops only 2 points (56 -> 54)
  set_quota "$home" 54 70 60 95
  out=$(FM_BURN_NOW=1900 bw "$home" check)
  assert_equals "" "$out" "recovery sample is silent"

  # 4. Re-arm: claude drops 14 points (54 -> 40)
  set_quota "$home" 40 70 60 95
  out=$(FM_BURN_NOW=2200 bw "$home" check)
  assert_contains "$out" "claude dropped 14 points (54% -> 40%)" "drop alert re-arms after recovery"
  pass "drop threshold crossing, no-repeat, recovery, and re-arm"
}

test_floor_threshold_crossing_no_repeat_recovery_and_rearm() {
  local home out
  home=$(make_home floor)
  set_quota "$home" 50 50 50 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null

  # 1. Claude falls below 20% (18%)
  set_quota "$home" 18 50 50 95
  out=$(FM_BURN_NOW=1300 bw "$home" check)
  assert_contains "$out" "burn watch:" "floor alert prefix"
  assert_contains "$out" "claude below 20% (18% remaining)" "claude floor alert"

  # 2. Codex below 15% (12%)
  set_quota "$home" 18 12 50 95
  out=$(FM_BURN_NOW=1600 bw "$home" check)
  assert_contains "$out" "codex below 15% (12% remaining)" "codex floor alert"
  assert_not_contains "$out" "claude below 20%" "claude does not repeat"

  # 3. Recovery: claude resets to 100%, codex resets to 100%
  set_quota "$home" 100 100 50 95
  out=$(FM_BURN_NOW=1900 bw "$home" check)
  assert_equals "" "$out" "floor recovery is silent"

  # 4. Re-arm: claude drops to 15%
  set_quota "$home" 15 100 50 95
  out=$(FM_BURN_NOW=2200 bw "$home" check)
  assert_contains "$out" "claude below 20% (15% remaining)" "floor alert re-arms after reset"
  pass "floor threshold crossing, no-repeat, recovery, and re-arm"
}

test_alibaba_rate_threshold_crossing_no_repeat_recovery_and_rearm() {
  local home out
  home=$(make_home alibaba)
  set_quota "$home" 80 70 60 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null

  set_quota "$home" 80 70 60 92
  out=$(FM_BURN_NOW=22300 bw "$home" check)
  assert_equals "" "$out" "rate waits until anchor is six hours old"
  out=$(FM_BURN_NOW=22600 bw "$home" check)
  assert_contains "$out" "alibaba monthly burning faster than 1.5%/day (8%/day)" "alibaba rate alert"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "rate alert is exactly one line"

  out=$(FM_BURN_NOW=22900 bw "$home" check)
  assert_equals "" "$out" "flat tick does not re-arm the anchored rate"
  set_quota "$home" 80 70 60 91
  out=$(FM_BURN_NOW=23200 bw "$home" check)
  assert_equals "" "$out" "rate alert does not repeat"

  out=$(FM_BURN_NOW=173800 bw "$home" check)
  assert_equals "" "$out" "anchor average below limit recovers silently"
  set_quota "$home" 80 70 60 89
  out=$(FM_BURN_NOW=174100 bw "$home" check)
  assert_contains "$out" "alibaba monthly burning faster than 1.5%/day" "rate alert re-arms"
  assert_equals 1000 "$(jq -r '.anchors.alibaba.timestamp' "$home/state/.burn-watch-prev")" "ordinary ticks preserve anchor"
  pass "anchored rate warmup, crossing, no-repeat, recovery, and re-arm"
}

test_single_integer_step_after_anchor_never_alerts_rate() {
  local home out
  home=$(make_home single-step)
  set_quota "$home" 80 70 60 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null
  set_quota "$home" 80 70 60 94
  out=$(FM_BURN_NOW=4600 bw "$home" check)
  assert_equals "" "$out" "one-point step an hour after anchor is silent"
  out=$(FM_BURN_NOW=22600 bw "$home" check)
  assert_equals "" "$out" "one-point step does not alert at six hours"
  pass "a single integer step never alerts the rate by itself"
}

test_sub_second_reset_jitter_keeps_drop_baseline_and_anchor() {
  local home out
  home=$(make_home jitter)
  set_quota "$home" 64 70 60 95
  jq '(.providers[] | select(.provider == "claude").windows[0].resetsAt) = "2026-10-08T00:00:00.172970+00:00"' "$home/stub/quota.json" > "$home/stub/next.json"
  mv "$home/stub/next.json" "$home/stub/quota.json"
  FM_BURN_NOW=1000 bw "$home" check >/dev/null
  set_quota "$home" 50 70 60 95
  jq '(.providers[] | select(.provider == "claude").windows[0].resetsAt) = "2026-10-07T23:59:59.967221+00:00"' "$home/stub/quota.json" > "$home/stub/next.json"
  mv "$home/stub/next.json" "$home/stub/quota.json"
  out=$(FM_BURN_NOW=1300 bw "$home" check)
  assert_contains "$out" "claude dropped 14 points (64% -> 50%)" "jittered reset time keeps drop baseline"
  assert_equals 1000 "$(jq -r '.anchors.claude.timestamp' "$home/state/.burn-watch-prev")" "jittered reset time keeps rate anchor"
  pass "sub-second reset jitter does not start a new period"
}

test_integer_steps_at_fast_poll_cadence_stay_below_rate_limit() {
  local home out day tick remaining
  home=$(make_home integer-rate)
  set_quota "$home" 80 70 60 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null
  for day in 2 4 6; do
    for tick in 0 300 600; do
      remaining=$((95 - day / 2))
      if [ "$tick" -eq 0 ]; then remaining=$((remaining + 1)); fi
      set_quota "$home" 80 70 60 "$remaining"
      out=$(FM_BURN_NOW=$((1000 + day * 86400 + tick)) bw "$home" check)
      assert_equals "" "$out" "one integer point every two days stays below limit at 300s cadence"
    done
  done
  assert_equals 95 "$(jq -r '.anchors.alibaba.remaining' "$home/state/.burn-watch-prev")" "integer drops retain baseline value"
  assert_equals 1000 "$(jq -r '.anchors.alibaba.timestamp' "$home/state/.burn-watch-prev")" "integer drops retain baseline time"
  pass "integer one-point steps do not produce fast-poll rate spikes"
}

test_rate_anchor_resets_on_rise_or_window_reset_and_survives_missing() {
  local home out
  home=$(make_home rate-reset)
  set_quota "$home" 80 70 60 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null
  set_quota "$home" 80 70 60 92
  FM_BURN_NOW=22600 bw "$home" check >/dev/null
  jq '(.providers[] | select(.provider == "alibaba").state.status) = "stale"' "$home/stub/quota.json" > "$home/stub/next.json"
  mv "$home/stub/next.json" "$home/stub/quota.json"
  out=$(FM_BURN_NOW=22900 bw "$home" check)
  assert_contains "$out" "alibaba unmeasured" "missing lane reports"
  assert_equals 1000 "$(jq -r '.anchors.alibaba.timestamp' "$home/state/.burn-watch-prev")" "missing lane retains rate anchor"
  set_quota "$home" 80 70 60 92
  out=$(FM_BURN_NOW=23200 bw "$home" check)
  assert_equals "" "$out" "measurement recovery preserves active rate"
  set_quota "$home" 80 70 60 94.5
  out=$(FM_BURN_NOW=23500 bw "$home" check)
  assert_equals "" "$out" "rise resets anchor even below original value"
  assert_equals 23500 "$(jq -r '.anchors.alibaba.timestamp' "$home/state/.burn-watch-prev")" "rise starts new anchor"
  jq '(.providers[] | select(.provider == "alibaba").windows[0]) |= (.percentRemaining = 70 | .resetsAt = "2030-02-01T00:00:00Z")' "$home/stub/quota.json" > "$home/stub/next.json"
  mv "$home/stub/next.json" "$home/stub/quota.json"
  out=$(FM_BURN_NOW=45100 bw "$home" check)
  assert_equals "" "$out" "changed reset period skips both drop and rate comparisons"
  assert_equals 45100 "$(jq -r '.anchors.alibaba.timestamp' "$home/state/.burn-watch-prev")" "changed reset starts new anchor"
  set_quota "$home" 80 70 60 90
  jq '(.providers[] | select(.provider == "alibaba").windows[0]) |= (.id = "weekly" | .percentRemaining = 50)' "$home/stub/quota.json" > "$home/stub/next.json"
  mv "$home/stub/next.json" "$home/stub/quota.json"
  printf '%s\n' '{"lanes":{"alibaba":{"provider":"alibaba","window":"weekly","rate_pct_day":1.5}}}' > "$home/config/burn-watch.json"
  out=$(FM_BURN_NOW=45400 bw "$home" check)
  assert_equals "" "$out" "configured window change starts a new baseline"
  jq '(.providers[] | select(.provider == "alibaba").windows[0].percentRemaining) = 48' "$home/stub/quota.json" > "$home/stub/next.json"
  mv "$home/stub/next.json" "$home/stub/quota.json"
  out=$(FM_BURN_NOW=67000 bw "$home" check)
  assert_contains "$out" "alibaba weekly burning faster than 1.5%/day" "rate names actual configured window"
  pass "rate anchors survive missing measurements and reset on rise or period change"
}

test_exact_fresh_lane_extraction_shared_by_check_and_sample() {
  local home out status
  home=$(make_home extraction)
  set_quota "$home" 80 70 60 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null
  for status in stale error fresh; do
    cat > "$home/stub/quota.json" <<JSON
{"providers":[{"provider":"claude","state":{"status":"$status"},
"windows":[{"id":"five_hour","kind":"seven_day","label":"seven_day","percentRemaining":10}],
"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":5}]}}]}
JSON
    out=$(FM_BURN_NOW=1300 bw "$home" check)
    if [ "$status" = stale ]; then
      assert_contains "$out" "claude unmeasured" "unmeasured lane alerts once"
    else
      assert_equals "" "$out" "unmeasured lane does not repeat"
    fi
    assert_not_contains "$out" "dropped" "different window never causes drop"
    assert_not_contains "$out" "below" "different window never causes floor"
    out=$(bw "$home" sample)
    assert_contains "$out" "claude: unmeasured" "sample rejects window aliases and fallback"
    assert_equals null "$(jq -r '.lanes.claude' "$home/state/.burn-watch-prev")" "unmeasured persisted as null"
  done
  for status in stale error; do
    set_quota "$home" 10 70 60 95
    jq --arg status "$status" '(.providers[] | select(.provider == "claude").state.status) = $status' "$home/stub/quota.json" > "$home/stub/next.json"
    mv "$home/stub/next.json" "$home/stub/quota.json"
    out=$(FM_BURN_NOW=1600 bw "$home" check)
    assert_equals "" "$out" "exact stale or errored window stays unmeasured"
    out=$(bw "$home" sample)
    assert_contains "$out" "claude: unmeasured" "sample rejects stale and error providers"
  done
  set_quota "$home" 70 70 60 95
  out=$(FM_BURN_NOW=1900 bw "$home" check)
  assert_equals "" "$out" "fresh recovery skips comparison across missing measurements"
  out=$(bw "$home" sample)
  assert_contains "$out" "claude: 70% (seven_day)" "sample accepts fresh configured window"
  jq '(.providers[] | select(.provider == "claude").state.status) = "error"' "$home/stub/quota.json" > "$home/stub/next.json"
  mv "$home/stub/next.json" "$home/stub/quota.json"
  out=$(FM_BURN_NOW=2200 bw "$home" check)
  assert_contains "$out" "claude unmeasured" "unmeasured diagnostic re-arms on recovery"
  pass "check and sample accept only exact fresh windows and report missing lanes once"
}

test_failed_instrument_prints_one_line_once_and_rearms() {
  local home out
  home=$(make_home fail)
  set_quota "$home" 80 70 60 95
  touch "$home/stub/quota-fail"
  out=$(FM_BURN_NOW=1000 bw "$home" check)
  assert_contains "$out" "burn watch: instrument failed - quota-axi" "failed instrument alerts"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "failure alert is exactly one line"

  # No repeat: second poll with failure
  out=$(FM_BURN_NOW=1300 bw "$home" check)
  assert_equals "" "$out" "failed instrument does not alert repeatedly"

  # Recovery: instrument succeeds
  rm -f "$home/stub/quota-fail"
  out=$(FM_BURN_NOW=1600 bw "$home" check)
  assert_equals "" "$out" "healthy recovery poll is silent"

  # Failure re-arms: instrument fails again
  touch "$home/stub/quota-fail"
  out=$(FM_BURN_NOW=1900 bw "$home" check)
  assert_contains "$out" "burn watch: instrument failed - quota-axi" "failure alerts again after recovery"
  pass "failed instrument prints one line once and re-arms on recovery"
}

test_invalid_config_reports_once_instead_of_defaults() {
  local home out
  home=$(make_home badcfg)
  printf '{"lanes":{"codex":{"window":"weekly","floor_pct":40},}}\n' > "$home/config/burn-watch.json"
  set_quota "$home" 80 30 60 95
  out=$(FM_BURN_NOW=1000 bw "$home" check)
  assert_equals "burn watch: invalid config - $home/config/burn-watch.json" "$out" "invalid config reported, not defaulted"
  out=$(FM_BURN_NOW=1300 bw "$home" check)
  assert_equals "" "$out" "invalid config reported once"
  if bw "$home" sample >/dev/null 2>&1; then fail "sample rejects invalid config"; fi

  printf '{"lanes":{"codex":{"window":"weekly","floor_pct":40}}}\n' > "$home/config/burn-watch.json"
  out=$(FM_BURN_NOW=1600 bw "$home" check)
  assert_equals "burn watch: codex below 40% (30% remaining)" "$out" "fixed config thresholds apply"

  printf 'not json\n' > "$home/config/burn-watch.json"
  out=$(FM_BURN_NOW=1900 bw "$home" check)
  assert_equals "burn watch: invalid config - $home/config/burn-watch.json" "$out" "invalid config re-arms after recovery"
  pass "existing invalid config is reported once instead of silently using defaults"
}

test_mistyped_config_fields_are_invalid() {
  local home out bad
  home=$(make_home typedcfg)
  set_quota "$home" 80 70 60 95
  for bad in '{"drop_threshold_pp":"10","lanes":{}}' \
    '{"lanes":[]}' \
    '{"lanes":{"claude":"seven_day"}}' \
    '{"lanes":{"claude":{"provider":1}}}' \
    '{"lanes":{"claude":{"window":["seven_day"]}}}' \
    '{"lanes":{"claude":{"floor_pct":"20"}}}' \
    '{"lanes":{"claude":{"drop_threshold_pp":"5"}}}' \
    '{"lanes":{"alibaba":{"rate_pct_day":"1.5"}}}'; do
    rm -f "$home/state/.burn-watch-alerts"
    printf '%s\n' "$bad" > "$home/config/burn-watch.json"
    out=$(FM_BURN_NOW=1000 bw "$home" check)
    assert_equals "burn watch: invalid config - $home/config/burn-watch.json" "$out" "mistyped config rejected: $bad"
    if bw "$home" sample >/dev/null 2>&1; then fail "sample rejects mistyped config: $bad"; fi
  done
  pass "mistyped config fields are reported as invalid config"
}

test_state_write_failure_is_reported_not_silent() {
  local home out rc=0
  home=$(make_home rostate)
  set_quota "$home" 80 70 60 95
  FM_BURN_NOW=1000 bw "$home" check >/dev/null
  chmod 555 "$home/state"
  if touch "$home/state/.probe" 2>/dev/null; then
    rm -f "$home/state/.probe"; chmod 755 "$home/state"
    pass "state write failure (skipped: state directory stays writable)"
    return
  fi
  set_quota "$home" 68 70 60 95
  out=$(FM_BURN_NOW=1300 bw "$home" check) || rc=$?
  assert_equals "burn watch: state write failed - $home/state" "$out" "sample publication failure reported"
  assert_equals 1 "$rc" "sample publication failure exits non-zero"
  rc=0
  touch "$home/stub/quota-fail"
  out=$(FM_BURN_NOW=1600 bw "$home" check) || rc=$?
  assert_equals "burn watch: state write failed - $home/state" "$out" "diagnostic marker failure reported"
  assert_equals 1 "$rc" "diagnostic marker failure exits non-zero"
  chmod 755 "$home/state"
  rm -f "$home/stub/quota-fail"
  out=$(FM_BURN_NOW=1900 bw "$home" check)
  assert_equals "burn watch: claude dropped 12 points (80% -> 68%)" "$out" "baseline kept after failed write"
  pass "state write failures are reported instead of reporting success"
}

test_init_writes_default_config_when_absent() {
  local home out out2
  home=$(make_home init)
  assert_absent "$home/config/burn-watch.json" "config initially absent"
  out=$(bw "$home" init)
  assert_contains "$out" "wrote: $home/config/burn-watch.json" "init reports wrote"
  assert_present "$home/config/burn-watch.json" "config written"
  assert_equals 10 "$(jq -r .drop_threshold_pp "$home/config/burn-watch.json")" "default drop threshold"
  assert_equals 20 "$(jq -r .lanes.claude.floor_pct "$home/config/burn-watch.json")" "default claude floor"
  assert_equals 15 "$(jq -r .lanes.codex.floor_pct "$home/config/burn-watch.json")" "default codex floor"
  assert_equals 20 "$(jq -r .lanes.agy.floor_pct "$home/config/burn-watch.json")" "default agy floor"
  assert_equals 1.5 "$(jq -r .lanes.alibaba.rate_pct_day "$home/config/burn-watch.json")" "default alibaba rate"
  out2=$(bw "$home" init)
  assert_contains "$out2" "present: $home/config/burn-watch.json" "idempotent init reports present"
  pass "init writes default config when absent"
}

test_arm_registers_and_disarm_removes
test_healthy_check_is_silent
test_drop_threshold_crossing_no_repeat_recovery_and_rearm
test_floor_threshold_crossing_no_repeat_recovery_and_rearm
test_alibaba_rate_threshold_crossing_no_repeat_recovery_and_rearm
test_single_integer_step_after_anchor_never_alerts_rate
test_sub_second_reset_jitter_keeps_drop_baseline_and_anchor
test_integer_steps_at_fast_poll_cadence_stay_below_rate_limit
test_rate_anchor_resets_on_rise_or_window_reset_and_survives_missing
test_exact_fresh_lane_extraction_shared_by_check_and_sample
test_failed_instrument_prints_one_line_once_and_rearms
test_invalid_config_reports_once_instead_of_defaults
test_mistyped_config_fields_are_invalid
test_state_write_failure_is_reported_not_silent
test_init_writes_default_config_when_absent
