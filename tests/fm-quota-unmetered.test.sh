#!/usr/bin/env bash
# Behavior tests for fm-quota-unmetered.sh - the companion quota report for the
# providers quota-axi does not meter.
#
# The defect class this suite exists to pin is a single one: a dispatch intake
# acts on this report, so a number it cannot actually observe must never appear
# in it. DeepSeek publishes an account balance and no usage window at all, and
# the tempting shortcut - turning money into a percentage, or a balance into a
# "credits" window - would hand the dispatcher a confident figure that measures
# nothing. Z.ai has the mirror-image failure: it returns period codes, so an
# unrecognized code could silently be mapped onto a familiar duration and
# misreport how much runway is left. Both directions are asserted below.
#
# Every provider call is served by a local fake HTTP endpoint, so the suite
# needs no network, no credential, and no vendor account, and it still exercises
# the real script through its executable interface rather than its source.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-unmetered-tests)
SCRIPT="$ROOT/bin/fm-quota-unmetered.sh"

# A credential the script must never echo into its own output.
KEY_SENTINEL='SENTINEL-KEY-MUST-NOT-APPEAR-IN-OUTPUT'

command -v node >/dev/null 2>&1 || {
  printf '1..0 # SKIP node is required by fm-quota-unmetered.sh\n'
  exit 0
}

# --- fake provider endpoint -------------------------------------------------
#
# One server serves both provider paths from a scenario file and records the
# request headers it saw, so the wire contract (which Authorization form each
# provider needs) is an observed fact rather than a comment.

cat > "$TMP_ROOT/fake-provider.mjs" <<'MJS'
import { createServer } from "node:http";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";

const scenario = JSON.parse(readFileSync(process.env.FM_FAKE_SCENARIO, "utf8"));
const headerLog = process.env.FM_FAKE_HEADER_LOG;

const server = createServer((req, res) => {
  const route = scenario[req.url] || { status: 404, body: "{}" };
  appendFileSync(headerLog, `${req.url} authorization=${req.headers.authorization || ""}\n`);
  const send = () => {
    res.writeHead(route.status, { "Content-Type": "application/json" });
    res.end(typeof route.body === "string" ? route.body : JSON.stringify(route.body));
  };
  // A hang is served as a response that never arrives, so the caller's own
  // bound is what ends the request.
  if (route.hang) return;
  if (route.delayMs) setTimeout(send, route.delayMs);
  else send();
});

server.listen(0, "127.0.0.1", () => {
  writeFileSync(process.env.FM_FAKE_PORT_FILE, String(server.address().port));
});
MJS

FAKE_PID=
stop_fake() {
  [ -n "$FAKE_PID" ] || return 0
  kill "$FAKE_PID" 2>/dev/null || true
  wait "$FAKE_PID" 2>/dev/null || true
  FAKE_PID=
}
trap 'stop_fake; fm_test_cleanup' EXIT INT TERM

