#!/usr/bin/env bash
# fm-burn-watch.sh - Fast steering-oriented lane burndown watch: sample quota
# windows on the watcher's check cadence, compute per-lane deltas against
# state/.burn-watch-prev, and print exactly one line when a steering threshold
# is crossed, nothing otherwise.
#
# Usage:
#   fm-burn-watch.sh check                  the watcher check; samples and alerts on threshold crossing
#   fm-burn-watch.sh arm | disarm           write and register, or remove, state/burn-watch.check.sh
#   fm-burn-watch.sh init                   write config/burn-watch.json when absent
#   fm-burn-watch.sh sample                 take a sample now and print lane readings / status
#   fm-burn-watch.sh --help
#
# Starting thresholds (configurable in config/burn-watch.json):
#   - a lane falling 10+ points between samples
#   - claude below 20%, codex below 15%, agy below 20%
#   - the Alibaba monthly bucket burning faster than 1.5%/day
#
# One alert per lane per threshold crossing, re-armed only after recovery,
# so it never spams.
# A failed instrument prints one line, once, and re-arms on recovery.
# FM_BURN_NOW (epoch seconds) overrides the clock for tests.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG_DIR/burn-watch.json"
CHECK_ID=burn-watch
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
PREV_SAMPLE="$STATE/.burn-watch-prev"
ALERTS_FILE="$STATE/.burn-watch-alerts"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"

# Default configuration when config/burn-watch.json is absent.
DEFAULT_CONFIG='{
  "version": "1",
  "drop_threshold_pp": 10,
  "lanes": {
    "claude": {
      "provider": "claude",
      "window": "seven_day",
      "floor_pct": 20
    },
    "codex": {
      "provider": "codex",
      "window": "weekly",
      "floor_pct": 15
    },
    "agy": {
      "provider": "agy",
      "window": "gemini_weekly",
      "floor_pct": 20
    },
    "alibaba": {
      "provider": "alibaba",
      "window": "monthly",
      "rate_pct_day": 1.5
    }
  }
}'

# Shared JQ program for extracting lane quota and evaluating threshold crossings.
# shellcheck disable=SC2016
LANE_EXTRACT_JQ='
def extract_lane($quota; $prov; $target_win):
  ([$quota.providers[]? | select(.provider == $prov and .state.status == "fresh")
    | .windows[]? | select(.id == $target_win and (.percentRemaining | type) == "number")] | first) as $w
  | if $w == null then null
    else {remaining: $w.percentRemaining, provider: $prov, window: $w.id, resets_at: $w.resetsAt}
    end;

def reset_epoch:
  [if type == "string" then
     capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
     | (.d + "Z" | fromdateiso8601)
       - (if (.z // "Z") == "Z" then 0
          else (if .z[0:1] == "-" then -1 else 1 end) * ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) end)
   else empty end] | first;

def same_period($a; $b):
  ($a | reset_epoch) as $x | ($b | reset_epoch) as $y
  | if $x != null and $y != null then (($x - $y) | fabs) <= 3600 else $a == $b end;

