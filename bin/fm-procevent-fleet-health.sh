#!/usr/bin/env bash
# Fleet infrastructure health process-event adapter.
#
# Usage:
#   fm-procevent-fleet-health.sh arm [--repo <owner/name>]... [--host <ssh-host>]
#                                    [--interval <secs>] [--confirm <n>]
#   fm-procevent-fleet-health.sh poll [same flags] [--timeout <secs>]
#   fm-procevent-fleet-health.sh classify <result-file>
#   fm-procevent-fleet-health.sh terminal <result-file>
#   fm-procevent-fleet-health.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-fleet-health.sh source-id
#   fm-procevent-fleet-health.sh state
#   fm-procevent-fleet-health.sh retire
#
# arm        Register the recurring fleet-health watch through
#            `bin/fm-procevent.sh register`. At least one --repo is required;
#            --host is optional and enables the box checks. Arming refuses a
#            repo whose runner API does not answer, so a typo or a missing gh
#            credential cannot arm a watch that reports a permanent outage.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. It evaluates the watched
#            conditions every --interval seconds and stays silent until the
#            overall health differs from the durable marker this home recorded
#            for the last announced state, so one outage produces one wake and
#            its recovery produces one more however long the outage lasts.
# classify   Print the captured outcome class: problem, recovered, or unknown.
# terminal   Never terminal: a fleet-health capture is one transition, and the
#            source stays armed so reconcile re-arms the poll for the next one.
# autohandle Record the announced health in the durable marker and deliberately
#            leave the capture UNACKNOWLEDGED, so it always returns non-zero.
#            The runner publishes the `check` wake BEFORE this runs, and only
#            the handler's own `fm-procevent.sh handled` closes a capture, so a
#            wake that is published but never acted on stays eligible for
#            re-announcement on every reconcile instead of being silenced by
#            the marker. The marker only ever advances to a state that was
#            already announced, which is what keeps a standing outage quiet
#            once its transition has actually been handled.
# source-id  Print the canonical source id.
# state      Print the durable marker's recorded health, or `unknown` when this
#            home has announced nothing yet.
# retire     Retire the registration.
#
# Watched conditions, each a problem when it holds:
#   runner:<repo>     a GitHub Actions runner registration that is not online,
#                     or a repo with no registration at all
#   runner-api:<repo> that repo's runner API did not answer
#   box-unreachable   --host did not answer over the tailnet, which is what
#                     tells a dead box apart from a dead runner
#   box-oom           the host kernel log recorded an OOM kill in the window
#
# An OOM read that fails on a reachable box is unknown, not a problem: the box
# answering is the stronger signal and a missing journal must not page anyone.
# --confirm (default 2) is how many consecutive evaluations must agree before a
# change is announced, so one API blip or one dropped SSH connection does not
# open and close an episode.
#
# The canonical source id is `fleet-health` and one home arms one watch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CANONICAL_SOURCE_ID=fleet-health
DEFAULT_INTERVAL=60
DEFAULT_CONFIRM=2
DEFAULT_TIMEOUT=20
OOM_WINDOW='-20 min'

REPOS=()
HOST=
INTERVAL=$DEFAULT_INTERVAL
CONFIRM=$DEFAULT_CONFIRM
TIMEOUT=$DEFAULT_TIMEOUT

PROBLEMS=
DETAILS=()
HEALTH=healthy

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

valid_repo() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

valid_host() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[A-Za-z0-9._-]+$ ]]
}

marker_path() { printf '%s\n' "$STATE/fleet-health.state"; }

# marker_state - the health this home last announced, or `unknown`.
marker_state() {
  local line=
  [ ! -f "$(marker_path)" ] || IFS= read -r line < "$(marker_path)" || true
  case "$line" in
    healthy|problem) printf '%s\n' "$line" ;;
    *) printf 'unknown\n' ;;
  esac
}

