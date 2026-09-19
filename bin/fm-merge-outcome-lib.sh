#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# Both a merge performed by this home and a merge detected by its existing poll
# use this operation, so neither outcome depends on an agent remembering it.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a secondmate home reports upward on its parent channel, resolved and
#     appended through bin/fm-parent-channel-lib.sh in the same
#     "<state> [key=<slug>]: <note>" shape the charter contract defines;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a secondmate home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the merge-notification marker owned by bin/fm-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
#
# The outcome also carries the task's typed receipt (fm-receipt.v1,
# bin/fm-receipt.sh owns the format): this path upgrades the task's landing
# receipt to verified and merges the anchors the proved merge holds (the PR
# url, the merge commit when the caller read one from the forge, and the
# verified source head when only that is provable). The write is structural
# and idempotent, and it happens before the marker commits - but delivery of a
# landed merge NEVER depends on it. A receipt write that fails degrades to a
# loud actionable line exactly like the two sibling writers
# (bin/fm-pr-check.sh, bin/fm-merge-local.sh), and the outcome is still marked
# notified so the poll retires: a host where receipts are unavailable at all
# (no jq, exit 3) would otherwise re-observe the same merge forever and never
# deliver a merge that demonstrably landed. A receipt failure that is NOT that
# permanent unavailability keeps at-least-once retry first: the marker is held
# back and the report returns non-zero, so the poll re-observes the merge and
# the receipt is written on a later attempt. That retry is bounded
# (FM_MERGE_OUTCOME_RECEIPT_MAX_ATTEMPTS, counted durably per PR identity)
# because permanent non-jq failures exist too; once the bound is spent the
# outcome degrades exactly like the jq-less case. The gap is never silent - the
# actionable line names it, and bin/fm-teardown.sh still refuses to clean up a
# ship task whose receipt is missing. The repair that line prints is
# `bin/fm-receipt.sh upgrade-landing`, carrying the anchors this proved merge
# held: the marker has already committed, so this path will not run again for
# this PR, and the registration writer would mint an unverified "PR ready"
# receipt with no landed commit for a merge that demonstrably landed.
# At-least-once retry stays where it belongs: on the parent-channel append and
# the wake, which still hold the marker back when they fail.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#                         [commit-sha] [sha-source] [head-sha] [head-sha-source]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
# Optional <authority> is yolo, away-grant, attended, or external. Yolo,
# away-grant, and external are appended to the ledger line; attended remains
# untagged. The merge entrypoint supplies its authority after forge acceptance,
# while the poll supplies the persisted identity-bound value or external when
# no matching record proves that this home authorized the merge.
#
# <commit-sha> and <sha-source> are the optional merge commit the caller read
# from the forge, recorded as the receipt's commit_sha anchor when present.
# <head-sha> and <head-sha-source> are the optional source-branch head the
# merge bound itself to, recorded as the receipt's pr_head anchor: a forge
# that cannot report the merge commit still proves which content it merged,
# and that is a different answer from which commit landed.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority] [commit-sha] [sha-source] [head-sha] [head-sha-source]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local merge_sha=${7:-} merge_sha_source=${8:-}
  local head_sha=${9:-} head_sha_source=${10:-}
  local self_rc=0 destination='' line lock status=0 receipt_rc=0 repair='' attempts=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  case "$authority" in
    yolo|away-grant|external) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    line="done [key=merged-$id]: merged $id $FM_PR_URL$suffix"
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    destination=''
  fi

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$line" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "merged-$id-$FM_PR_URL" \
      "check: merge landed: $id $FM_PR_URL$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    receipt_rc=0
    fm_merge_outcome_receipt \
      "$home" "$state" "$id" "$FM_PR_URL" "$merge_sha" "$merge_sha_source" \
      "$head_sha" "$head_sha_source" || receipt_rc=$?
    if [ "$receipt_rc" -ne 0 ]; then
      repair="bin/fm-receipt.sh upgrade-landing --task $id --pr-url $FM_PR_URL"
      [ -z "$merge_sha" ] \
        || repair="$repair --commit-sha $merge_sha --sha-source '$merge_sha_source'"
      [ -z "$head_sha" ] \
        || repair="$repair --head-sha $head_sha --head-sha-source '$head_sha_source'"
    fi
    case "$receipt_rc" in
      0) fm_merge_outcome_receipt_attempts_clear "$state" "$id" || true ;;
      3)
        printf 'actionable: merge of %s is delivered but its typed receipt was not recorded: jq is not installed, so receipts are unavailable on this host; install jq and run: %s\n' \
          "$FM_PR_URL" "$repair" >&2
        ;;
      *)
        attempts=$(fm_merge_outcome_receipt_attempts "$state" "$id" \
          "$provider" "$host" "$path" "$number")
        attempts=$((attempts + 1))
        if [ "$attempts" -lt "$FM_MERGE_OUTCOME_RECEIPT_MAX_ATTEMPTS" ] \
          && fm_merge_outcome_receipt_attempts_record "$state" "$id" \
            "$provider" "$host" "$path" "$number" "$attempts"; then
          printf 'actionable: merge of %s is delivered but its typed receipt could not be written (rc=%s, attempt %s of %s); the outcome stays eligible for retry. If it keeps failing, run: %s\n' \
            "$FM_PR_URL" "$receipt_rc" "$attempts" \
            "$FM_MERGE_OUTCOME_RECEIPT_MAX_ATTEMPTS" "$repair" >&2
          status=1
        else
          printf 'actionable: merge of %s is delivered but its typed receipt could not be written (rc=%s) after %s attempts; run: %s\n' \
            "$FM_PR_URL" "$receipt_rc" "$attempts" "$repair" >&2
          fm_merge_outcome_receipt_attempts_clear "$state" "$id" || true
        fi
        ;;
    esac
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}
