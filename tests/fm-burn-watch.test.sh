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
  {"provider":"claude","windows":[{"id":"seven_day","percentRemaining":$2}]},
  {"provider":"codex","windows":[{"id":"weekly","percentRemaining":$3}]},
  {"provider":"agy","windows":[{"id":"gemini_weekly","percentRemaining":$4}]},
  {"provider":"alibaba","windows":[{"id":"monthly","percentRemaining":$5}]}
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
  set_quota "$home" 80 70 60 95.0
  FM_BURN_NOW=1000 bw "$home" check >/dev/null

  # 1. 1 hour later (3600s), alibaba drops to 94.9 (0.1% burned -> 2.4%/day > 1.5%/day)
  set_quota "$home" 80 70 60 94.9
  out=$(FM_BURN_NOW=4600 bw "$home" check)
  assert_contains "$out" "alibaba monthly burning faster than 1.5%/day (2.4%/day)" "alibaba rate alert"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "rate alert is exactly one line"

  # 2. No-repeat: 1 hour later (8200s), alibaba drops to 94.8 (2.4%/day again)
  set_quota "$home" 80 70 60 94.8
  out=$(FM_BURN_NOW=8200 bw "$home" check)
  assert_equals "" "$out" "rate alert does not repeat"

  # 3. Recovery: 1 hour later (11800s), alibaba stays at 94.8 (0% burn <= 1.5%/day)
  set_quota "$home" 80 70 60 94.8
  out=$(FM_BURN_NOW=11800 bw "$home" check)
  assert_equals "" "$out" "rate recovery is silent"

  # 4. Re-arm: 1 hour later (15400s), alibaba drops to 94.7 (2.4%/day again)
  set_quota "$home" 80 70 60 94.7
  out=$(FM_BURN_NOW=15400 bw "$home" check)
  assert_contains "$out" "alibaba monthly burning faster than 1.5%/day" "rate alert re-arms"
  pass "alibaba rate threshold crossing, no-repeat, recovery, and re-arm"
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
test_failed_instrument_prints_one_line_once_and_rearms
test_init_writes_default_config_when_absent
