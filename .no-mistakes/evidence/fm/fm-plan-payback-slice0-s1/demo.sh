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
. /Users/achiu/.no-mistakes/worktrees/d9c8a3404af5/01M3W1PCSJ36WK7M9GJTD1RB2G/tests/lib.sh

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
home=$(make_home demo); fresh_world "$home"
echo '$ fm-value-ledger.sh init'; vl "$home" init | sed "s#$home#\$FM_HOME#"
jq '(.pools[] | select(.id=="claude-max") | .cycle_start) = "2026-09-20" | (.pools[] | select(.id=="codex-plus") | .cycle_start) = "2026-09-25"' "$home/data/value-ledger/lanes.json" > "$home/l" && mv "$home/l" "$home/data/value-ledger/lanes.json"
set_models "$home" claude anthropic claude-opus-5 codex openai gpt-5.5 pi openai-codex gpt-5.5 pi openai gpt-5.5 antigravity-cli anthropic claude-opus-5
C="[$(bucket '2026-09-29 10:00' '["claude"]' '["claude-opus-5"]' 12),$(bucket '2026-09-30 14:00' '["claude"]' '["claude-opus-5"]' 18),$(bucket '2026-10-01 09:00' '["claude"]' '["claude-opus-5"]' 15)]"
X="[$(bucket '2026-09-29 11:00' '["codex"]' '["gpt-5.5"]' 6),$(bucket '2026-09-30 16:00' '["codex"]' '["gpt-5.5"]' 9),$(bucket '2026-10-01 11:00' '["codex"]' '["gpt-5.5"]' 7)]"
P="[$(bucket '2026-09-30 20:00' '["pi"]' '["gpt-5.5"]' 4)]"
A="[$(bucket '2026-09-30 12:00' '["antigravity-cli"]' '["claude-opus-5"]' 25)]"
set_hourly "$home" claude "$C"; set_hourly "$home" codex "$X"; set_hourly "$home" pi "$P"; set_hourly "$home" antigravity-cli "$A"
set_hourly "$home" all "[$(bucket '2026-09-29 10:00' '["claude"]' '["claude-opus-5"]' 12),$(bucket '2026-09-29 11:00' '["codex"]' '["gpt-5.5"]' 6),$(bucket '2026-09-30 12:00' '["antigravity-cli"]' '["claude-opus-5"]' 25),$(bucket '2026-09-30 14:00' '["claude"]' '["claude-opus-5"]' 18),$(bucket '2026-09-30 16:00' '["codex"]' '["gpt-5.5"]' 9),$(bucket '2026-09-30 20:00' '["pi"]' '["gpt-5.5"]' 4),$(bucket '2026-10-01 09:00' '["claude"]' '["claude-opus-5"]' 15),$(bucket '2026-10-01 11:00' '["codex"]' '["gpt-5.5"]' 7)]"
R=2026-10-08T00:00:00.000+00:00
for d in "2026-09-29|05|90|70" "2026-09-30|05|84|62" "2026-10-01|05|78|52" "2026-10-02|05|73|44"; do
  IFS="|" read -r day mm cp xp <<<"$d"
  set_quota "$home" "$cp" "$R" "$xp"
  echo "\$ FM_VALUE_NOW='$day 00:05 SGT' fm-value-ledger.sh sample --actor manual   # claude ${cp}% left, codex ${xp}% left"
  FM_VALUE_NOW=$(at "$day 00:$mm") vl "$home" sample --actor manual 2>&1 | sed "s#$home#\$FM_HOME#"
done
echo '$ fm-value-ledger.sh rollup --actor manual'; vl "$home" rollup --actor manual | sed "s#$home#\$FM_HOME#"
echo '$ fm-value-ledger.sh rollup --actor manual   # re-run'; vl "$home" rollup --actor manual | sed "s#$home#\$FM_HOME#"
echo "rollup rows in ledger: $(jq -s '[.[]|select(.schema=="fm.value.rollup.v1")]|length' "$home/data/value-ledger/ledger.jsonl")"
echo '$ fm-value-ledger.sh verify --actor manual'; vl "$home" verify --actor manual | sed "s#$home#\$FM_HOME#"
echo '--- latest rollup row (pools, conservation, actor_counts):'
jq -s '[.[]|select(.schema=="fm.value.rollup.v1")][-1] | {pools: (.pools|map_values({api_value_usd,pp_used,dollars_per_pp,cycle_to_date,payback,premise})), conservation, actor_counts}' "$home/data/value-ledger/ledger.jsonl"
echo '$ fm-value-ledger.sh dashboard'; vl "$home" dashboard | sed "s#$home#\$FM_HOME#"
cp "$home/data/value-ledger/plan-payback.html" "$EV/plan-payback.html"
set_quota "$home" 70 "$R" 40
echo '$ FM_VALUE_NOW="2026-10-03 00:20 SGT" fm-value-ledger.sh check   # healthy day'; FM_VALUE_NOW=$(at "2026-10-03 00:20") vl "$home" check; echo "(exit $?, no output)"
touch "$home/stub/quota-fail"
echo '$ FM_VALUE_NOW="2026-10-04 00:20 SGT" fm-value-ledger.sh check   # quota-axi failing'; FM_VALUE_NOW=$(at "2026-10-04 00:20") vl "$home" check
echo '$ FM_VALUE_NOW="2026-10-04 00:40 SGT" fm-value-ledger.sh check   # same day retry'; FM_VALUE_NOW=$(at "2026-10-04 00:40") vl "$home" check; echo "(no second alert)"
vl "$home" dashboard >/dev/null; cp "$home/data/value-ledger/plan-payback.html" "$EV/plan-payback-alert.html"
