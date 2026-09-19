#!/usr/bin/env bash
# fm-pi-session-metrics.sh - measure how local Pi sessions grow, in aggregate
# numbers only, and print the calibration baseline the primary-session circuit
# breakers are derived from.
#
# WHY THIS EXISTS. A long-lived Pi session re-sends its own transcript on every
# turn. That re-send is cheap while it stays cached and ruinous once the
# conversation has outgrown its window, and the only honest way to place a
# circuit breaker on it is to first measure what an ordinary session actually
# costs. This script is that measurement. It is the evidence behind every
# threshold in .pi/extensions/lib/fm-primary-growth.ts, and re-running it is how
# those thresholds are re-checked rather than re-guessed.
#
# WHAT IT READS AND WHAT IT KEEPS. It reads Pi's own session transcripts under
# ~/.pi/agent/sessions. It keeps only aggregate numbers: the providers and
# models a session used, its input/output/cache-read/cache-write/reasoning token
# totals, its turn and assistant-message counts, its age, its compaction count,
# and a count per coarse event class. Prompts, commands, tool names, tool
# arguments, tool results, compaction summaries, file paths, project names, the
# working directory, the session directory name, and credentials are read past
# and never emitted. bin/fm-pi-session-metrics.mjs owns that boundary and
# enforces it structurally against its own declared field list; this header owns
# what the numbers mean.
#
# It is a reporting tool. It renders no verdict, changes no state, writes no
# file, and never decides that a session should rotate. That decision belongs to
# .pi/extensions/lib/fm-primary-growth.ts, and the operating contract to
# docs/pi-primary-growth.md.
#
# Usage:
#   bin/fm-pi-session-metrics.sh [--summary] [--quota]
#                                [--sessions-dir DIR]
#                                [--min-assistant-messages N]
#
#   --summary                  print only the calibration baseline, omitting
#                              the per-session rows.
#   --quota                    attach a quota-axi snapshot, reduced to provider,
#                              window, reset, remaining percentage, and
#                              projected runway. The snapshot is copied through
#                              verbatim and carries no verdict; quota-axi owns
#                              those numbers and the growth policy owns what
#                              they mean. Absent or incompatible quota-axi is
#                              reported as an unavailable snapshot rather than
#                              failing the measurement, because the session
#                              baseline does not depend on it.
#   --sessions-dir DIR         read transcripts from DIR instead of
#                              ~/.pi/agent/sessions. FM_PI_SESSIONS_DIR does the
#                              same; the flag wins.
#   --min-assistant-messages N sessions with fewer than N assistant messages are
#                              excluded from the baseline percentiles (default
#                              20). They are still listed in the per-session
#                              rows. A session of a few messages cannot show
#                              growth, and counting it would drag every
#                              percentile down and produce thresholds too loose
#                              to ever fire.
#
# Output is one JSON object on stdout (schemaVersion 1). Exit status is 0 when a
# report was produced, 2 for a usage error, and 1 when node is unavailable.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CORE="$SCRIPT_DIR/fm-pi-session-metrics.mjs"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

WANT_QUOTA=0
CORE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --quota) WANT_QUOTA=1; shift ;;
    --summary) CORE_ARGS+=("$1"); shift ;;
    --sessions-dir|--min-assistant-messages)
      [ $# -ge 2 ] || { printf 'fm-pi-session-metrics: %s needs a value\n' "$1" >&2; exit 2; }
      CORE_ARGS+=("$1" "$2"); shift 2 ;;
    *) printf 'fm-pi-session-metrics: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || {
  printf 'fm-pi-session-metrics: node is required to read session transcripts\n' >&2
  exit 1
}

QUOTA_FILE=""
cleanup() { [ -n "$QUOTA_FILE" ] && rm -f "$QUOTA_FILE"; }
trap cleanup EXIT

if [ "$WANT_QUOTA" = 1 ]; then
  QUOTA_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-pi-session-metrics-quota.XXXXXX") || {
    printf 'fm-pi-session-metrics: could not create a temporary file for the quota snapshot\n' >&2
    exit 1
  }
  # A failed, missing, or slow quota-axi leaves an empty file, which the core
  # reports as an unavailable snapshot. The session baseline stands either way,
  # so a quota read is never allowed to fail the measurement.
  if command -v quota-axi >/dev/null 2>&1; then
    quota-axi --json >"$QUOTA_FILE" 2>/dev/null </dev/null || : >"$QUOTA_FILE"
  fi
  CORE_ARGS+=(--quota-json "$QUOTA_FILE")
fi

# Deliberately not exec: the EXIT trap above owns removing the quota snapshot,
# and exec would replace this shell before it could run.
if [ ${#CORE_ARGS[@]} -eq 0 ]; then
  node "$CORE"
else
  node "$CORE" "${CORE_ARGS[@]}"
fi
