#!/usr/bin/env bash
# fm-attention.sh - read the captain's portfolio attention classification, and
# gate intake on the portfolio attention limit.
#
# bin/fm-attention-lib.sh is the single owner of what the classes, reasons, and
# limit mean. This is the operator and intake surface over it; the records it
# classifies come from bin/fm-fleet-snapshot.sh --portfolio.
#
# Usage:
#   fm-attention.sh status [--json] [--snapshot <file|->]
#   fm-attention.sh check <project> [--override] [--snapshot <file|->]
#
# status  prints one line per project: "<class> <name> [reason,...]", then the
#         counted set against the limit. --json prints the portfolio object.
#
# check   answers whether newly attention-consuming work may start on <project>.
#         The CALLER decides whether the work it is about to start creates a
#         captain lane at all: autonomous execution that creates no new captain
#         decision lane must not be checked. <project> may be a name or a path;
#         only its basename is matched.
#         Exit 0 allowed, 3 refused (with the reason on stderr), 2 usage, and 1
#         when the classification could not be computed at all - a refusal is a
#         decision, so a caller that fails open must not read a failure as one.
#         --override carries a current explicit captain instruction past a
#         refusal and says so. There is no config key for it. An admission that
#         actually needed the override is printed as
#         "override applied: <reason>", so a caller announces an override only
#         where one was used; it never unparks a parked project.
#
# --snapshot reuses an already-collected --portfolio or --json document ("-"
# reads stdin), so a caller that already holds one pays for it once.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-attention-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-attention-lib.sh"

# Print the whole usage block: every header line from "# Usage:" up to the first
# line that is not a comment. Keyed on the end of the comment block rather than
# on a paragraph's first line, so a later header edit cannot truncate --help
# mid-sentence.
usage() { sed -n '/^# Usage:/,/^[^#]/p' "${BASH_SOURCE[0]}" | sed -n 's/^# \{0,1\}//p'; }

command -v jq >/dev/null 2>&1 || { echo "fm-attention: jq not found" >&2; exit 1; }

CMD=${1:-}
[ $# -gt 0 ] && shift || true
JSON=0
OVERRIDE=0
SNAPSHOT_SRC=
PROJECT=

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --override) OVERRIDE=1 ;;
    --snapshot) shift; [ $# -gt 0 ] || { echo "error: --snapshot needs a path or -" >&2; exit 2; }; SNAPSHOT_SRC=$1 ;;
    --snapshot=*) SNAPSHOT_SRC=${1#--snapshot=} ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) [ -z "$PROJECT" ] || { echo "error: unexpected argument $1" >&2; exit 2; }; PROJECT=$1 ;;
  esac
  shift
done

load_portfolio() {
  local raw
  if [ -n "$SNAPSHOT_SRC" ]; then
    if [ "$SNAPSHOT_SRC" = - ]; then
      raw=$(cat)
    else
      [ -f "$SNAPSHOT_SRC" ] || { echo "error: no snapshot at $SNAPSHOT_SRC" >&2; exit 1; }
      raw=$(cat "$SNAPSHOT_SRC")
    fi
  else
    raw=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --portfolio) || exit 1
  fi
  local portfolio
  portfolio=$(printf '%s' "$raw" | jq -e '.portfolio // empty' 2>/dev/null) \
    || { echo "error: that document carries no portfolio block" >&2; exit 1; }
  fm_attention_portfolio_valid "$portfolio" \
    || { echo "error: that document's portfolio block is not a classification this reads" >&2; exit 1; }
  printf '%s' "$portfolio"
}

case "$CMD" in
  status)
    [ -z "$PROJECT" ] || { echo "error: status takes no project argument" >&2; exit 2; }
    PORTFOLIO=$(load_portfolio)
    if [ "$JSON" -eq 1 ]; then
      printf '%s\n' "$PORTFOLIO"
      exit 0
    fi
    printf '%s' "$PORTFOLIO" | jq -r '
      ([.projects[].class | length] | max // 6) as $w
      | ([.projects[].name | length] | max // 8) as $n
      | (.projects[]
       | "\(.class + (" " * ($w - (.class | length))))  \(.name + (" " * ($n - (.name | length))))  \(if (.reasons | length) > 0 then (.reasons | join(",")) else "-" end)"),
      "",
      "focus: \(.focus // "none")",
      (if .enforced == false then
         "attention: \(.counted) carried; the limit is disabled in config/attention-limit\(if (.counted_projects | length) > 0 then " (\(.counted_projects | join(", ")))" else "" end)"
       else
         "attention: \(.counted)/\(.limit)\(if (.counted_projects | length) > 0 then " (\(.counted_projects | join(", ")))" else "" end)"
       end),
      (if (.focus_conflict | length) > 0 then
         "conflict: more than one project is flagged +focus (\(.focus_conflict | join(", "))); the captain has one focus project"
       else empty end),
      (if .over_limit then
         "over limit: finish or park a project before starting another"
       elif .at_limit then
         "at limit: a new attention-consuming project needs one of these finished or parked first"
       else empty end)'
    ;;
  check)
    [ -n "$PROJECT" ] || { echo "error: check needs a project" >&2; usage >&2; exit 2; }
    PROJECT=$(basename "$PROJECT")
    PORTFOLIO=$(load_portfolio)
    if verdict=$(fm_attention_admit "$PORTFOLIO" "$PROJECT" "$OVERRIDE"); then
      printf '%s\n' "$verdict"
      exit 0
    else
      admit_rc=$?
    fi
    echo "error: $verdict" >&2
    [ "$admit_rc" -eq 3 ] || exit 1
    exit 3
    ;;
  ""|-h|--help) usage; exit 0 ;;
  *) echo "error: unknown command '$CMD'" >&2; usage >&2; exit 2 ;;
esac