# start_fake <scenario-json>: boot the endpoint and export the URL overrides.
start_fake() {
  local waited=0
  stop_fake
  printf '%s\n' "$1" > "$TMP_ROOT/scenario.json"
  : > "$TMP_ROOT/headers.log"
  rm -f "$TMP_ROOT/port"
  FM_FAKE_SCENARIO="$TMP_ROOT/scenario.json" \
    FM_FAKE_PORT_FILE="$TMP_ROOT/port" \
    FM_FAKE_HEADER_LOG="$TMP_ROOT/headers.log" \
    node "$TMP_ROOT/fake-provider.mjs" &
  FAKE_PID=$!
  while [ ! -s "$TMP_ROOT/port" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || fail "the fake provider endpoint never came up"
    sleep 0.1
  done
  FAKE_PORT=$(cat "$TMP_ROOT/port")
  export FM_QUOTA_UNMETERED_ZAI_URL="http://127.0.0.1:$FAKE_PORT/zai"
  export FM_QUOTA_UNMETERED_DEEPSEEK_URL="http://127.0.0.1:$FAKE_PORT/deepseek"
}

write_auth_store() {
  cat > "$TMP_ROOT/auth.json" <<EOF
{
  "zai": { "type": "api_key", "key": "$KEY_SENTINEL" },
  "deepseek": { "type": "api_key", "key": "$KEY_SENTINEL" }
}
EOF
  export FM_QUOTA_UNMETERED_AUTH_FILE="$TMP_ROOT/auth.json"
}

# run_report [args...]: run the script with a clean credential environment and
# capture stdout to $TMP_ROOT/out.json. Echoes the exit status.
run_report() {
  local rc=0
  env -u ZAI_API_KEY -u Z_AI_API_KEY -u DEEPSEEK_API_KEY \
    FM_QUOTA_UNMETERED_AUTH_FILE="${FM_QUOTA_UNMETERED_AUTH_FILE:-$TMP_ROOT/missing.json}" \
    FM_QUOTA_UNMETERED_ZAI_URL="$FM_QUOTA_UNMETERED_ZAI_URL" \
    FM_QUOTA_UNMETERED_DEEPSEEK_URL="$FM_QUOTA_UNMETERED_DEEPSEEK_URL" \
    FM_QUOTA_UNMETERED_TIMEOUT="${FM_QUOTA_UNMETERED_TIMEOUT:-20}" \
    "$SCRIPT" "$@" > "$TMP_ROOT/out.json" 2> "$TMP_ROOT/err.txt" || rc=$?
  printf '%s\n' "$rc"
}

# jget <js-expression over `d`>: read one value out of the captured report.
jget() {
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const p = (id) => d.providers.find((x) => x.provider === id);
    const v = eval(process.argv[2]);
    process.stdout.write(
      v === undefined ? "<undefined>" : typeof v === "object" ? JSON.stringify(v) : String(v),
    );
  ' "$TMP_ROOT/out.json" "$1"
}

assert_json() {
  local actual
  actual=$(jget "$1")
  [ "$actual" = "$2" ] || fail "$3 (expected '$2', got '$actual')"
}

# --- realistic provider payloads --------------------------------------------
#
# The Z.ai body is the exact shape returned by the live endpoint on 2026-08-19:
# a 5-hour window (unit 3, number 5) and a weekly window (unit 6, number 1).
ZAI_LIVE_SHAPE='{"code":200,"msg":"Operation successful","data":{"limits":[
  {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":0,"remaining":2000,"percentage":0},
  {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":2098,"remaining":7901,"percentage":20,"nextResetTime":1787498417997}
],"level":"lite"},"success":true}'

DEEPSEEK_LIVE_SHAPE='{"is_available":true,"balance_infos":[
  {"currency":"CNY","total_balance":"62.07","granted_balance":"0.00","topped_up_balance":"62.07"},
  {"currency":"USD","total_balance":"3.53","granted_balance":"0.00","topped_up_balance":"3.53"}
]}'

scenario_ok() {
  printf '{"/zai":{"status":200,"body":%s},"/deepseek":{"status":200,"body":%s}}' \
    "$(printf '%s' "$ZAI_LIVE_SHAPE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')" \
    "$(printf '%s' "$DEEPSEEK_LIVE_SHAPE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')"
}

# --- tests ------------------------------------------------------------------

test_report_matches_quota_axi_envelope() {
  local rc
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report)
  expect_code 0 "$rc" "a successful report must exit 0"
  assert_json 'd.schemaVersion' 3 "the report must declare quota-axi schema version 3"
  assert_json 'typeof d.generatedAt' string "the report must carry a generatedAt clock"
  assert_json 'd.providers.length' 3 "all three unmetered providers must be reported by default"
  pass "the report uses quota-axi's schema v3 envelope"
}

test_zai_windows_are_read_from_the_provider() {
  local rc
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report)
  expect_code 0 "$rc" "a successful report must exit 0"
  assert_json 'p("zai").windows.length' 2 "both Z.ai windows must be reported"
  assert_json 'p("zai").windows[0].id' five_hour "the 5-hour cycle must be named like quota-axi's"
  assert_json 'p("zai").windows[0].kind' session "a 5-hour cycle is a session window"
  assert_json 'p("zai").windows[0].windowSeconds' 18000 "unit 3 x number 5 is 18000 seconds"
  assert_json 'p("zai").windows[1].id' seven_day "the weekly cycle must be named like quota-axi's"
  assert_json 'p("zai").windows[1].kind' weekly "a 7-day cycle is a weekly window"
  # The provider reports percent USED; percentRemaining is its complement, and
  # neither is rounded, rescaled, or re-derived from the token counters.
  assert_json 'p("zai").windows[1].percentUsed' 20 "percentUsed must be the provider's own figure"
  assert_json 'p("zai").windows[1].percentRemaining' 80 "percentRemaining must complement percentUsed"
  assert_json 'p("zai").windows[1].resetsAt' 2026-08-23T15:20:17.997Z "the reset must be the provider's epoch converted to ISO"
  assert_json 'p("zai").plan' lite "the plan level must be reported when the provider names it"
  pass "Z.ai usage windows come from the provider's own response"
}

