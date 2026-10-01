#!/usr/bin/env bash
# fm-value-ledger.sh - Plan payback: what each subscription plan carried, priced
# at API-equivalent cost, per percentage point of quota and against its fee.
#
# Usage:
#   fm-value-ledger.sh init                 write data/value-ledger/lanes.json when absent
#   fm-value-ledger.sh sample [--actor A]   capture raw instrument output and append one sample row
#   fm-value-ledger.sh rollup [--dry]       derive the rollup row from the ledger and its captures
#   fm-value-ledger.sh verify               re-derive the latest rollup and diff it against the stored row
#   fm-value-ledger.sh dashboard            write dashboard.json and the one-panel plan-payback.html
#   fm-value-ledger.sh check                the daily trigger; prints one line only when a human must act
#   fm-value-ledger.sh arm | disarm         write and register, or remove, state/value-ledger.check.sh
#   fm-value-ledger.sh --help
#
# Data lives in data/value-ledger/ (private, gitignored with data/):
#   lanes.json       pool registry: quota window, plan tier and price, billing-cycle start,
#                    attribution rules, unseen surfaces - each fact carries its source
#   ledger.jsonl     append-only sample and rollup rows
#   captures/<id>/   the raw quota-axi, tokscale and codeburn output behind each sample
#   dashboard.json, plan-payback.html   generated, disposable
#   prices/*.json    optional first-party per-model price tables (used by the price check only)
#
# Measurement rules (each is a required fix from the adversarial review):
#  - Alignment: a quota read is paired with tokscale HOURLY buckets from the previous
#    read's hour up to, excluding, this read's hour; never with differenced --today
#    snapshots. A pair whose reads were taken more than 20 minutes into their hour is
#    flagged unaligned and is not counted.
#  - Resets: samples are never paired across a changed resetsAt or a rise in remaining quota.
#  - Denominator: quota is an integer, so every dollars-per-point figure carries the band
#    api/(pp+n) .. api/(pp-n), n = unbroken sample chains, and counts only when that band
#    is narrower than 25% of the figure. A pair where quota moved but local draw is under
#    USD 1 is contaminated: it is listed and never averaged in.
#  - Coverage honesty is mechanical: rollup never reads a number a sample stored. It
#    re-derives every cell from the captures, whose sha256 are recorded in the sample.
#    A pool with unseen surfaces displays its figure as biased low, in the figure itself.
#  - Determinism: rollup is a pure function of the ledger prefix plus the captures. Its row
#    is keyed by an input hash, so a re-run appends nothing, and verify diffs a re-derivation
#    against the stored row with zero tolerance (only written_at differs).
#  - Cost: every sample records its actor (check, manual, agent); rollup counts them.
#  - Pre-conditions for a number to be called measured: the tokscale cost used here is
#    tokscale's own (LiteLLM) price. Hourly buckets mix models, so they cannot be re-priced
#    from a first-party table; the first-party table instead checks tokscale's per-model
#    rows, and codeburn checks the numerator as an independent meter.
#
# `check` runs sample and rollup at the first sweep at or after 00:15 SGT each day, which
# reads only closed hours. It prints one line when an instrument failed, when a pool read
# is not fresh, when the day's row could not be written, or when whole days are missing.
# Otherwise it prints nothing. FM_VALUE_NOW (epoch seconds) overrides the clock for tests,
# FM_VALUE_SINCE_DAYS (default 7) bounds the backfill when no cycle start is registered.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
VL_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}/value-ledger"
LANES="$VL_DIR/lanes.json"
LEDGER="$VL_DIR/ledger.jsonl"
CAPS="$VL_DIR/captures"
CHECK_ID=value-ledger
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
MARK_DAY="$STATE/.value-ledger-last-day"
MARK_FAIL="$STATE/.value-ledger-fail"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
export TZ=Asia/Singapore
ALIGN_MIN=20
CONTAM_USD=1
BAND_MAX=0.25

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-value-ledger: %s\n' "$*" >&2; exit 1; }
now_epoch() { printf '%s\n' "${FM_VALUE_NOW:-$(date +%s)}"; }
fmt_at() { date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2"; }
day_epoch() { date -j -f %Y-%m-%d "$1" +%s 2>/dev/null || date -d "$1" +%s; }

have() { command -v "$1" >/dev/null 2>&1; }

need_lanes() { [ -f "$LANES" ] || die "no registry at $LANES (run: fm-value-ledger.sh init)"; jq -e '.pools|length>0' "$LANES" >/dev/null 2>&1 || die "unreadable registry $LANES"; }

action_init() {
  mkdir -p "$VL_DIR" || return 1
  [ ! -f "$LANES" ] || { printf 'present: %s\n' "$LANES"; return 0; }
  cat > "$LANES" <<'JSON'
{
  "version": "1",
  "pools": [
    {
      "id": "claude-max",
      "quota_provider": "claude",
      "quota_window": "seven_day",
      "plan": {"name": "max", "tier": "5x", "tier_confirmed": false, "price_usd_month": 100,
               "price_src": "support.claude.com/en/articles/11049741 (Max 5x USD 100/month); quota-axi reports plan max without a tier, so the tier is unconfirmed"},
      "cycle_start": null,
      "cycle_start_src": "unknown - the billing day is not exposed by quota-axi; set it from the Anthropic billing page, YYYY-MM-DD",
      "rules": [{"client": "claude", "model_re": "^claude-"}],
      "unseen_surfaces": ["claude.ai web", "Claude Desktop", "phone", "other machines"],
      "codeburn": {"provider": "claude", "clients": ["claude"]}
    },
    {
      "id": "codex-plus",
      "quota_provider": "codex",
      "quota_window": "weekly",
      "plan": {"name": "plus", "tier": "plus", "tier_confirmed": true, "price_usd_month": 20,
               "price_src": "developers.openai.com/codex/pricing (Plus USD 20/month)"},
      "cycle_start": null,
      "cycle_start_src": "unknown - set it from the ChatGPT billing page, YYYY-MM-DD",
      "rules": [{"client": "codex", "model_re": "^gpt-"}, {"client": "pi", "model_re": "^gpt-"}],
      "unseen_surfaces": ["ChatGPT web", "other machines"],
      "codeburn": {"provider": "codex", "clients": ["codex"]}
    }
  ]
}
JSON
  printf 'wrote: %s\n' "$LANES"
}

# ---------------------------------------------------------------- sample

capture_cmd() { # capture_cmd <outfile> <cmd...>
  local out=$1; shift
  "$@" > "$out" 2>/dev/null
}

action_sample() {
  local actor=manual ep id dir since clients c pool fail="" today
  while [ $# -gt 0 ]; do
    case $1 in
      --actor) actor=${2:-}; shift 2 ;;
      *) die "unknown sample option: $1" ;;
    esac
  done
  case $actor in check|manual|agent) ;; *) die "actor must be check, manual, or agent" ;; esac
  need_lanes
  if ! have quota-axi || ! have tokscale || ! have jq; then die "quota-axi, tokscale and jq are required"; fi
  ep=$(now_epoch)
  id="s-$(TZ=UTC fmt_at "$ep" +%Y%m%dT%H%M%SZ)"
  dir="$CAPS/$id"
  mkdir -p "$dir" || return 1
  today=$(fmt_at "$ep" +%Y-%m-%d)
  since=$(jq -r '[.pools[].cycle_start // empty] | min // empty' "$LANES")
  if [ -z "$since" ]; then
    since=$(date -r $((ep - ${FM_VALUE_SINCE_DAYS:-7} * 86400)) +%Y-%m-%d)
  fi
  clients=$(jq -r '[.pools[].rules[].client] | unique | .[]' "$LANES")

  capture_cmd "$dir/quota.json" quota-axi --json && jq -e '.providers' "$dir/quota.json" >/dev/null 2>&1 || fail="$fail quota-axi"
  capture_cmd "$dir/hourly-all.json" tokscale hourly --since "$since" --until "$today" --json && jq -e '.entries' "$dir/hourly-all.json" >/dev/null 2>&1 || fail="$fail tokscale-hourly"
  for c in $clients; do
    capture_cmd "$dir/hourly-$c.json" tokscale hourly -c "$c" --since "$since" --until "$today" --json && jq -e '.entries' "$dir/hourly-$c.json" >/dev/null 2>&1 || fail="$fail tokscale-hourly-$c"
  done
  capture_cmd "$dir/models.json" tokscale models --since "$since" --until "$today" --group-by client,provider,model --json && jq -e '.entries' "$dir/models.json" >/dev/null 2>&1 || fail="$fail tokscale-models"
  if have codeburn; then
    for pool in $(jq -r '.pools[] | select(.codeburn) | .codeburn.provider' "$LANES" | sort -u); do
      capture_cmd "$dir/codeburn-$pool.txt" codeburn overview --from "$since" --to "$today" --no-color --provider "$pool" || : > "$dir/codeburn-$pool.txt"
    done
  fi
  if [ -n "$fail" ]; then
    rm -rf -- "$dir"
    printf 'fm-value-ledger: instrument failed:%s\n' "$fail" >&2
    return 1
  fi

  local shas qv tv
  shas=$(cd "$dir" && for f in *; do printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done | jq -R 'split("  ") | {(.[1]): .[0]}' | jq -s 'add')
  qv=$(quota-axi --version 2>/dev/null | head -1); tv=$(tokscale --version 2>/dev/null | head -1)
  jq -c -n --arg id "$id" --arg at "$(TZ=UTC fmt_at "$ep" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hour "$(fmt_at "$ep" '+%Y-%m-%d %H:00')" --argjson min "$((10#$(fmt_at "$ep" +%M)))" \
    --arg actor "$actor" --arg since "$since" --argjson shas "$shas" --arg qv "$qv" --arg tv "$tv" \
    --slurpfile lanes "$LANES" --slurpfile quota "$dir/quota.json" '
    def cell($pool; $w; $f):
      ($quota[0].providers[] | select(.provider == $pool.quota_provider)) as $p
      | ($p.windows // [] | map(select(.id == $pool.quota_window)) | .[0]) as $win
      | if $p.state.status == "fresh" and $win != null and ($win.percentRemaining != null)
        then {v: $win.percentRemaining, unit: "pp", status: "measured",
              src: ("captures/\($id)/quota.json#\($pool.quota_provider)/\($pool.quota_window)"),
              resets_at: $win.resetsAt, why: null}
        else {v: null, unit: "pp", status: "missing", src: ("captures/\($id)/quota.json"), resets_at: ($win.resetsAt // null),
              why: ("quota read " + ($p.state.status // "absent") + (if $win == null then ", window absent" else "" end))} end;
    {schema: "fm.value.sample.v1", id: $id, taken_at: $at, hour_sgt: $hour, min_sgt: $min, actor: $actor,
     since: $since, captures: $shas, versions: {quota_axi: $qv, tokscale: $tv, lanes: $lanes[0].version},
     pools: ($lanes[0].pools | map({key: .id, value: cell(.; .quota_window; .)}) | from_entries)}' \
    >> "$LEDGER" || return 1
  printf 'sampled: %s actor=%s\n' "$id" "$actor"
  local missing
  missing=$(tail -1 "$LEDGER" | jq -r '[.pools | to_entries[] | select(.value.status != "measured") | "\(.key): \(.value.why)"] | join("; ")')
  [ -z "$missing" ] || printf 'warn: quota not measured - %s\n' "$missing" >&2
  return 0
}

# ---------------------------------------------------------------- rollup

# bundle_for <capdir> <clients...>: {client: <hourly capture>} for the pair program.
bundle_for() {
  local dir=$1 c; shift
  local args=() expr='{'
  local i=0
  for c in "$@"; do
    args+=(--slurpfile "h$i" "$dir/hourly-$c.json")
    expr="$expr\"$c\": \$h${i}[0],"
    i=$((i + 1))
  done
  expr="${expr%,}}"
  jq -n "${args[@]}" "$expr"
}

# derive: print the rollup row body (no id/written_at) as JSON on stdout.
derive() {
  local samples last cur_id pair_file p clients
  samples=$(jq -c -s '[.[] | select(.schema == "fm.value.sample.v1")] | sort_by(.taken_at)' "$LEDGER" 2>/dev/null) || return 1
  [ "$(jq 'length' <<<"$samples")" -ge 1 ] || { printf 'no samples\n' >&2; return 2; }
  last=$(jq -c '.[-1]' <<<"$samples")
  pair_file=$(mktemp) || return 1
  local violations_file; violations_file=$(mktemp) || return 1
  local n i
  n=$(jq 'length' <<<"$samples")

  # Verify every capture the derivation will read against the sha256 its sample recorded.
  for i in $(seq 0 $((n - 1))); do
    local sid f want got
    sid=$(jq -r ".[$i].id" <<<"$samples")
    for f in $(jq -r ".[$i].captures | keys[]" <<<"$samples"); do
      want=$(jq -r ".[$i].captures[\"$f\"]" <<<"$samples")
      got=$(shasum -a 256 "$CAPS/$sid/$f" 2>/dev/null | cut -d' ' -f1)
      [ "$want" = "$got" ] || printf '{"sample":"%s","capture":"%s","why":"capture missing or altered"}\n' "$sid" "$f" >> "$violations_file"
    done
  done

  for p in $(jq -r '.pools[].id' "$LANES"); do
    clients=$(jq -r --arg p "$p" '.pools[] | select(.id == $p) | [.rules[].client] | unique | .[]' "$LANES")
    for i in $(seq 1 $((n - 1))); do
      local prev cur
      prev=$(jq -c ".[$((i - 1))]" <<<"$samples"); cur=$(jq -c ".[$i]" <<<"$samples")
      cur_id=$(jq -r .id <<<"$cur")
      # shellcheck disable=SC2086
      bundle_for "$CAPS/$cur_id" $clients | jq -c --arg p "$p" --argjson prev "$prev" --argjson cur "$cur" \
        --argjson align "$ALIGN_MIN" --argjson contam "$CONTAM_USD" --slurpfile lanes "$LANES" '
        . as $bundle
        | ($lanes[0].pools[] | select(.id == $p)) as $pool
        | $prev.pools[$p] as $a | $cur.pools[$p] as $b
        | ($prev.hour_sgt) as $lo | ($cur.hour_sgt) as $hi
        | [ $pool.rules[] as $r | ($bundle[$r.client].entries // [])[]
            | select(.hour >= $lo and .hour < $hi) | . + {rule: $r} ] as $cands
        | ($cands | map(select(. as $e | ($e.models | length) > 0 and ($e.models | all(test($e.rule.model_re)))))) as $own
        | ($cands | map(select(. as $e | ($e.models | all(test($e.rule.model_re)) | not)))) as $amb
        | ($own | map(select(.clients != [.rule.client]))) as $leak
        | ($own | map(.cost) | add // 0) as $api
        | ($amb | map(.cost) | add // 0) as $ambusd
        | (if ($a.status == "measured" and $b.status == "measured") then ($a.v - $b.v) else null end) as $pp
        | def ts: if . == null then 0 else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) end;
        ((($a.resets_at | ts) - ($b.resets_at | ts)) | fabs) as $rdiff
        | (if $pp == null then "quota not measured"
           elif $rdiff > 300 then "reset between samples"
           elif $pp < 0 then "quota rose (reset or credit)"
           elif ($cur.since > ($prev.hour_sgt[0:10])) then "backfill does not reach the previous read"
           elif ($prev.min_sgt > $align or $cur.min_sgt > $align) then "unaligned read"
           elif ($leak | length) > 0 then "attribution leak"
           else null end) as $skip
        | {pool: $p, prev: $prev.id, cur: $cur.id, window: [$lo, $hi],
           pp_used: $pp, api_value: $api, ambiguous_usd: $ambusd, buckets: ($own | length),
           skipped: $skip,
           contaminated: ($skip == null and $pp >= 1 and $api < $contam),
           edge_minutes: [$prev.min_sgt, $cur.min_sgt],
           leaks: ($leak | map({hour, clients}))}' >> "$pair_file"
    done
  done

  jq -n -c --slurpfile pairs "$pair_file" --slurpfile viol "$violations_file" --argjson samples "$samples" \
    --slurpfile lanes "$LANES" --argjson last "$last" --arg capdir "$CAPS" \
    --argjson bandmax "$BAND_MAX" '
    def r4: (. * 10000 | round) / 10000;
    ($last.id) as $lid
    | { schema: "fm.value.rollup.v1",
        lanes_version: $lanes[0].version,
        through_sample: $lid,
        sample_ids: ($samples | map(.id)),
        actor_counts: ($samples | group_by(.actor) | map({key: .[0].actor, value: length}) | from_entries),
        capture_violations: $viol,
        pools: ($lanes[0].pools | map(
          . as $pool
          | ($pairs | map(select(.pool == $pool.id))) as $pp
          | ($pp | map(select(.skipped == null and (.contaminated | not)))) as $good
          | ($good | map(.pp_used) | add // 0) as $pp_sum
          | ($good | map(.api_value) | add // 0) as $api_sum
          | ($good | to_entries | map(select(.key == 0 or (.value.prev != $good[.key - 1].cur))) | length) as $chains
          | (if $pp_sum > $chains and ($pp_sum - $chains) > 0 then {lo: ($api_sum / ($pp_sum + $chains)), hi: ($api_sum / ($pp_sum - $chains))} else null end) as $band
          | (if $band != null then (($band.hi - $band.lo) / ($api_sum / $pp_sum)) else null end) as $width
          | ($pool.unseen_surfaces | length > 0) as $biased
          | { key: $pool.id, value: {
              pairs: $pp,
              counted_pairs: ($good | length), chains: $chains,
              pp_used: $pp_sum, api_value_usd: ($api_sum | r4),
              dollars_per_pp: (if $pp_sum >= 1 then {
                  v: (($api_sum / $pp_sum) | r4), unit: "USD/pp", status: "derived",
                  band: (if $band then {lo: ($band.lo | r4), hi: ($band.hi | r4)} else null end),
                  counts: ($width != null and $width < $bandmax),
                  bias: (if $biased then "low: unseen surfaces move quota without local draw" else null end),
                  display: ("USD \(($api_sum / $pp_sum) | r4)/pp"
                            + (if $band then " (band \($band.lo | r4)..\($band.hi | r4))" else " (band unbounded)" end)
                            + (if $biased then " - biased low: \($pool.unseen_surfaces | join(", ")) unseen" else "" end)
                            + (if ($width != null and $width < $bandmax) then "" else " - indicative only, band too wide" end))
                } else {v: null, unit: "USD/pp", status: "missing", why: "no counted pair with 1 or more points used"} end)
            } } ) | from_entries)
      }' > "${pair_file}.out" || { rm -f "$pair_file" "$violations_file"; return 1; }

  # Capture-level cells for the last sample: cycle-to-date, payback, price check,
  # numerator cross-check and conservation. All re-derived from that sample's captures.
  local out; out=$(cat "${pair_file}.out")
  local lcap
  lcap="$CAPS/$(jq -r .id <<<"$last")"
  for p in $(jq -r '.pools[].id' "$LANES"); do
    clients=$(jq -r --arg p "$p" '.pools[] | select(.id == $p) | [.rules[].client] | unique | .[]' "$LANES")
    local cb_prov cb_text=""
    cb_prov=$(jq -r --arg p "$p" '.pools[] | select(.id == $p) | .codeburn.provider // ""' "$LANES")
    [ -z "$cb_prov" ] || cb_text=$(cat "$lcap/codeburn-$cb_prov.txt" 2>/dev/null || true)
    # shellcheck disable=SC2086
    out=$(bundle_for "$lcap" $clients | jq -c --arg p "$p" --argjson last "$last" --arg cb "$cb_text" \
      --slurpfile lanes "$LANES" --slurpfile all "$lcap/hourly-all.json" --slurpfile models "$lcap/models.json" \
      --slurpfile prices <(cat "$VL_DIR"/prices/*.json 2>/dev/null | jq -s '.') --argjson roll "$out" '
      def r4: (. * 10000 | round) / 10000;
      . as $bundle
      | ($lanes[0].pools[] | select(.id == $p)) as $pool
      | $last.hour_sgt as $hi
      | [ $pool.rules[] as $r | ($bundle[$r.client].entries // [])[] | select(.hour < $hi) | . + {rule: $r} ] as $cands
      | ($cands | map(select(. as $e | ($e.models | length) > 0 and ($e.models | all(test($e.rule.model_re)))))) as $own
      | ($cands | map(select(. as $e | ($e.models | all(test($e.rule.model_re)) | not)))) as $amb
      | ($pool.cycle_start // null) as $cs
      | ($own | map(select($cs != null and .hour[0:10] >= $cs)) | map(.cost) | add // 0) as $ctd
      | ($amb | map(select($cs != null and .hour[0:10] >= $cs)) | map(.cost) | add // 0) as $ctd_amb
      # (d) conservation over the whole capture span, all pools of this registry.
      | ($all[0].entries | map(select(.hour < $hi)) | map(.cost) | add // 0) as $total
      | ([ $lanes[0].pools[].rules[].client ] | unique) as $rc
      | ($roll.pools[$p]) as $pr
      | ($pool.codeburn // null) as $cbp
      | (($cb | capture("Cost +\\$(?<c>[0-9,.]+)") | .c | gsub(","; "") | tonumber) // null) as $cbcost
      | ([ $pool.rules[] | select(.client as $c | ($cbp.clients // []) | index($c)) as $r | ($bundle[$r.client].entries // [])[] | . ] | map(.cost) | add // 0) as $ledger_for_cb
      | ($models[0].entries | map(select(.client as $c | $pool.rules | map(.client) | index($c)))) as $mrows
      | ($prices[0] // [] | map(.models // {}) | add // {}) as $pt
      | $roll | .pools[$p] += {
          cycle_to_date: (if $cs == null then {v: null, unit: "USD", status: "missing", why: "cycle_start not registered in lanes.json"}
                          elif ($last.since > $cs) then {v: null, unit: "USD", status: "missing", why: "backfill capture starts after cycle_start"}
                          else {v: ($ctd | r4), unit: "USD", status: "derived", ambiguous_usd_excluded: ($ctd_amb | r4),
                                src: "captures/\($last.id)/hourly-*.json hours \($cs)..<\($hi)"} end),
          payback: (if $cs == null or ($last.since > $cs) then {v: null, status: "missing", why: "needs cycle-to-date"}
                    else {v: ($ctd / $pool.plan.price_usd_month | r4), unit: "x fee", status: "derived",
                          basis: "cycle-to-date realised value over monthly fee, not a run-rate",
                          fee_usd: $pool.plan.price_usd_month, tier_confirmed: $pool.plan.tier_confirmed,
                          bias: (if ($pool.unseen_surfaces | length) > 0 then "low: unseen surfaces; ambiguous hours excluded" else null end)} end),
          conservation: {
            total_usd: ($total | r4),
            registry_clients: $rc,
            this_pool_attributed_usd: ($own | map(.cost) | add // 0 | r4),
            this_pool_ambiguous_usd: ($amb | map(.cost) | add // 0 | r4),
            leaks: ($own | map(select(.clients != [.rule.client])) | length),
            ok: (($own | map(select(.clients != [.rule.client])) | length) == 0)
          },
          numerator_check: (if $cbcost == null then {status: "missing", why: "codeburn capture absent or unreadable"}
                            else {status: "derived", codeburn_usd: $cbcost, ledger_usd: ($ledger_for_cb | r4),
                                  delta_pct: (if $cbcost > 0 then ((($ledger_for_cb - $cbcost) / $cbcost * 1000 | round) / 10) else null end),
                                  flag: (if $cbcost > 0 and ((($ledger_for_cb - $cbcost) / $cbcost) | fabs) > 0.15 then "numerator disagrees with codeburn by over 15%" else null end)} end),
          price_check: ($mrows | map(. as $m | ($pt[$m.model] // null) as $px
              | if $px == null then {model: $m.model, status: "missing", why: "no first-party price in prices/*.json"}
                else (($m.input * $px.input + $m.output * $px.output + $m.cacheRead * $px.cache_read + $m.cacheWrite * $px.cache_write) / 1000000) as $fp
                  | {model: $m.model, status: "derived", first_party_usd: ($fp | r4), tokscale_usd: ($m.cost | r4),
                     delta_pct: (if $m.cost > 0 then ((($fp - $m.cost) / $m.cost * 1000 | round) / 10) else null end),
                     tolerance_pct: ($px.tolerance_pct // 2),
                     ok: (if $m.cost > 0 then ((($fp - $m.cost) / $m.cost * 100) | fabs) <= ($px.tolerance_pct // 2) else true end)} end))
        }')
  done
  rm -f "$pair_file" "${pair_file}.out" "$violations_file"
  printf '%s\n' "$out"
}

action_rollup() {
  local dry=0 body hash id existing
  [ "${1:-}" != "--dry" ] || dry=1
  need_lanes
  [ -s "$LEDGER" ] || die "no ledger yet (run sample first)"
  body=$(derive) || die "rollup could not derive"
  hash=$( { cat "$LANES"; printf '%s\n' "$body"; } | shasum -a 256 | cut -c1-16)
  id="r-$hash"
  if [ "$dry" = 1 ]; then jq -c --arg id "$id" '{id: $id} + .' <<<"$body"; return 0; fi
  existing=$(jq -r --arg id "$id" 'select(.id == $id) | .id' "$LEDGER" | head -1)
  if [ -n "$existing" ]; then printf 'unchanged: %s\n' "$id"; return 0; fi
  jq -c --arg id "$id" --arg at "$(TZ=UTC fmt_at "$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ)" '{id: $id, written_at: $at} + .' <<<"$body" >> "$LEDGER" || return 1
  printf 'rolled up: %s\n' "$id"
  jq -r '.pools | to_entries[] | "\(.key): \(.value.dollars_per_pp.display // .value.dollars_per_pp.why) | payback \(.value.payback.v // "missing")"' <<<"$body"
  jq -r '"actors: " + (.actor_counts | to_entries | map("\(.key)=\(.value)") | join(" "))' <<<"$body"
}

action_verify() {
  local stored fresh
  need_lanes
  stored=$(jq -c -s '[.[] | select(.schema == "fm.value.rollup.v1")] | .[-1] | del(.written_at)' "$LEDGER") || return 1
  [ "$stored" != "null" ] || die "no stored rollup to verify"
  fresh=$(action_rollup --dry) || return 1
  if [ "$(jq -S -c . <<<"$stored")" = "$(jq -S -c . <<<"$fresh")" ]; then
    printf 'verified: re-derivation matches the stored rollup exactly\n'
  else
    printf 'MISMATCH: stored rollup differs from its re-derivation\n' >&2
    diff <(jq -S . <<<"$stored") <(jq -S . <<<"$fresh") >&2
    return 1
  fi
}

# ---------------------------------------------------------------- dashboard (one panel)

action_dashboard() {
  local roll alert
  need_lanes
  roll=$(jq -c -s '[.[] | select(.schema == "fm.value.rollup.v1")] | .[-1]' "$LEDGER") || return 1
  [ "$roll" != "null" ] || die "no rollup to draw"
  alert=$(cat "$MARK_FAIL" 2>/dev/null || true)
  jq -n -c --argjson r "$roll" --slurpfile lanes "$LANES" --arg alert "$alert" '
    {panel: "realised value vs plan price", through_sample: $r.through_sample, alert: (if $alert == "" then null else $alert end),
     pools: ($lanes[0].pools | map(. as $p | {id: $p.id, fee_usd: $p.plan.price_usd_month,
        cycle_to_date: $r.pools[$p.id].cycle_to_date, payback: $r.pools[$p.id].payback,
        dollars_per_pp: $r.pools[$p.id].dollars_per_pp}))}' > "$VL_DIR/dashboard.json" || return 1
  jq -r '
    def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;");
    def bar($v; $fee; $y): (($fee * 2) as $max
      | "<rect x=\"150\" y=\"\($y)\" width=\"\(([$v, $max] | min) / $max * 500)\" height=\"22\" fill=\"#3b82f6\"/>"
      + "<line x1=\"\($fee / $max * 500 + 150)\" y1=\"\($y - 4)\" x2=\"\($fee / $max * 500 + 150)\" y2=\"\($y + 26)\" stroke=\"#dc2626\" stroke-width=\"2\"/>");
    "<!doctype html><meta charset=\"utf-8\"><title>Plan payback</title><body style=\"font:14px sans-serif;margin:24px\">",
    "<h2>Plan payback: realised value vs plan price</h2>",
    (if .alert then "<p style=\"color:#dc2626\"><b>Alert:</b> \(.alert | esc)</p>" else "<p>No alert.</p>" end),
    "<p>Through sample \(.through_sample). Blue = cycle-to-date API-priced value; red line = monthly fee. Hatched grey = not measured.</p>",
    "<svg width=\"720\" height=\"\(.pools | length * 40 + 10)\">",
    (.pools | to_entries[] | . as $e | ($e.key * 40 + 10) as $y
      | "<text x=\"0\" y=\"\($y + 16)\">\($e.value.id)</text>",
        (if $e.value.cycle_to_date.v == null
         then "<rect x=\"150\" y=\"\($y)\" width=\"500\" height=\"22\" fill=\"#d1d5db\"/><text x=\"156\" y=\"\($y + 16)\" font-size=\"11\">\($e.value.cycle_to_date.why | esc)</text>"
         else bar($e.value.cycle_to_date.v; $e.value.fee_usd; $y) end)),
    "</svg>",
    "<table border=\"1\" cellpadding=\"4\"><tr><th>pool</th><th>fee USD/mo</th><th>cycle-to-date USD</th><th>payback</th><th>dollars per point</th></tr>",
    (.pools[] | "<tr><td>\(.id)</td><td>\(.fee_usd)</td><td>\(.cycle_to_date.v // "missing")</td><td>\(.payback.v // "missing")</td><td>\(.dollars_per_pp.display // .dollars_per_pp.why | esc)</td></tr>"),
    "</table></body>"' "$VL_DIR/dashboard.json" > "$VL_DIR/plan-payback.html" || return 1
  printf 'wrote: %s\n' "$VL_DIR/plan-payback.html"
}

# ---------------------------------------------------------------- check / arm

action_check() {
  local ep today hhmm line="" lastday gap
  [ -f "$LANES" ] || exit 0
  ep=$(now_epoch)
  today=$(fmt_at "$ep" +%Y-%m-%d)
  hhmm=$(fmt_at "$ep" +%H%M)
  [ "$((10#$hhmm))" -ge 15 ] || exit 0
  [ "$(cat "$MARK_DAY" 2>/dev/null)" != "$today" ] || exit 0
  lastday=$(cat "$MARK_DAY" 2>/dev/null || true)
  local err rc=0
  err=$(action_sample --actor check 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    line="plan payback: sample failed - ${err:-instrument error}"
  else
    [ -z "$err" ] || line="plan payback: ${err#warn: }"
    if ! action_rollup >/dev/null 2>&1; then line="plan payback: sample written but rollup failed${line:+; $line}"; fi
    action_dashboard >/dev/null 2>&1 || true
    if [ -n "$lastday" ]; then
      gap=$(( ( $(day_epoch "$today") - $(day_epoch "$lastday") ) / 86400 ))
      [ "$gap" -le 1 ] || line="plan payback: no ledger row for ${gap} days before $today${line:+; $line}"
    fi
    printf '%s\n' "$today" > "$MARK_DAY"
  fi
  if [ -n "$line" ]; then
    # one alert per day: a retry every poll must not re-wake for the same failure.
    if [ "$(cat "$MARK_FAIL" 2>/dev/null | cut -c1-10)" != "$today" ]; then
      printf '%s %s\n' "$today" "$line" > "$MARK_FAIL"
      printf '%s\n' "$line"
    fi
  elif [ "$rc" -eq 0 ]; then
    rm -f "$MARK_FAIL"
  fi
  return 0
}

shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-value-ledger.sh - Plan payback daily poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-value-ledger.sh") check"
}

action_arm() {
  local home tmp
  need_lanes
  mkdir -p "$STATE" || return 1
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  [ ! -L "$CHECK_SHIM" ] || die "refusing a symlink at the shim path"
  tmp=$(umask 077; mktemp "$STATE/.fm-value-ledger-check.XXXXXX") || return 1
  if ! { shim_content "$home" > "$tmp" && chmod 0700 "$tmp" && mv -f -- "$tmp" "$CHECK_SHIM"; }; then
    rm -f -- "$tmp"; die "could not write $CHECK_SHIM"
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    die "could not register $CHECK_SHIM"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$MARK_DAY" "$MARK_FAIL"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  init) action_init ;;
  sample) shift; action_sample "$@" ;;
  rollup) shift; action_rollup "$@" ;;
  verify) action_verify ;;
  dashboard) action_dashboard ;;
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die "unknown action: $1" ;;
esac
