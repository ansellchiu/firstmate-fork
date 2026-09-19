#!/usr/bin/env bash
# fm-findings-lib.sh's operator CLI: record, list, and triage the per-task
# incidental-findings channel.
#
# A ship worker that notices a concrete defect OUTSIDE its task's scope
# records it here instead of fixing it, expanding the task, or spending a
# status line; firstmate triages pending findings at its natural checkpoints
# (teardown output and the session-start fleet digest) by filing the
# follow-up work or dismissing with a reason, then closing the entry with
# triage. The entry format, dedup and pending rules, and the teardown-
# retention guarantee are owned by bin/fm-findings-lib.sh's header; this CLI
# adds only argument parsing and does not restate them.
#
# Usage:
#   fm-findings.sh record <task-id> --title "<short title>" \
#       --evidence "<file:line, command, or observation>" \
#       --disposition "<the follow-up you suggest>" \
#       [--context "<what work was under way>"]
#   fm-findings.sh list [<task-id>]
#       list prints every task's pending findings (bounded); with a task id,
#       only that task's. Read an entry's full evidence in its
#       <task-id>/findings.md file.
#   fm-findings.sh triage <task-id> <slug> --note "<where the work went, or why dismissed>"
#
# Every field must be a single line. record refuses malformed input without
# writing and deduplicates on (slug, evidence) per bin/fm-findings-lib.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

# shellcheck source=bin/fm-findings-lib.sh
. "$SCRIPT_DIR/fm-findings-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA="$FM_DATA_OVERRIDE"
else
  DATA="$FM_HOME/data"
fi

parse_kv() { # <flag-name> <value> [previous-value]
  if [ -n "${3:-}" ]; then
    echo "error: --$1 given more than once" >&2
    exit 1
  fi
  [ -n "$2" ] || {
    echo "error: --$1 requires a value" >&2
    exit 1
  }
  printf '%s' "$2"
}

CMD=${1:-}
[ -n "$CMD" ] || {
  usage >&2
  exit 1
}
shift || true

TITLE=
EVIDENCE=
DISPOSITION=
CONTEXT=
NOTE=
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*)
        echo "error: --$want_value requires a value" >&2
        exit 1
        ;;
    esac
    case "$want_value" in
      title) TITLE=$(parse_kv title "$a" "$TITLE") ;;
      evidence) EVIDENCE=$(parse_kv evidence "$a" "$EVIDENCE") ;;
      disposition) DISPOSITION=$(parse_kv disposition "$a" "$DISPOSITION") ;;
      context) CONTEXT=$(parse_kv context "$a" "$CONTEXT") ;;
      note) NOTE=$(parse_kv note "$a" "$NOTE") ;;
      *)
        echo "error: internal parser state for --$want_value" >&2
        exit 1
        ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --title) want_value=title ;;
    --title=*) TITLE=$(parse_kv title "${a#--title=}" "$TITLE") ;;
    --evidence) want_value=evidence ;;
    --evidence=*) EVIDENCE=$(parse_kv evidence "${a#--evidence=}" "$EVIDENCE") ;;
    --disposition) want_value=disposition ;;
    --disposition=*) DISPOSITION=$(parse_kv disposition "${a#--disposition=}" "$DISPOSITION") ;;
    --context) want_value=context ;;
    --context=*) CONTEXT=$(parse_kv context "${a#--context=}" "$CONTEXT") ;;
    --note) want_value=note ;;
    --note=*) NOTE=$(parse_kv note "${a#--note=}" "$NOTE") ;;
    --*)
      echo "error: unknown flag $a" >&2
      exit 1
      ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || {
  echo "error: --$want_value requires a value" >&2
  exit 1
}

case "$CMD" in
  record)
    [ "${#POS[@]}" -eq 1 ] || {
      echo "usage: fm-findings.sh record <task-id> --title \"...\" --evidence \"...\" --disposition \"...\" [--context \"...\"]" >&2
      exit 1
    }
    fm_findings_record "$DATA" "${POS[0]}" "$TITLE" "$EVIDENCE" "$DISPOSITION" "$CONTEXT"
    ;;
  list)
    [ "${#POS[@]}" -le 1 ] || {
      echo "usage: fm-findings.sh list [<task-id>]" >&2
      exit 1
    }
    if [ "${#POS[@]}" -eq 1 ]; then
      fm_findings_pending_lines "$DATA" "${POS[0]}" 20 || echo "no pending incidental findings for ${POS[0]}"
    else
      fm_findings_pending_lines "$DATA" all 12 || echo "no pending incidental findings"
    fi
    ;;
  triage)
    [ "${#POS[@]}" -eq 2 ] || {
      echo "usage: fm-findings.sh triage <task-id> <slug> --note \"...\"" >&2
      exit 1
    }
    [ -n "$NOTE" ] || {
      echo "error: --note is required (where the work went, or why dismissed)" >&2
      exit 1
    }
    fm_findings_triage "$DATA" "${POS[0]}" "${POS[1]}" "$NOTE"
    ;;
  *)
    echo "error: unknown command '$CMD' (expected record, list, or triage)" >&2
    usage >&2
    exit 1
    ;;
esac