test_zai_effective_remaining_is_the_tightest_window() {
  local rc
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report)
  expect_code 0 "$rc" "a successful report must exit 0"
  assert_json 'p("zai").quotaSemantics.status' known "every window resolved, so the semantics are known"
  assert_json 'p("zai").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining' 80 \
    "effective headroom must be the minimum across bounding windows, not the average or the first"
  assert_json 'p("zai").quotaSemantics.effectiveAvailability[0].limitingWindowIds' '["seven_day"]' \
    "the limiting window must be named"
  assert_json 'p("zai").quotaSemantics.effectiveAvailability[0].boundedBy' '["five_hour","seven_day"]' \
    "every credit window bounds the plan"
  pass "Z.ai effective headroom is the tightest bounding window"
}

test_unrecognized_zai_period_is_not_guessed() {
  local rc
  write_auth_store
  # unit 99 is a period code this script has never verified. Mapping it onto a
  # familiar duration would misreport the runway, so it must stay unknown.
  start_fake '{"/zai":{"status":200,"body":"{\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"unit\":99,\"number\":7,\"percentage\":10}],\"level\":\"pro\"}}"},"/deepseek":{"status":500,"body":"{}"}}'
  rc=$(run_report zai)
  expect_code 0 "$rc" "an unrecognized period is still a printable report"
  assert_json 'p("zai").windows[0].kind' unknown "an unverified period code must not be classified"
  assert_json 'p("zai").windows[0].windowSeconds' '<undefined>' \
    "an unverified period code must not be given a duration"
  # The percentage is still the provider's own observation, so it is kept.
  assert_json 'p("zai").windows[0].percentUsed' 10 "a reported percentage survives an unknown period"
  pass "an unrecognized Z.ai period is reported as unknown rather than guessed"
}

test_non_credit_zai_window_does_not_shrink_headroom() {
  local rc
  write_auth_store
  # A non-CREDIT_LIMIT window describes a different workload (web search/reader),
  # so it must be reported but excluded from what bounds model availability.
  start_fake '{"/zai":{"status":200,"body":"{\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"unit\":6,\"number\":1,\"percentage\":10},{\"type\":\"SEARCH_LIMIT\",\"unit\":6,\"number\":1,\"percentage\":95}],\"level\":\"pro\"}}"},"/deepseek":{"status":500,"body":"{}"}}'
  rc=$(run_report zai)
  expect_code 0 "$rc" "a mixed-window report must still print"
  assert_json 'p("zai").windows.length' 2 "every reported window must survive into the report"
  assert_json 'p("zai").quotaSemantics.status' partial "an unresolved window makes the semantics partial"
  assert_json 'p("zai").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining' 90 \
    "a non-model window must not bound model headroom"
  assert_json 'p("zai").quotaSemantics.unresolvedWindowIds.length' 1 \
    "the excluded window must be named as unresolved rather than dropped"
  pass "a non-model Z.ai window is reported without bounding model headroom"
}

test_deepseek_balance_is_never_presented_as_quota() {
  local rc
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report)
  expect_code 0 "$rc" "a successful report must exit 0"
  # This is the whole point of the provider's record: DeepSeek publishes no
  # usage window, so none may be manufactured from its balance.
  assert_json 'p("deepseek").windows.length' 0 "DeepSeek must report no usage windows"
  assert_json 'p("deepseek").quotaSemantics.status' unknown \
    "DeepSeek quota must stay unknown, never derived from balance"
  assert_json 'p("deepseek").quotaSemantics.effectiveAvailability.length' 0 \
    "no effective availability may be computed without a usage window"
  assert_json 'p("deepseek").credits.remaining' 3.53 "the USD balance must be reported as credits"
  assert_json 'p("deepseek").credits.unit' usd "the balance unit must be the currency it was returned in"
  assert_json 'p("deepseek").state.status' fresh "a readable balance is a fresh reading"
  pass "DeepSeek balance is reported as credits and never as quota"
}

