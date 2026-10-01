#!/usr/bin/env bash
# Tests for fm-value-ledger.sh, the Plan payback ledger.
#
# The instruments are stubbed with fixed JSON, so every case drives the real script
# through its public actions and asserts the figures it derives. The cases pin the
# adversarial review's required fixes: hourly alignment, reset and contamination
# handling, the quantization band, cross-client attribution, determinism and tamper
# detection, and the one print path of the armed check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VL="$ROOT/bin/fm-value-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-value-ledger)
export TZ=Asia/Singapore

# at <YYYY-MM-DD HH:MM> (SGT) -> epoch
at() { date -j -f '%Y-%m-%d %H:%M' "$1" +%s 2>/dev/null || date -d "$1" +%s; }

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/bin"
  # Stub instruments. Each answers from files in $STUB so a case can change the world.
  cat > "$home/bin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "quota-axi stub"; exit 0; }
[ -f "$STUB/quota-fail" ] && exit 1
cat "$STUB/quota.json"
SH
  cat > "$home/bin/tokscale" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "tokscale stub"; exit 0; }
sub=$1; shift
client=all
while [ $# -gt 0 ]; do case $1 in -c) client=$2; shift 2 ;; *) shift ;; esac; done
if [ "$sub" = models ]; then cat "$STUB/models.json"; else cat "$STUB/hourly-$client.json"; fi
SH
  cat > "$home/bin/codeburn" <<'SH'
#!/usr/bin/env bash
printf 'CodeBurn\nTotals\n  Cost       $100.00\n'
SH
  chmod +x "$home/bin/"*
  mkdir -p "$home/stub"
  printf '%s\n' "$home"
}

# quota <home> <claude-pp> <claude-resets> <codex-pp>
set_quota() {
  cat > "$1/stub/quota.json" <<JSON
{"providers":[
 {"provider":"claude","plan":"max","state":{"status":"fresh"},"windows":[{"id":"seven_day","resetsAt":"$3","percentRemaining":$2}]},
 {"provider":"codex","plan":"plus","state":{"status":"fresh"},"windows":[{"id":"weekly","resetsAt":"2026-10-05T01:54:04.000Z","percentRemaining":$4}]}]}
JSON
}

# set_hourly <home> <client> <json-entries-array>
set_hourly() { printf '{"entries":%s}\n' "$3" > "$1/stub/hourly-$2.json"; }