def extract_lanes($quota; $config):
  ($config.lanes // {}) | to_entries | map(
    .key as $id
    | {key: $id, value: extract_lane($quota; (.value.provider // $id); (.value.window // "all_models"))}
  ) | from_entries;
'

# shellcheck disable=SC2016
BURN_EVAL_JQ='
($prev[0] // {}) as $p
| ($alerts[0] // {active: []}) as $a
| ($config.lanes // {}) as $lanes_cfg
| ($config.drop_threshold_pp // 10) as $default_drop
| extract_lanes($quota; $config) as $cur_lanes
| ($lanes_cfg | to_entries | map(
    .key as $id
    | $cur_lanes[$id] as $curr
    | $p.anchors[$id] as $anchor
    | {key: $id, value:
        (if $curr == null then $anchor
         elif $anchor == null or $anchor.provider != $curr.provider or $anchor.window != $curr.window
           or (same_period($anchor.resets_at; $curr.resets_at) | not) or $curr.remaining > $anchor.last_remaining then
           ($curr + {timestamp: $now, last_remaining: $curr.remaining})
         else ($anchor + {last_remaining: $curr.remaining}) end)}
  ) | from_entries) as $anchors
| reduce ($lanes_cfg | to_entries[]) as $entry (
    {new_alerts: [], active: []};
    $entry.key as $id
    | $entry.value as $cfg
    | ($cur_lanes[$id]) as $curr
    | ($p.lanes[$id]) as $prev_lane
    | (if $prev_lane != null and $prev_lane.provider == $curr.provider and $prev_lane.window == $curr.window
          and same_period($prev_lane.resets_at; $curr.resets_at) then $prev_lane.remaining else null end) as $prev_rem
    | ($curr.remaining) as $curr_rem
    | ("unmeasured:" + $id) as $missing_key
    | (if $curr == null then
        .active += [$missing_key]
        | if ($a.active | index($missing_key)) == null then
            .new_alerts += ["\($id) unmeasured"]
          else . end
      else . end)
    |
    # 1. Floor check
    ($cfg.floor_pct) as $floor
    | ("floor:" + $id) as $floor_key
    | (if $floor != null and $curr_rem != null then
        if $curr_rem < $floor then
          .active += [$floor_key]
          | if ($a.active | index($floor_key)) == null then
              .new_alerts += ["\($id) below \($floor)% (\($curr_rem)% remaining)"]
            else . end
        else . end
      elif ($a.active | index($floor_key)) != null then
        .active += [$floor_key]
      else . end)
    |
    # 2. Drop check
    ($cfg.drop_threshold_pp // $default_drop) as $drop_thresh
    | ("drop:" + $id) as $drop_key
    | (if $curr_rem != null and $prev_rem != null then
        ($prev_rem - $curr_rem) as $drop
        | if $drop >= $drop_thresh then
            .active += [$drop_key]
            | if ($a.active | index($drop_key)) == null then
                .new_alerts += ["\($id) dropped \($drop) points (\($prev_rem)% -> \($curr_rem)%)"]
              else . end
          else . end
      elif ($a.active | index($drop_key)) != null then
        .active += [$drop_key]
      else . end)
    |
    # 3. Rate check
    ($cfg.rate_pct_day) as $rate_limit
    | ("rate:" + $id) as $rate_key
    | (if $rate_limit != null and $curr_rem != null then
        $anchors[$id] as $anchor
        | ($now - $anchor.timestamp) as $dt
        | if $dt >= 21600 then
            (($anchor.remaining - $curr_rem - 1) * 86400 / $dt) as $rate
            | if $rate > $rate_limit then
                .active += [$rate_key]
                | if ($a.active | index($rate_key)) == null then
                    ((($rate * 10 | round) / 10) | tostring) as $rate_disp
                    | .new_alerts += ["\($id) \($curr.window) burning faster than \($rate_limit)%/day (\($rate_disp)%/day)"]
                  else . end
              else . end
          else . end
      elif ($a.active | index($rate_key)) != null then
        .active += [$rate_key]
      else . end)
  )
| {
    new_alerts: .new_alerts,
    active: (.active | unique),
    new_sample: {timestamp: $now, lanes: $cur_lanes, anchors: $anchors}
  }
'

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-burn-watch: %s\n' "$*" >&2; exit 1; }
now_epoch() { printf '%s\n' "${FM_BURN_NOW:-$(date +%s)}"; }

read_config() {
  if [ -f "$CONFIG_FILE" ]; then
    if jq -e '.lanes' "$CONFIG_FILE" >/dev/null 2>&1; then
      cat "$CONFIG_FILE"
      return 0
    fi
  fi
  printf '%s\n' "$DEFAULT_CONFIG"
}

action_init() {
  mkdir -p "$CONFIG_DIR" || return 1
  if [ -f "$CONFIG_FILE" ]; then
    printf 'present: %s\n' "$CONFIG_FILE"
    return 0
  fi
  printf '%s\n' "$DEFAULT_CONFIG" > "$CONFIG_FILE" || die "could not write $CONFIG_FILE"
  printf 'wrote: %s\n' "$CONFIG_FILE"
}

shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-burn-watch.sh - Lane burn watch poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-burn-watch.sh") check"
}

action_arm() {
  local home tmp
  mkdir -p "$STATE" || return 1
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  [ ! -L "$CHECK_SHIM" ] || die "refusing a symlink at the shim path"
  tmp=$(umask 077; mktemp "$STATE/.fm-burn-watch-check.XXXXXX") || return 1
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
  local home
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || home="$FM_HOME"
  if [ -f "$UNREGISTER_BIN" ] && [ -f "$CHECK_SHIM" ]; then
    FM_HOME="$home" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  else
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  fi
  rm -f -- "$PREV_SAMPLE" "$ALERTS_FILE"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

action_check() {
  local quota_json rc=0 now config_json
  mkdir -p "$STATE" || return 1
  now=$(now_epoch)

  # Check instrument availability and output.
  if ! command -v quota-axi >/dev/null 2>&1; then
    rc=127
  else
    quota_json=$(quota-axi --json 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      jq -e '.providers' >/dev/null 2>&1 <<< "$quota_json" || rc=1
    fi
  fi

  local fail_key="instrument:quota-axi"
  if [ "$rc" -ne 0 ]; then
    local active_alerts="[]"
    if [ -f "$ALERTS_FILE" ]; then
      active_alerts=$(jq -c '.active // []' "$ALERTS_FILE" 2>/dev/null || echo "[]")
    fi
    if ! jq -e --arg k "$fail_key" 'index($k)' >/dev/null 2>&1 <<< "$active_alerts"; then
      local tmp_alert
      tmp_alert=$(umask 077; mktemp "$STATE/.fm-burn-alerts.XXXXXX") || return 1
      jq -n --argjson active "$active_alerts" --arg k "$fail_key" \
        '{active: ($active + [$k] | unique)}' > "$tmp_alert" && mv -f -- "$tmp_alert" "$ALERTS_FILE"
      printf 'burn watch: instrument failed - quota-axi\n'
    fi
    return 0
  fi

  config_json=$(read_config)
  local prev_arg alerts_arg
  if [ -f "$PREV_SAMPLE" ]; then
    prev_arg="$PREV_SAMPLE"
  else
    prev_arg="/dev/null"
  fi
  if [ -f "$ALERTS_FILE" ]; then
    alerts_arg="$ALERTS_FILE"
  else
    alerts_arg="/dev/null"
  fi

  local eval_out
  eval_out=$(jq -n \
    --argjson config "$config_json" \
    --argjson quota "$quota_json" \
    --slurpfile prev "$prev_arg" \
    --slurpfile alerts "$alerts_arg" \
    --argjson now "$now" \
    "$LANE_EXTRACT_JQ$BURN_EVAL_JQ" 2>/dev/null) || die "burn evaluation failed"

  local tmp_sample tmp_alerts
  tmp_sample=$(umask 077; mktemp "$STATE/.fm-burn-sample.XXXXXX") || return 1
  tmp_alerts=$(umask 077; mktemp "$STATE/.fm-burn-alerts.XXXXXX") || { rm -f -- "$tmp_sample"; return 1; }

  jq -c '.new_sample' <<< "$eval_out" > "$tmp_sample" && mv -f -- "$tmp_sample" "$PREV_SAMPLE"
  jq -c '{active: .active}' <<< "$eval_out" > "$tmp_alerts" && mv -f -- "$tmp_alerts" "$ALERTS_FILE"

  local alert_line
  alert_line=$(jq -r '.new_alerts | join("; ")' <<< "$eval_out")
  if [ -n "$alert_line" ]; then
    printf 'burn watch: %s\n' "$alert_line"
  fi
  return 0
}

action_sample() {
  local quota_json now config_json
  now=$(now_epoch)
  if ! command -v quota-axi >/dev/null 2>&1; then
    die "quota-axi is required"
  fi
  quota_json=$(quota-axi --json 2>/dev/null) || die "quota-axi --json failed"
  config_json=$(read_config)

  printf 'timestamp: %s\n' "$now"
  jq -nr --argjson config "$config_json" --argjson quota "$quota_json" "$LANE_EXTRACT_JQ"'
extract_lanes($quota; $config) | to_entries[] |
  .key as $id | .value as $res |
  "\($id): \(if $res != null then "\($res.remaining)% (\($res.window))" else "unmeasured" end)"
'
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  init) action_init ;;
  sample) action_sample ;;
  -h|--help) usage ;;
  *) die "unknown action: $1" ;;
esac
