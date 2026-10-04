#!/usr/bin/env bash
# fm-slot-audit.sh - read-only audit of work-copy ownership in this home.
#
# Usage: fm-slot-audit.sh
#
# Reports two kinds of ambiguity and changes nothing:
#   DOUBLE_CLAIM <worktree> <task> <task>...  one copy recorded by several state/*.meta
#   OUT_OF_ISOLATION <pid> <agent> <cwd>      an agent process whose cwd is the home's
#                                             repository root or one of its projects/*
# Exits 0 when clean, 1 when anything is reported.
#
# The agent list is every supported harness binary; a name missing from it would
# silently undercount, so extend AGENT_NAMES when a harness is added.
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
AGENT_NAMES=' claude cursor-agent agy antigravity gemini muse omp codex opencode pi grok kimi devin rovo '

claims=$(
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    wt=$(grep -m1 '^worktree=' "$meta" | cut -d= -f2-)
    [ -n "$wt" ] && printf '%s\t%s\n' "$wt" "$(basename "$meta" .meta)"
  done | sort | awk -F'\t' '
    $1 == w { ids = ids " " $2; n++; next }
    { if (n > 1) print "DOUBLE_CLAIM " w ids; w = $1; ids = " " $2; n = 1 }
    END { if (n > 1) print "DOUBLE_CLAIM " w ids }'
)

root=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
escapes=$(
  ps -eo pid=,comm= | while read -r pid comm; do
    name=${comm##*/}
    case "$AGENT_NAMES" in *" $name "*) ;; *) continue ;; esac
    cwd=$(lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    case "$cwd" in
      "$root"|"$root"/projects/*) echo "OUT_OF_ISOLATION $pid $name $cwd" ;;
    esac
  done
)

[ -z "$claims" ] || printf '%s\n' "$claims"
[ -z "$escapes" ] || printf '%s\n' "$escapes"
[ -z "$claims$escapes" ]
