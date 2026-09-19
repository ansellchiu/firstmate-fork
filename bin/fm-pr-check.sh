#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

# Structural receipt (fm-receipt.v1, bin/fm-receipt.sh owns the format): the
# registration itself writes the task's typed landing receipt - pr_url, and
# pr_head when the forge supplied it - so the outcome never depends on the
# model composing it later. Failure here is loud but not fatal: the meta and
# poll stay authoritative, and bin/fm-teardown.sh refuses to clean up a ship
# task whose receipt is missing, so the gap always surfaces; re-running this
# command with the same URL repairs it.
PR_RECEIPT_ARGS=(write-landing --task "$ID" --pr-url "$URL"
  --pr-url-source "grep '^pr=' $META")
# The head is the PR branch head BEFORE any merge, so it takes the pr_head
# anchor kind; commit_sha stays reserved for the commit that lands.
[ -z "$PR_HEAD" ] || PR_RECEIPT_ARGS+=(--head-sha "$PR_HEAD" \
  --head-sha-source "gh pr view $URL --json headRefOid -q .headRefOid")
# A record that predates project= still gets an honest project name: the forge
# repo path parsed from the canonical URL.
[ -z "$PROJECT_PATH" ] || PR_RECEIPT_ARGS+=(--project-fallback "$(basename "$PROJECT_PATH")")
if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$FM_ROOT/bin/fm-receipt.sh" "${PR_RECEIPT_ARGS[@]+"${PR_RECEIPT_ARGS[@]}"}" >/dev/null; then
  printf 'actionable: task %s is registered but its landing receipt could not be written; teardown will refuse cleanup until fm-pr-check.sh is re-run successfully\n' "$ID" >&2
fi

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if fm_pr_poll_publish_prepared; then
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi

# Read the authenticated GitHub login from gh-axi, which answers an --jq request
# in one of two shapes depending on whether the selected value parses as JSON. A
# login like ansellchiu does not, so it arrives wrapped in an api_response block
# whose body: field carries it, read here the way bin/fm-pr-merge.sh reads a pull
# request state; a login that happens to be all digits does parse, and is printed
# bare on a line of its own. Both are accepted, and everything else - an absent,
# repeated or truncated body, extra lines, or a value that is not a single GitHub
# login - is refused rather than passed on to an assignment that could only fail
# or name the wrong account.
github_authenticated_login() {
  local output
  output=$(gh-axi api user --jq .login 2>/dev/null) || return 1
  printf '%s\n' "$output" | awk '
    { lines++ }
    NR == 1 { bare = $0 }
    $1 == "body:" { body++; login = $2; fields = NF }
    $1 == "truncated:" { truncated++; flag = $2 }
    END {
      if (body == 1 && fields == 2 && truncated == 1 && flag == "false") value = login
      else if (lines == 1) value = bare
      else exit 1
      if (value !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) exit 1
      print value
    }
  '
}

# Assignment is deliberately after the durable PR poll and metadata publication:
# a GitHub API failure must remain visible without losing the ready record. Use
# the authenticated account rather than a personal name, and make the edit
# idempotent by adding the same assignee on every registration retry. An absent
# gh-axi is its own cause and is named as one: reporting it as an undetermined
# login would send every registration on such a host chasing an account that was
# never the problem.
#
# Putting a PR in the captain's review inbox belongs to registration, and this
# script is also the metadata recorder bin/fm-pr-merge.sh runs immediately before
# it merges. FM_PR_ASSIGN_CAPTAIN=0 is how that caller declines the announcement
# it has no use for: a PR on its way out of review must not be written to the
# forge again just to re-assert who was already meant to review it.
if [ "$PROVIDER" = github ] && [ "${FM_PR_ASSIGN_CAPTAIN:-1}" != 0 ]; then
  CAPTAIN_LOGIN=
  if ! command -v gh-axi >/dev/null 2>&1; then
    printf 'actionable: PR %s is registered but GitHub captain assignment requires gh-axi on PATH\n' "$URL" >&2
  elif ! CAPTAIN_LOGIN=$(github_authenticated_login) || [ -z "$CAPTAIN_LOGIN" ]; then
    printf 'actionable: PR %s is registered but GitHub captain assignment could not determine the authenticated login\n' "$URL" >&2
  elif ! gh-axi pr edit "$NUMBER" --repo "$OWNER/$REPO" --add-assignee "$CAPTAIN_LOGIN" >/dev/null 2>&1; then
    printf 'actionable: PR %s is registered but GitHub captain assignment failed for %s\n' "$URL" "$CAPTAIN_LOGIN" >&2
  fi
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