# marker_write <healthy|problem> - replace the marker atomically.
marker_write() {
  local tmp
  (umask 077; mkdir -p "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fleet-health.state.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$(marker_path)" || { rm -f -- "$tmp"; return 1; }
}

# add_problem <key> <detail>
add_problem() {
  PROBLEMS="${PROBLEMS:+$PROBLEMS,}$1"
  DETAILS+=("$2")
}

# check_runners - one bounded runner-registration read per watched repo.
check_runners() {
  local repo statuses bad st
  for repo in "${REPOS[@]}"; do
    if ! statuses=$(fm_run_timed "$TIMEOUT" gh api "repos/$repo/actions/runners" \
        --jq '.runners[].status' 2>/dev/null </dev/null); then
      add_problem "runner-api:$repo" "$repo runner: registration API did not answer"
      continue
    fi
    if [ -z "$statuses" ]; then
      add_problem "runner:$repo" "$repo runner: no registration found"
      continue
    fi
    bad=
    while IFS= read -r st; do
      [ -z "$st" ] || [ "$st" = online ] || bad="${bad:+$bad,}$st"
    done <<< "$statuses"
    if [ -n "$bad" ]; then
      add_problem "runner:$repo" "$repo runner: $bad"
    else
      DETAILS+=("$repo runner: online")
    fi
  done
}

# check_box - reachability first, then the OOM read that reachability enables.
check_box() {
  local oom
  [ -n "$HOST" ] || return 0
  if ! fm_run_timed "$TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true \
      >/dev/null 2>&1 </dev/null; then
    add_problem box-unreachable "box $HOST: unreachable over the tailnet"
    return 0
  fi
  DETAILS+=("box $HOST: reachable")
  local probe
  probe="log=\$(sudo journalctl -k --since '$OOM_WINDOW' 2>/dev/null) || exit 1
printf '%s\\n' \"\$log\" | grep -ciE 'out of memory|killed process' || true"
  if ! oom=$(fm_run_timed "$TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
      "$probe" 2>/dev/null </dev/null); then
    DETAILS+=("box $HOST: kernel log unreadable, OOM state unknown")
    return 0
  fi
  oom=${oom//[!0-9]/}
  if [ "${oom:-0}" -gt 0 ] 2>/dev/null; then
    add_problem box-oom "box $HOST: $oom OOM kill line(s) in the last 20 minutes"
  else
    DETAILS+=("box $HOST: no recent OOM kills")
  fi
}

# evaluate - fill PROBLEMS, DETAILS, and HEALTH from one pass of the checks.
# It assigns rather than prints because a command substitution would run the
# checks in a subshell and throw their findings away.
evaluate() {
  PROBLEMS=
  DETAILS=()
  check_runners
  check_box
  if [ -z "$PROBLEMS" ]; then HEALTH=healthy; else HEALTH=problem; fi
}

parse_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)     valid_repo "${2-}" || die "--repo needs an owner/name repository"; REPOS+=("$2"); shift 2 ;;
      --host)     valid_host "${2-}" || die "--host needs an ssh host name"; HOST=$2; shift 2 ;;
      --interval) positive_number "${2-}" || die "--interval needs a positive number"; INTERVAL=$2; shift 2 ;;
      --confirm)  positive_int "${2-}" || die "--confirm needs a positive integer"; CONFIRM=$2; shift 2 ;;
      --timeout)  positive_int "${2-}" || die "--timeout needs a positive integer"; TIMEOUT=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ "${#REPOS[@]}" -gt 0 ] || die "at least one --repo is required"
}

cmd_source_id() { printf '%s\n' "$CANONICAL_SOURCE_ID"; }

cmd_state() { marker_state; }