# set_models <home> <client> <provider> <model> ...: the client,provider,model capture
set_models() {
  local home=$1 rows="" sep=""; shift
  while [ $# -ge 3 ]; do rows="$rows$sep{\"client\":\"$1\",\"provider\":\"$2\",\"model\":\"$3\",\"cost\":0}"; sep=,; shift 3; done
  printf '{"entries":[%s]}\n' "$rows" > "$home/stub/models.json"
}

bucket() { # bucket <hour> <clients-json> <models-json> <cost>
  printf '{"hour":"%s","clients":%s,"models":%s,"input":1,"output":1,"cacheRead":1,"cacheWrite":1,"cost":%s}' "$1" "$2" "$3" "$4"
}

fresh_world() {
  local home=$1
  set_quota "$home" 80 "2026-10-08T00:00:00.201787+00:00" 50
  set_hourly "$home" claude '[]'
  set_hourly "$home" codex '[]'
  set_hourly "$home" pi '[]'
  set_hourly "$home" antigravity-cli '[]'
  set_hourly "$home" all '[]'
  echo '{"entries":[]}' > "$home/stub/models.json"
}

vl() { # vl <home> <args...>
  local home=$1; shift
  env FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" STUB="$home/stub" \
    PATH="$home/bin:$PATH" "$VL" "$@"
}

sample_at() { # sample_at <home> <time> [actor]
  FM_VALUE_NOW=$(at "$2") vl "$1" sample --actor "${3:-manual}" >/dev/null 2>&1 || fail "sample at $2 failed"
}

rollup_json() { vl "$1" rollup --dry; }

# two samples bracketing the 22:00 and 23:00 buckets
two_samples() { # two_samples <home> <pp-after>
  local home=$1
  vl "$home" init >/dev/null
  set_quota "$home" 80 "2026-10-08T00:00:00.201787+00:00" 50
  sample_at "$home" "2026-10-01 21:05"
  set_quota "$home" "$2" "2026-10-08T00:00:00.201787+00:00" 50
  sample_at "$home" "2026-10-01 23:05" check
}

test_aligned_pair_gives_dollars_per_point_with_band_and_bias() {
  local home out
  home=$(make_home aligned); fresh_world "$home"
  set_hourly "$home" claude "[$(bucket '2026-10-01 21:00' '["claude"]' '["claude-opus-5"]' 20),$(bucket '2026-10-01 22:00' '["claude"]' '["claude-opus-5"]' 30),$(bucket '2026-10-01 23:00' '["claude"]' '["claude-opus-5"]' 99)]"
  two_samples "$home" 70
  out=$(rollup_json "$home")
  assert_equals 10 "$(jq '.pools["claude-max"].pp_used' <<<"$out")" "points used"
  assert_equals 50 "$(jq '.pools["claude-max"].api_value_usd' <<<"$out")" "hours 21 and 22 count, the open 23 hour does not"
  assert_equals 5 "$(jq '.pools["claude-max"].dollars_per_pp.v' <<<"$out")" "dollars per point"
  assert_equals true "$(jq '.pools["claude-max"].dollars_per_pp.counts' <<<"$out")" "a 10 point band is narrower than 25%"
  assert_contains "$(jq -r '.pools["claude-max"].dollars_per_pp.display' <<<"$out")" "biased low" "the bias is in the figure itself"
  pass "an aligned pair yields a banded, bias-labelled dollars per point"
}

test_narrow_sample_does_not_count() {
  local home out
  home=$(make_home narrow); fresh_world "$home"
  set_hourly "$home" claude "[$(bucket '2026-10-01 21:00' '["claude"]' '["claude-opus-5"]' 30)]"
  two_samples "$home" 77
  out=$(rollup_json "$home")
  assert_equals false "$(jq '.pools["claude-max"].dollars_per_pp.counts' <<<"$out")" "a 3 point band is wider than 25%"
  assert_contains "$(jq -r '.pools["claude-max"].dollars_per_pp.display' <<<"$out")" "indicative only" "a wide band is called indicative"
  pass "a figure whose quantization band is too wide does not count"
}

test_reset_between_samples_is_never_paired() {
  local home out
  home=$(make_home reset); fresh_world "$home"; vl "$home" init >/dev/null
  set_quota "$home" 20 "2026-10-08T00:00:00.2+00:00" 50
  sample_at "$home" "2026-10-01 21:05"
  set_quota "$home" 90 "2026-10-15T00:00:00.2+00:00" 50
  sample_at "$home" "2026-10-01 23:05"
  out=$(rollup_json "$home")
  assert_equals "reset between samples" "$(jq -r '.pools["claude-max"].pairs[0].skipped' <<<"$out")" "reset pair is skipped"
  assert_equals 0 "$(jq '.pools["claude-max"].counted_pairs' <<<"$out")" "nothing counted across a reset"
  pass "samples are never paired across a reset"
}

test_resets_at_jitter_is_not_a_reset() {
  local home out
  home=$(make_home jitter); fresh_world "$home"; vl "$home" init >/dev/null
  set_quota "$home" 80 "2026-10-07T23:59:59Z" 50
  sample_at "$home" "2026-10-01 21:05"
  set_quota "$home" 70 "2026-10-08T00:00:00.201787+00:00" 50
  sample_at "$home" "2026-10-01 23:05"
  out=$(rollup_json "$home")
  assert_equals null "$(jq '.pools["claude-max"].pairs[0].skipped' <<<"$out")" "one second of jitter is the same window"
  pass "a one second resetsAt jitter is not read as a reset"
}

test_contaminated_pair_is_flagged_not_averaged() {
  local home out
  home=$(make_home contam); fresh_world "$home"
  set_hourly "$home" claude "[$(bucket '2026-10-01 21:00' '["claude"]' '["claude-opus-5"]' 0.2)]"
  two_samples "$home" 75
  out=$(rollup_json "$home")
  assert_equals true "$(jq '.pools["claude-max"].pairs[0].contaminated' <<<"$out")" "points moved with no local draw"
  assert_equals 0 "$(jq '.pools["claude-max"].counted_pairs' <<<"$out")" "a contaminated pair is not counted"
  pass "a pair where quota moved without local draw is flagged and excluded"
}

test_unaligned_read_is_not_counted() {
  local home out
  home=$(make_home unaligned); fresh_world "$home"; vl "$home" init >/dev/null
  sample_at "$home" "2026-10-01 21:45"
  set_quota "$home" 70 "2026-10-08T00:00:00.201787+00:00" 50
  sample_at "$home" "2026-10-01 23:05"
  out=$(rollup_json "$home")
  assert_equals "unaligned read" "$(jq -r '.pools["claude-max"].pairs[0].skipped' <<<"$out")" "a read 45 minutes into the hour is unaligned"
  pass "a read taken late in its hour is not paired"
}

test_cross_client_attribution_and_exclusion() {
  local home out
  home=$(make_home attribution); fresh_world "$home"
  set_hourly "$home" pi "[$(bucket '2026-10-01 21:00' '["pi"]' '["gpt-6.1-sol"]' 7),$(bucket '2026-10-01 22:00' '["pi"]' '["gpt-6.1-sol","deepseek-flash"]' 9)]"
  set_hourly "$home" codex "[$(bucket '2026-10-01 21:00' '["codex"]' '["gpt-6.1-sol"]' 3)]"
  set_hourly "$home" claude "[$(bucket '2026-10-01 21:00' '["claude","antigravity-cli"]' '["claude-opus-5"]' 40)]"
  set_models "$home" pi openai-codex gpt-6.1-sol pi deepseek deepseek-flash codex openai gpt-6.1-sol
  vl "$home" init >/dev/null
  sample_at "$home" "2026-10-01 21:05"
  set_quota "$home" 80 "2026-10-08T00:00:00.201787+00:00" 40
  sample_at "$home" "2026-10-01 23:05"
  out=$(rollup_json "$home")
  assert_equals 10 "$(jq '.pools["codex-plus"].api_value_usd' <<<"$out")" "pi gpt-6.1-sol and codex both draw codex-plus"
  assert_equals 9 "$(jq '.pools["codex-plus"].pairs[0].ambiguous_usd' <<<"$out")" "a mixed-provider hour is ambiguous, not guessed"
  assert_equals "attribution leak" "$(jq -r '.pools["claude-max"].pairs[0].skipped' <<<"$out")" "a claude bucket that also carries antigravity-cli is refused"
  assert_equals '{"pool":"claude-max","client":"antigravity-cli","in_pool_usd":40,"ok":false}' \
    "$(jq -c '.conservation.exclusions[0] | {pool, client, in_pool_usd, ok}' <<<"$out")" "the named exclusion fails when antigravity-cli reaches claude-max"
  assert_equals false "$(jq '.conservation.ok' <<<"$out")" "conservation is not ok"
  pass "pi gpt rows attribute to codex-plus, mixed hours stay ambiguous, foreign clients cannot leak into claude-max"
}

test_rollup_is_deterministic_and_verifiable() {
  local home first second
  home=$(make_home determinism); fresh_world "$home"
  set_hourly "$home" claude "[$(bucket '2026-10-01 21:00' '["claude"]' '["claude-opus-5"]' 50)]"
  two_samples "$home" 70
  first=$(vl "$home" rollup)
  second=$(vl "$home" rollup)
  assert_contains "$first" "rolled up: r-" "first rollup writes"
  assert_contains "$second" "unchanged: r-" "re-run appends no duplicate row"
  assert_equals 1 "$(jq -s '[.[] | select(.schema == "fm.value.rollup.v1")] | length' "$home/data/value-ledger/ledger.jsonl")" "exactly one rollup row"
  assert_contains "$(vl "$home" verify)" "verified" "a re-derivation matches the stored row exactly"
  assert_equals '{"check":1,"manual":1}' "$(rollup_json "$home" | jq -c .actor_counts)" "actors are counted from the ledger"
  pass "rollup is idempotent and verify re-derives it exactly"
}

test_altered_capture_is_detected() {
  local home cap out
  home=$(make_home tamper); fresh_world "$home"
  two_samples "$home" 70
  cap=$(printf '%s\n' "$home"/data/value-ledger/captures/*/ | head -1)
  echo '{"entries":[]}' >> "${cap}hourly-claude.json"
  out=$(rollup_json "$home")
  assert_equals 1 "$(jq '.capture_violations | length' <<<"$out")" "a capture whose bytes changed is a recorded violation"
  pass "a capture altered after the sample is detected"
}

test_codex_cycle_to_date_and_payback_need_a_cycle_start() {
  local home out
  home=$(make_home payback); fresh_world "$home"
  set_hourly "$home" codex "[$(bucket '2026-09-29 10:00' '["codex"]' '["gpt-6.1-sol"]' 30),$(bucket '2026-09-30 10:00' '["codex"]' '["gpt-6.1-sol"]' 10)]"
  two_samples "$home" 70
  out=$(rollup_json "$home")
  assert_equals null "$(jq '.pools["codex-plus"].payback.v' <<<"$out")" "no cycle start, no payback"
  assert_contains "$(jq -r '.pools["codex-plus"].cycle_to_date.why' <<<"$out")" "cycle_start" "the reason names the missing registry field"
  jq '(.pools[] | select(.id == "codex-plus") | .cycle_start) = "2026-09-29"' "$home/data/value-ledger/lanes.json" > "$home/lanes.new" && mv "$home/lanes.new" "$home/data/value-ledger/lanes.json"
  # the capture span now has to reach the cycle start, so take two fresh samples
  sample_at "$home" "2026-10-02 21:05"
  sample_at "$home" "2026-10-02 23:05"
  out=$(rollup_json "$home")
  assert_equals 40 "$(jq '.pools["codex-plus"].cycle_to_date.v' <<<"$out")" "cycle-to-date value sums attributed hours since the cycle start"
  assert_equals 2 "$(jq '.pools["codex-plus"].payback.v' <<<"$out")" "40 over a 20 dollar fee"
  pass "payback is cycle-to-date over the fee, and missing until the cycle start is registered"
}

test_check_prints_one_line_on_failure_once_a_day_and_stays_silent_otherwise() {
  local home out
  home=$(make_home check); fresh_world "$home"; vl "$home" init >/dev/null
  out=$(FM_VALUE_NOW=$(at "2026-10-02 00:10") vl "$home" check)
  assert_equals "" "$out" "before 00:15 SGT the check is silent"
  touch "$home/stub/quota-fail"
  out=$(FM_VALUE_NOW=$(at "2026-10-02 00:20") vl "$home" check)
  assert_contains "$out" "plan payback: sample failed" "an instrument failure prints the one line"
  out=$(FM_VALUE_NOW=$(at "2026-10-02 00:25") vl "$home" check)
  assert_equals "" "$out" "the same failure does not wake twice in a day"
  rm -f "$home/stub/quota-fail"
  out=$(FM_VALUE_NOW=$(at "2026-10-03 00:20") vl "$home" check)
  assert_equals "" "$out" "a healthy daily run is silent"
  assert_present "$home/state/.value-ledger-last-day" "the healthy run is marked"
  assert_equals 1 "$(jq -s '[.[] | select(.schema == "fm.value.sample.v1" and .actor == "check")] | length' "$home/data/value-ledger/ledger.jsonl")" "the check wrote exactly one sample row, as actor check"
  assert_equals check "$(jq -s -r '[.[] | select(.schema == "fm.value.rollup.v1")][-1].actor' "$home/data/value-ledger/ledger.jsonl")" "the check's rollup row records actor check"
  out=$(FM_VALUE_NOW=$(at "2026-10-03 00:30") vl "$home" check)
  assert_equals "" "$out" "a second sweep the same day does nothing"
  out=$(FM_VALUE_NOW=$(at "2026-10-07 00:20") vl "$home" check)
  assert_contains "$out" "no ledger row for 4 days" "missing days are reported"
  pass "the check has exactly one print path and runs once a day"
}

test_not_fresh_quota_prints_the_line() {
  local home out
  home=$(make_home stale); fresh_world "$home"; vl "$home" init >/dev/null
  sed -i.bak 's/"status":"fresh"/"status":"error"/' "$home/stub/quota.json"
  out=$(FM_VALUE_NOW=$(at "2026-10-02 00:20") vl "$home" check)
  assert_contains "$out" "quota not measured" "a pool read that is not fresh is an instrument failure"
  pass "a pool whose quota read is not fresh prints the alert"
}

test_arm_registers_and_disarm_removes() {
  local home
  home=$(make_home arm); fresh_world "$home"; vl "$home" init >/dev/null
  assert_contains "$(vl "$home" arm)" "armed: state/value-ledger.check.sh" "arm reports"
  assert_present "$home/state/value-ledger.check.sh" "shim written"
  assert_present "$home/state/value-ledger.check-trust" "shim bound"
  assert_equals 700 "$(stat -c %a "$home/state/value-ledger.check.sh" 2>/dev/null || stat -f %Lp "$home/state/value-ledger.check.sh")" "shim mode"
  vl "$home" disarm >/dev/null
  assert_absent "$home/state/value-ledger.check.sh" "shim removed"
  assert_absent "$home/state/value-ledger.check-trust" "binding removed"
  pass "arm writes and binds the byte-static shim and disarm removes it"
}

test_dashboard_draws_the_panel_and_the_alert() {
  local home
  home=$(make_home panel); fresh_world "$home"
  set_hourly "$home" claude "[$(bucket '2026-10-01 21:00' '["claude"]' '["claude-opus-5"]' 50)]"
  two_samples "$home" 70
  vl "$home" rollup >/dev/null
  echo "2026-10-01 plan payback: sample failed" > "$home/state/.value-ledger-fail"
  vl "$home" dashboard >/dev/null || fail "dashboard failed"
  assert_contains "$(cat "$home/data/value-ledger/plan-payback.html")" "Alert:" "the panel shows the live alert"
  assert_contains "$(cat "$home/data/value-ledger/plan-payback.html")" "claude-max" "the panel names the pools"
  pass "the panel renders the pools and the alert state"
}

test_pi_gpt_through_a_plain_api_key_is_not_charged_to_codex_plus() {
  local home out
  home=$(make_home provider); fresh_world "$home"
  set_hourly "$home" pi "[$(bucket '2026-10-01 21:00' '["pi"]' '["gpt-6.1-sol"]' 7)]"
  set_models "$home" pi openai gpt-6.1-sol
  vl "$home" init >/dev/null
  sample_at "$home" "2026-10-01 21:05"
  set_quota "$home" 80 "2026-10-08T00:00:00.201787+00:00" 40
  sample_at "$home" "2026-10-01 23:05"
  out=$(rollup_json "$home")
  assert_equals 0 "$(jq '.pools["codex-plus"].api_value_usd' <<<"$out")" "pi gpt served by provider openai is not codex-plus draw"
  assert_equals 7 "$(jq '.pools["codex-plus"].pairs[0].ambiguous_usd' <<<"$out")" "it is held out as ambiguous"
  pass "pi gpt usage outside provider openai-codex is never charged to codex-plus"
}

test_conservation_reconciles_the_total_and_names_the_exclusion() {
  local home out
  home=$(make_home conservation); fresh_world "$home"
  set_hourly "$home" claude "[$(bucket '2026-10-01 21:00' '["claude"]' '["claude-opus-5"]' 50)]"
  set_hourly "$home" antigravity-cli "[$(bucket '2026-10-01 21:00' '["antigravity-cli"]' '["claude-opus-5"]' 6)]"
  set_hourly "$home" all "[$(bucket '2026-10-01 21:00' '["claude","antigravity-cli","gemini"]' '["claude-opus-5"]' 60)]"
  two_samples "$home" 70
  out=$(rollup_json "$home")
  assert_equals '{"total_usd":60,"attributed_usd":50,"excluded_usd":6,"unregistered_usd":4,"ok":true}' \
    "$(jq -c '.conservation | {total_usd, attributed_usd, excluded_usd, unregistered_usd, ok}' <<<"$out")" "total = attributed + excluded + unregistered"
  assert_equals '{"client_usd":6,"in_pool_usd":0,"ok":true}' \
    "$(jq -c '.conservation.exclusions[] | select(.pool == "claude-max" and .client == "antigravity-cli") | {client_usd, in_pool_usd, ok}' <<<"$out")" "antigravity-cli is asserted out of claude-max by name"
  set_hourly "$home" all "[$(bucket '2026-10-01 21:00' '["claude"]' '["claude-opus-5"]' 30)]"
  sample_at "$home" "2026-10-02 01:05"
  assert_equals false "$(rollup_json "$home" | jq '.conservation.ok')" "per-client captures above the all-client total do not reconcile"
  pass "conservation reconciles the all-client total and asserts the antigravity-cli exclusion"
}

test_cycle_to_date_rolls_the_cycle_start_forward() {
  local home out
  home=$(make_home cycle); fresh_world "$home"
  set_hourly "$home" codex "[$(bucket '2026-09-10 10:00' '["codex"]' '["gpt-6.1-sol"]' 30),$(bucket '2026-09-30 10:00' '["codex"]' '["gpt-6.1-sol"]' 10)]"
  vl "$home" init >/dev/null
  jq '(.pools[] | select(.id == "codex-plus") | .cycle_start) = "2026-07-29"' "$home/data/value-ledger/lanes.json" > "$home/lanes.new" && mv "$home/lanes.new" "$home/data/value-ledger/lanes.json"
  sample_at "$home" "2026-10-01 21:05"
  assert_equals 2026-09-29 "$(jq -s -r '.[0].since' "$home/data/value-ledger/ledger.jsonl")" "the backfill starts at the current cycle, not the registered one"
  out=$(rollup_json "$home")
  assert_equals 2026-09-29 "$(jq -r '.pools["codex-plus"].cycle_to_date.cycle_start' <<<"$out")" "a July 29 billing day rolls to September 29"
  assert_equals 10 "$(jq '.pools["codex-plus"].cycle_to_date.v' <<<"$out")" "the previous cycle's hours are not in cycle-to-date"
  assert_equals 0.5 "$(jq '.pools["codex-plus"].payback.v' <<<"$out")" "payback is this cycle only"
  pass "cycle-to-date never spans two billing cycles"
}

test_claude_max_idle_premise_has_a_verdict() {
  local home out
  home=$(make_home premise); fresh_world "$home"; vl "$home" init >/dev/null
  sample_at "$home" "2026-10-01 21:05"
  set_quota "$home" 79 "2026-10-08T00:00:00.201787+00:00" 50
  sample_at "$home" "2026-10-02 21:05"
  out=$(rollup_json "$home")
  assert_equals "holds: idle" "$(jq -r '.pools["claude-max"].premise.verdict' <<<"$out")" "one point in a day is idle"
  assert_equals "open primary-lane call" "$(jq -r '.pools["claude-max"].premise.src' <<<"$out")" "the verdict names the premise it tests"
  set_quota "$home" 50 "2026-10-08T00:00:00.201787+00:00" 50
  sample_at "$home" "2026-10-03 21:05"
  vl "$home" rollup >/dev/null
  assert_equals "fails: in use" "$(rollup_json "$home" | jq -r '.pools["claude-max"].premise.verdict')" "thirty points in two days is not idle"
  vl "$home" dashboard >/dev/null || fail "dashboard failed"
  assert_contains "$(cat "$home/data/value-ledger/plan-payback.html")" "fails: in use" "the panel shows the premise verdict"
  pass "the claude-max idle premise is tested in the rollup and the panel"
}

test_rollup_and_verify_runs_are_counted_by_actor() {
  local home out
  home=$(make_home actors); fresh_world "$home"
  two_samples "$home" 70
  vl "$home" rollup --actor agent >/dev/null
  vl "$home" verify --actor agent >/dev/null || fail "verify failed"
  assert_equals agent "$(jq -s -r '[.[] | select(.schema == "fm.value.rollup.v1")][-1].actor' "$home/data/value-ledger/ledger.jsonl")" "the rollup row records its actor"
  assert_equals match "$(jq -s -r '[.[] | select(.schema == "fm.value.verify.v1")][-1].result' "$home/data/value-ledger/ledger.jsonl")" "verify logs its run"
  sample_at "$home" "2026-10-02 01:05"
  out=$(rollup_json "$home")
  assert_equals '{"agent":2,"check":1,"manual":2}' "$(jq -c .actor_counts <<<"$out")" "every run kind counts by actor"
  assert_equals '{"agent":1}' "$(jq -c .run_counts.rollup <<<"$out")" "agent rollups are counted"
  assert_equals '{"agent":1}' "$(jq -c .run_counts.verify <<<"$out")" "agent verifies are counted"
  pass "rollup and verify rows carry an actor and are counted from the ledger"
}

test_aligned_pair_gives_dollars_per_point_with_band_and_bias
test_narrow_sample_does_not_count
test_reset_between_samples_is_never_paired
test_resets_at_jitter_is_not_a_reset
test_contaminated_pair_is_flagged_not_averaged
test_unaligned_read_is_not_counted
test_cross_client_attribution_and_exclusion
test_rollup_is_deterministic_and_verifiable
test_altered_capture_is_detected
test_codex_cycle_to_date_and_payback_need_a_cycle_start
test_check_prints_one_line_on_failure_once_a_day_and_stays_silent_otherwise
test_not_fresh_quota_prints_the_line
test_arm_registers_and_disarm_removes
test_dashboard_draws_the_panel_and_the_alert
test_pi_gpt_through_a_plain_api_key_is_not_charged_to_codex_plus
test_conservation_reconciles_the_total_and_names_the_exclusion
test_cycle_to_date_rolls_the_cycle_start_forward
test_claude_max_idle_premise_has_a_verdict
test_rollup_and_verify_runs_are_counted_by_actor