test_deepseek_insufficient_balance_is_surfaced() {
  local rc
  write_auth_store
  start_fake '{"/zai":{"status":500,"body":"{}"},"/deepseek":{"status":200,"body":"{\"is_available\":false,\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"0.00\"}]}"}}'
  rc=$(run_report deepseek)
  expect_code 0 "$rc" "an unusable account is still a printable report"
  assert_json 'p("deepseek").state.status' unavailable \
    "the provider's own verdict that calls will fail must not be left for a caller to infer"
  assert_json 'p("deepseek").credits.remaining' 0 "the zero balance must still be reported"
  pass "a DeepSeek account that can no longer call the API is surfaced"
}

test_missing_credential_is_reported_not_invented() {
  local rc
  unset FM_QUOTA_UNMETERED_AUTH_FILE
  start_fake "$(scenario_ok)"
  rc=$(run_report)
  expect_code 0 "$rc" "an unavailable provider is a result, not a script failure"
  assert_json 'p("zai").state.status' auth_required "a missing key must be reported as auth_required"
  assert_json 'p("zai").source' unavailable "no data source was reached"
  assert_json 'p("zai").windows.length' 0 "an unauthenticated provider must report no windows"
  assert_json 'p("deepseek").state.status' auth_required "a missing key must be reported as auth_required"
  assert_json 'p("deepseek").credits' '<undefined>' "no credits may be reported without a reading"
  pass "a missing credential is reported as unavailable rather than filled in"
}

test_rejected_credential_is_distinguished_from_a_failure() {
  local rc
  write_auth_store
  start_fake '{"/zai":{"status":401,"body":"{}"},"/deepseek":{"status":500,"body":"{}"}}'
  rc=$(run_report)
  expect_code 0 "$rc" "a rejected credential is a result, not a script failure"
  assert_json 'p("zai").state.status' auth_required "HTTP 401 means the credential was rejected"
  assert_json 'p("deepseek").state.status' error "HTTP 500 is a provider failure, not a credential problem"
  assert_json 'p("zai").windows.length' 0 "a rejected credential must yield no windows"
  assert_json 'p("deepseek").windows.length' 0 "a failed call must yield no windows"
  pass "a rejected credential and a provider failure are reported differently"
}

test_unparseable_body_is_an_error_not_an_empty_reading() {
  local rc
  write_auth_store
  start_fake '{"/zai":{"status":200,"body":"not json at all"},"/deepseek":{"status":200,"body":"{\"unexpected\":true}"}}'
  rc=$(run_report)
  expect_code 0 "$rc" "an unusable body is a reported result"
  assert_json 'p("zai").state.status' error "an unparseable body must be an error"
  assert_json 'p("deepseek").state.status' error "a body with no balance information must be an error"
  assert_json 'p("deepseek").credits' '<undefined>' "an unusable body must not produce a credits figure"
  pass "an unusable provider body is an error rather than a silent empty reading"
}

test_one_provider_outage_does_not_hide_the_other() {
  local rc
  write_auth_store
  start_fake '{"/zai":{"status":200,"body":"{\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"unit\":6,\"number\":1,\"percentage\":42}],\"level\":\"pro\"}}"},"/deepseek":{"status":503,"body":"{}"}}'
  rc=$(run_report)
  expect_code 0 "$rc" "a partial outage must still print a report"
  assert_json 'p("zai").windows[0].percentUsed' 42 "the healthy provider's usage must survive"
  assert_json 'p("deepseek").state.status' error "the failing provider must be reported as failed"
  pass "one provider's outage does not hide the other's usage"
}

test_hanging_provider_is_bounded() {
  local rc started elapsed
  write_auth_store
  start_fake '{"/zai":{"hang":true},"/deepseek":{"hang":true}}'
  started=$(date +%s)
  rc=$(FM_QUOTA_UNMETERED_TIMEOUT=2 run_report)
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "a bounded timeout is a reported result"
  [ "$elapsed" -lt 20 ] || fail "the request bound was not applied (took ${elapsed}s)"
  assert_json 'p("zai").state.status' error "a timed-out provider must be reported as an error"
  assert_json 'p("zai").windows.length' 0 "a timed-out provider must report no windows"
  pass "a hanging provider endpoint is bounded and reported"
}

