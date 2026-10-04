#!/usr/bin/env bash
# fm-slot-audit.sh - read-only audit of work-copy ownership in this home and the
# local Firstmate homes registered with it.
#
# Usage: fm-slot-audit.sh
#
# Reports two kinds of ambiguity and changes nothing:
#   DOUBLE_CLAIM <worktree> <meta> <meta>...  one copy recorded by several state/*.meta
#   OUT_OF_ISOLATION <task> <pid> <agent> <cwd>  a recorded worker in this home, a
#                                                project clone, or its repository's primary checkout
#   AUDIT_ERROR <pid> <reason>                  an unreadable worker process
# Exits 0 when clean, 1 when anything is reported.
#
# Covered layouts: this home, its projects/ clones (FM_PROJECTS_OVERRIDE when set), and
# the shared Treehouse pools reached through the .fm-slot-owner claims of registered local
# homes. Not covered: a worker in a linked project's external primary checkout or in a
# clone this home does not hold, which is follow-up work.
#
# Reconciliation (firstmate drives it; this script never repairs):
#   1. For each DOUBLE_CLAIM, decide the real occupant: the task named by the
#      slot's .fm-slot-owner claim, confirmed by its live endpoint's cwd. Every
#      other record is a stale claimant. Never tear a claimant down while the
#      occupant still uses the copy; bin/fm-teardown.sh owns that refusal. Once a
#      stale claimant's work has landed or is abandoned, clean it up through
#      bin/fm-teardown.sh, which leaves a slot another task's claim holds.
#   2. For each OUT_OF_ISOLATION agent, interrupt or exit it with bin/fm-control.sh
#      for its task before any git runs in that pane; never drive it in place.
#   3. Re-run this script until it is clean. bin/fm-spawn.sh refuses new work into
#      any slot a record still holds, so no new double claim is created meanwhile.
set -u
FM_HOME=${FM_HOME:-$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
LIB_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-agent-process-lib.sh
. "$LIB_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$LIB_DIR/fm-pr-lib.sh"

claims=$(
  collect_local_firstmate_states "$STATE" || {
    printf 'AUDIT_ERROR local-homes-unreadable\n'
    exit 1
  }
  states=("${TREEHOUSE_OWNER_STATES[@]}")
  seen=$'\n'
  for ((i=0; i<${#states[@]}; i++)); do
    state=$(CDPATH='' cd -- "${states[i]}" 2>/dev/null && pwd -P) || continue
    case "$seen" in *$'\n'"$state"$'\n'*) continue ;; esac
    seen="$seen$state"$'\n'
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      wt=$(grep -m1 '^worktree=' "$meta" | cut -d= -f2-)
      [ -n "$wt" ] || continue
      wt=$(CDPATH='' cd -- "$wt" 2>/dev/null && pwd -P) || wt=$(grep -m1 '^worktree=' "$meta" | cut -d= -f2-)
      printf '%s\t%s\n' "$wt" "$meta"
      marker="$(dirname "$wt")/.fm-slot-owner"
      if [ -f "$marker" ] && [ ! -L "$marker" ]; then
        owner_home=$(grep -m1 '^home=' "$marker" | cut -d= -f2-)
        [ -z "$owner_home" ] || states+=("$owner_home/state")
      fi
    done
  done | sort -u | awk -F'\t' '
    $1 == w { ids = ids " " $2; n++; next }
    { if (n > 1) print "DOUBLE_CLAIM " w ids; w = $1; ids = " " $2; n = 1 }
    END { if (n > 1) print "DOUBLE_CLAIM " w ids }'
)

state_real=$(CDPATH='' cd -- "$STATE" 2>/dev/null && pwd -P) || state_real=$STATE
ancestors=' '
ancestor=$$
while [ "$ancestor" -gt 1 ] 2>/dev/null; do
  ancestors="$ancestors$ancestor "
  ancestor=$(ps -p "$ancestor" -o ppid= 2>/dev/null | tr -d '[:space:]')
done
root=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
primaries=("$root")
for project in "${FM_PROJECTS_OVERRIDE:-$root/projects}"/*; do
  [ -d "$project" ] || continue
  physical=$(CDPATH='' cd -- "$project" && pwd -P) || continue
  primaries+=("$physical")
done
escapes=$(
  processes=$(ps -eo pid=,comm=,args=) || {
    printf 'AUDIT_ERROR process-scan-failed\n'
    exit 1
  }
  printf '%s\n' "$processes" | while read -r pid comm args; do
    case "$ancestors" in *" $pid "*) continue ;; esac
    argv0=${args%% *}
    [ "$(fm_agent_process_classify "$comm" "$argv0" "$args" "$pid")" = agent ] || continue
    if [ -r "/proc/$pid/environ" ]; then
      environment=$(tr '\0' ' ' < "/proc/$pid/environ")
    else
      environment=$(ps -Eww -o command= -p "$pid" 2>/dev/null)
    fi
    if [ -z "$environment" ]; then
      kill -0 "$pid" 2>/dev/null && printf 'AUDIT_ERROR %s cannot-read-environment\n' "$pid"
      continue
    fi
    task=$(printf '%s\n' "$environment" | tr ' ' '\n' | sed -n 's/^FM_TASK_ID=//p' | head -1)
    fm_task_id_creation_valid "$task" || continue
    case " $environment " in
      *" FM_TASK_INBOX=$state_real/$task.inbox "*) ;;
      *) continue ;;
    esac
    meta="$STATE/$task.meta"
    [ -f "$meta" ] || continue
    kind=$(grep -m1 '^kind=' "$meta" | cut -d= -f2-)
    [ "$kind" != secondmate ] || continue
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=''
    if [ -z "$cwd" ]; then
      cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    fi
    if [ -z "$cwd" ]; then
      kill -0 "$pid" 2>/dev/null && printf 'AUDIT_ERROR %s cannot-read-cwd task=%s\n' "$pid" "$task"
      continue
    fi
    cwd=$(CDPATH='' cd -- "$cwd" 2>/dev/null && pwd -P) || {
      printf 'AUDIT_ERROR %s cannot-resolve-cwd task=%s\n' "$pid" "$task"
      continue
    }
    escaped=0
    for primary in "${primaries[@]}"; do
      case "$cwd" in "$primary"|"$primary"/*) escaped=1; break ;; esac
    done
    project=$(grep -m1 '^project=' "$meta" | cut -d= -f2-)
    if [ "$escaped" = 0 ] && [ -n "$project" ]; then
      git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null) &&
        git_dir=$(CDPATH='' cd -- "$git_dir" 2>/dev/null && pwd -P) || git_dir=
      common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
        common=$(CDPATH='' cd -- "$common" 2>/dev/null && pwd -P) || common=
      [ -z "$git_dir" ] || [ "$git_dir" != "$common" ] || escaped=1
    fi
    [ "$escaped" = 0 ] || printf 'OUT_OF_ISOLATION %s %s %s %s\n' "$task" "$pid" "${comm##*/}" "$cwd"
  done
)

[ -z "$claims" ] || printf '%s\n' "$claims"
[ -z "$escapes" ] || printf '%s\n' "$escapes"
[ -z "$claims$escapes" ]
