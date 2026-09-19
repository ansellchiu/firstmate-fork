#!/usr/bin/env bash
# fm-discord-post.sh - post ONE attention or receipt line to the captain's
# private Discord channel, as Fred, through an incoming webhook.
#
# Usage:
#   fm-discord-post.sh <kind> <summary> [--anchor <text>]... [--dry-run]
#   fm-discord-post.sh check
#   fm-discord-post.sh kinds
#
# Kinds. This is an allowlist, and the refusal of everything else is the point.
# A chat app's low friction makes over-posting easy, so what may be posted is
# enforced here rather than left to a rule somebody has to remember:
#
#   pr-ready   work is ready for the captain's review; the anchor is the PR's
#              full https:// URL, copied, never assembled
#   blocker    a real blocker or failure, after the relevant playbook is spent
#   finding    a finished investigation's one-line finding, with its report path
#   receipt    a landing receipt: one line plus its anchors
#
# Routine progress, empty polls, heartbeats, worker status lines, task ids, and
# internal mechanics have no kind and cannot be posted. Neither can a message
# with no summary.
#
# `check` validates the configuration without posting and without printing any
# secret. `--dry-run` prints the exact message that would be posted and makes no
# network call.
#
# Anchors are never truncated. A summary is truncated to fit the budget; if the
# anchors alone will not fit, this refuses rather than posting a cut-in-half URL,
# because a half URL is worse than no message.
#
# Content boundary: this surface is NON-SENSITIVE ONLY. Discord does not
# end-to-end encrypt text and says so; treat everything posted here as read by
# Discord Inc. Credential names, client-contract material, and private strategy
# do not go in it. That is a judgement the caller makes, not something this
# script can check for you.
#
# Configuration, secret handling, and budgets: bin/fm-discord-lib.sh's header.
# Operator setup and the spike's exit: docs/discord-spike.md.
#
# Exits 2 on usage error, 1 on refusal or a failed post, 0 on a delivered post.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'fm-discord-post: %s\n' "$1" >&2; exit 1; }

KINDS="pr-ready blocker finding receipt"

kind_label() {
  case "$1" in
    pr-ready) printf 'PR ready' ;;
    blocker)  printf 'Blocked' ;;
    finding)  printf 'Finding' ;;
    receipt)  printf 'Landed' ;;
  esac
}

kind_valid() {
  local k=${1-} known
  for known in $KINDS; do
    [ "$k" = "$known" ] && return 0
  done
  return 1
}

# compose <kind> <summary> <anchor>...
# Set FM_DISCORD_MESSAGE to the exact message body, or fail with
# FM_DISCORD_ERROR when the anchors alone overflow. It assigns rather than
# printing because a command substitution would run it in a subshell, where its
# refusal reason could not survive.
FM_DISCORD_MESSAGE=
compose() {
  local kind=$1 summary=$2; shift 2
  local budget head anchors='' anchor room
  budget=$(fm_discord_budget)
  head="**$(kind_label "$kind")** "
  for anchor in "$@"; do
    anchors="$anchors"$'\n'"$anchor"
  done
  room=$(( budget - ${#head} - ${#anchors} ))
  if [ "$room" -lt 1 ]; then
    FM_DISCORD_ERROR="the anchors alone exceed Discord's $budget-character budget; shorten them rather than posting a truncated link"
    return 1
  fi
  local body
  if ! body=$(fm_discord_truncate "$summary" "$room"); then
    FM_DISCORD_ERROR="the summary has no room left inside Discord's $budget-character budget to be shortened and marked as cut; shorten the anchors or raise FM_DISCORD_MAX_CHARS rather than posting an unmarked stub"
    return 1
  fi
  FM_DISCORD_MESSAGE="$head$body$anchors"
}

cmd_check() {
  local ok=0
  if fm_discord_resolve webhook; then
    printf 'webhook: configured\n'
  else
    printf 'webhook: %s\n' "$FM_DISCORD_ERROR"
    ok=1
  fi
  printf 'budget: %s characters (Discord ceiling %s)\n' "$(fm_discord_budget)" "$FM_DISCORD_HARD_CEILING"
  printf 'kinds: %s\n' "$KINDS"
  return "$ok"
}

cmd_post() {
  local kind=${1-} summary=${2-} dry=0
  local -a anchors=()
  [ -n "$kind" ] || usage
  kind_valid "$kind" || die "not a postable kind: $kind (allowed: $KINDS). Routine progress is not posted."
  shift
  [ "$#" -ge 1 ] || usage
  summary=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --anchor) [ -n "${2-}" ] || die "--anchor needs a value"; anchors+=("$2"); shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "${summary//[[:space:]]/}" ] || die "refusing to post an empty $kind"

  local message
  compose "$kind" "$summary" ${anchors+"${anchors[@]}"} || die "$FM_DISCORD_ERROR"
  message=$FM_DISCORD_MESSAGE

  local payload
  # jq owns the JSON encoding, so nothing in the summary or an anchor can break
  # out of the string. allowed_mentions parse:[] means a message that happens to
  # contain @everyone pings nobody.
  payload=$(jq -n --arg content "$message" \
    '{content: $content, username: "Fred", allowed_mentions: {parse: []}}') \
    || die "cannot encode the message (is jq installed?)"

  if [ "$dry" -eq 1 ]; then
    printf '%s\n' "$message"
    # A preview needs no secret, but it must not read as proof the surface is
    # armed: say so when the real post would refuse.
    fm_discord_resolve webhook || printf 'dry-run only: %s\n' "$FM_DISCORD_ERROR" >&2
    return 0
  fi

  fm_discord_resolve webhook || die "$FM_DISCORD_ERROR"
  command -v curl >/dev/null 2>&1 || die "curl is not available"

  local code
  # The trap body runs after cmd_post has returned, so the path lives in a
  # script-scope variable the trap can still read when it is signalled.
  body_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-discord.XXXXXX") || die "cannot create a temporary file"
  trap 'rm -f -- "$body_file"' EXIT
  printf '%s' "$payload" > "$body_file" || die "cannot stage the message"

  # The webhook URL travels in a curl config file on stdin, never in argv, so it
  # is not visible in `ps` to anyone else on this machine.
  code=$(printf 'url = "%s"\nrequest = "POST"\nheader = "Content-Type: application/json"\ndata-binary = "@%s"\n' \
      "$FM_DISCORD_WEBHOOK" "$body_file" \
    | curl -sS -o /dev/null -w '%{http_code}' --max-time "${FM_DISCORD_TIMEOUT:-20}" -K - 2>/dev/null) \
    || die "the post to Discord failed before it got a response"

  case "$code" in
    2*) printf 'posted: %s\n' "$kind" ;;
    401|403|404) die "Discord rejected the post with HTTP $code; the webhook is wrong, revoked, or deleted" ;;
    429) die "Discord rate-limited the post (HTTP 429); it was not delivered" ;;
    *) die "Discord returned HTTP $code; the message was not delivered" ;;
  esac
}

case "${1-}" in
  ''|-h|--help|help) usage ;;
  check) shift; [ "$#" -eq 0 ] || usage; cmd_check ;;
  kinds) shift; [ "$#" -eq 0 ] || usage; printf '%s\n' "$KINDS" | tr ' ' '\n' ;;
  *) cmd_post "$@" ;;
esac