cmd_arm() {
  parse_flags "$@"
  command -v gh >/dev/null 2>&1 || die "gh is missing; the runner registration check needs it"
  fm_procevent_source_id_valid "$CANONICAL_SOURCE_ID" || die "source id is not path-safe: $CANONICAL_SOURCE_ID"
  local repo
  for repo in "${REPOS[@]}"; do
    fm_run_timed "$TIMEOUT" gh api "repos/$repo/actions/runners" --jq '.runners[].status' \
      >/dev/null 2>&1 </dev/null \
      || die "the runner API did not answer for $repo; check the repository name and gh credentials"
  done
  local argv=("$SCRIPT_DIR/fm-procevent-fleet-health.sh" poll)
  for repo in "${REPOS[@]}"; do argv+=(--repo "$repo"); done
  [ -z "$HOST" ] || argv+=(--host "$HOST")
  argv+=(--interval "$INTERVAL" --confirm "$CONFIRM" --timeout "$TIMEOUT")
  "$SCRIPT_DIR/fm-procevent.sh" register fleet-health "$CANONICAL_SOURCE_ID" -- "${argv[@]}" || exit 1
  printf 'armed: %s\n' "$CANONICAL_SOURCE_ID"
  printf 'repos: %s\n' "${REPOS[*]}"
  printf 'host: %s\n' "${HOST:-(none)}"
  printf 'interval: %ss\n' "$INTERVAL"
  printf 'confirm: %s\n' "$CONFIRM"
  printf 'recorded health: %s\n' "$(marker_state)"
}

# cmd_poll - block until the health differs from the announced marker.
# An unknown marker means nothing has been announced from this home yet, so the
# first agreeing evaluation is a transition and the captain learns the state.
cmd_poll() {
  parse_flags "$@"
  local announced candidate='' agreed=0 polls=0
  # An absent marker is a healthy baseline, so arming a healthy fleet is silent
  # and arming during an outage announces it once.
  announced=$(marker_state)
  [ "$announced" != unknown ] || announced=healthy
  while :; do
    polls=$((polls + 1))
    evaluate
    if [ "$HEALTH" = "$announced" ]; then
      candidate=
      agreed=0
    elif [ "$HEALTH" = "$candidate" ]; then
      agreed=$((agreed + 1))
    else
      candidate=$HEALTH
      agreed=1
    fi
    if [ -n "$candidate" ] && [ "$agreed" -ge "$CONFIRM" ]; then
      printf 'fleet-health: %s\n' "$CANONICAL_SOURCE_ID"
      printf 'status: %s\n' "$([ "$HEALTH" = problem ] && printf problem || printf recovered)"
      printf 'health: %s\n' "$HEALTH"
      printf 'problems: %s\n' "${PROBLEMS:-none}"
      printf 'condition_polls: %s\n' "$polls"
      printf -- '--\n'
      local line
      for line in "${DETAILS[@]}"; do printf '%s\n' "$line"; done
      exit 0
    fi
    sleep "$INTERVAL"
  done
}

result_header() {
  awk -v key="$2" '
    $0 == "--" { exit }
    index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(result_header "$file" status)
  case "$status" in
    problem|recovered) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

# Never terminal: the next transition needs this same source still armed.
cmd_terminal() { [ -f "${1-}" ] || usage; return 1; }

cmd_autohandle() {
  local sid=${1-} seq=${2-} file=${3-} health
  [ -n "$sid" ] && [ -n "$seq" ] && [ -n "$file" ] || usage
  [ "$sid" = "$CANONICAL_SOURCE_ID" ] || die "not a fleet-health source: $sid"
  [ -f "$file" ] || die "result file does not exist: $file"
  if fm_procevent_is_handled "$STATE" "$sid" "$seq" 2>/dev/null; then
    return 0
  fi
  health=$(result_header "$file" health)
  case "$health" in
    healthy|problem) ;;
    *) return 1 ;;
  esac
  marker_write "$health" || return 1
  printf 'fleet-health: recorded the announced health as %s; leaving this capture unacknowledged so the transition is still owed a handler\n' \
    "$health" >&2
  return 1
}

cmd_retire() { "$SCRIPT_DIR/fm-procevent.sh" retire "$CANONICAL_SOURCE_ID"; }

case "${1-}" in
  arm)        shift; cmd_arm "$@" ;;
  poll)       shift; cmd_poll "$@" ;;
  classify)   shift; cmd_classify "${1-}" ;;
  terminal)   shift; cmd_terminal "${1-}" ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  source-id)  shift; [ "$#" -eq 0 ] || usage; cmd_source_id ;;
  state)      shift; [ "$#" -eq 0 ] || usage; cmd_state ;;
  retire)     shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