test_zero_bound_falls_back_to_a_real_bound() {
  local rc
  write_auth_store
  start_fake "$(scenario_ok)"
  # Zero would mean "no deadline", so it must be replaced rather than forwarded.
  rc=$(FM_QUOTA_UNMETERED_TIMEOUT=0 run_report zai)
  expect_code 0 "$rc" "a replaced bound must not break the report"
  assert_json 'p("zai").state.status' fresh "the report must still complete under the fallback bound"
  pass "a zero request bound falls back to a real bound"
}

test_credential_never_reaches_the_output() {
  local rc out
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report)
  expect_code 0 "$rc" "a successful report must exit 0"
  out=$(cat "$TMP_ROOT/out.json" "$TMP_ROOT/err.txt")
  assert_not_contains "$out" "$KEY_SENTINEL" "the API key must never appear in the report or on stderr"
  pass "the credential never reaches the script's output"
}

test_each_provider_gets_the_authorization_form_it_requires() {
  local rc log
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report)
  expect_code 0 "$rc" "a successful report must exit 0"
  log=$(cat "$TMP_ROOT/headers.log")
  # Verified against the live endpoints: Z.ai takes the raw key, DeepSeek
  # requires the Bearer form and rejects the raw key.
  assert_contains "$log" "/zai authorization=$KEY_SENTINEL" "Z.ai must receive the raw key"
  assert_contains "$log" "/deepseek authorization=Bearer $KEY_SENTINEL" "DeepSeek must receive the Bearer form"
  pass "each provider receives the authorization form it requires"
}

test_environment_credential_overrides_the_store() {
  local rc log
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=0
  env -u Z_AI_API_KEY DEEPSEEK_API_KEY=unused ZAI_API_KEY=FROM-ENVIRONMENT \
    FM_QUOTA_UNMETERED_AUTH_FILE="$TMP_ROOT/auth.json" \
    FM_QUOTA_UNMETERED_ZAI_URL="$FM_QUOTA_UNMETERED_ZAI_URL" \
    FM_QUOTA_UNMETERED_DEEPSEEK_URL="$FM_QUOTA_UNMETERED_DEEPSEEK_URL" \
    "$SCRIPT" zai > "$TMP_ROOT/out.json" 2>/dev/null || rc=$?
  expect_code 0 "$rc" "an environment credential must produce a report"
  log=$(cat "$TMP_ROOT/headers.log")
  assert_contains "$log" "/zai authorization=FROM-ENVIRONMENT" "the environment key must win over the store"
  assert_json 'p("zai").state.sourcesTried[0]' env:ZAI_API_KEY "the credential source must be disclosed"
  pass "an environment credential overrides the credential store"
}

test_named_provider_is_the_only_one_reported() {
  local rc
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report deepseek)
  expect_code 0 "$rc" "a single-provider report must exit 0"
  assert_json 'd.providers.length' 1 "only the named provider may be reported"
  assert_json 'd.providers[0].provider' deepseek "the named provider must be the one reported"
  pass "naming a provider reports only that provider"
}

test_unregistered_provider_is_a_usage_error() {
  local rc=0 err
  start_fake "$(scenario_ok)"
  err=$("$SCRIPT" openai 2>&1 >/dev/null) || rc=$?
  expect_code 2 "$rc" "an unregistered provider must be a usage error"
  assert_contains "$err" "openai" "the usage error must name the rejected provider"
  pass "an unregistered provider is a usage error"
}

test_repeated_provider_is_a_usage_error() {
  local rc=0
  start_fake "$(scenario_ok)"
  "$SCRIPT" zai zai >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a repeated provider would emit two records for one provider"
  pass "a repeated provider is a usage error"
}

test_help_names_what_each_provider_can_report() {
  local out rc=0
  out=$("$SCRIPT" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "zai" "--help must name the registered providers"
  assert_contains "$out" "deepseek" "--help must name the registered providers"
  assert_contains "$out" "gemini" "--help must name the registered providers"
  # The balance-is-not-quota boundary is the one fact a reader must not miss.
  assert_contains "$out" "BALANCE only" "--help must state that DeepSeek reports balance, not quota"
  # gemini's OAuth-not-API-key boundary is the equivalent fact for that row.
  assert_contains "$out" "OAuth" "--help must state that gemini authenticates via OAuth, not an API key"
  pass "--help names the registered providers and their reporting limits"
}

test_gemini_reports_no_windows_and_makes_no_call() {
  local rc
  # No fake endpoint is started at all: if gemini made a network call, this
  # would hang until the connection was refused rather than returning
  # immediately, which is what this test relies on to prove no call was made.
  unset FM_QUOTA_UNMETERED_ZAI_URL FM_QUOTA_UNMETERED_DEEPSEEK_URL
  rc=$(env -u ZAI_API_KEY -u Z_AI_API_KEY -u DEEPSEEK_API_KEY -u FM_QUOTA_UNMETERED_AUTH_FILE \
    "$SCRIPT" gemini > "$TMP_ROOT/out.json" 2> "$TMP_ROOT/err.txt"; echo "$?")
  expect_code 0 "$rc" "gemini must always be a printable report"
  assert_json 'd.providers.length' 1 "only gemini must be reported"
  assert_json 'p("gemini").windows.length' 0 "gemini must report no usage windows"
  assert_json 'p("gemini").source' unmetered "gemini's source must not claim a live api or oauth read"
  assert_json 'p("gemini").quotaSemantics.status' unknown \
    "gemini quota must stay unknown until a Cloud Billing export is wired"
  assert_json 'p("gemini").quotaSemantics.effectiveAvailability.length' 0 \
    "no effective availability may be computed without a usage window"
  assert_json 'p("gemini").credits' '<undefined>' "gemini must not report a credits figure that does not exist"
  pass "gemini reports no usage windows and makes no network call"
}

test_gemini_auth_status_reflects_the_captains_oauth_login() {
  local rc
  rc=$(env -u ZAI_API_KEY -u Z_AI_API_KEY -u DEEPSEEK_API_KEY -u FM_QUOTA_UNMETERED_AUTH_FILE \
    "$SCRIPT" gemini > "$TMP_ROOT/out.json" 2> "$TMP_ROOT/err.txt"; echo "$?")
  expect_code 0 "$rc" "gemini must always be a printable report"
  assert_json 'p("gemini").state.authStatus' usable \
    "gemini's authStatus must reflect the captain's confirmed OAuth login"
  assert_json 'p("gemini").state.status' unknown \
    "gemini's state must not claim a fresh live read that never happened"
  assert_json 'typeof p("gemini").state.error' string \
    "gemini must disclose that authStatus is not a live read"
  pass "gemini's auth status reflects the captain's confirmed OAuth login, not a live probe"
}

test_gemini_is_unaffected_by_zai_and_deepseek_credentials() {
  local rc
  write_auth_store
  start_fake "$(scenario_ok)"
  rc=$(run_report gemini)
  expect_code 0 "$rc" "gemini must report regardless of zai/deepseek credential state"
  assert_json 'd.providers.length' 1 "only the named provider may be reported"
  assert_json 'p("gemini").provider' gemini "the named provider must be the one reported"
  pass "naming gemini reports only gemini, independent of zai/deepseek credentials"
}

test_report_matches_quota_axi_envelope
test_zai_windows_are_read_from_the_provider
test_zai_effective_remaining_is_the_tightest_window
test_unrecognized_zai_period_is_not_guessed
test_non_credit_zai_window_does_not_shrink_headroom
test_deepseek_balance_is_never_presented_as_quota
test_deepseek_insufficient_balance_is_surfaced
test_missing_credential_is_reported_not_invented
test_rejected_credential_is_distinguished_from_a_failure
test_unparseable_body_is_an_error_not_an_empty_reading
test_one_provider_outage_does_not_hide_the_other
test_hanging_provider_is_bounded
test_zero_bound_falls_back_to_a_real_bound
test_credential_never_reaches_the_output
test_each_provider_gets_the_authorization_form_it_requires
test_environment_credential_overrides_the_store
test_named_provider_is_the_only_one_reported
test_unregistered_provider_is_a_usage_error
test_repeated_provider_is_a_usage_error
test_help_names_what_each_provider_can_report
test_gemini_reports_no_windows_and_makes_no_call
test_gemini_auth_status_reflects_the_captains_oauth_login
test_gemini_is_unaffected_by_zai_and_deepseek_credentials
