#!/usr/bin/env bash
# fm-spend.sh - print per-task token spend by mapping tokscale workspaces to task IDs.
#
# Wraps tokscale to attribute token spend and estimated cost to Firstmate task IDs
# rather than raw worktree paths.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'EOF'
usage: fm-spend.sh [tokscale-args...]

Print per-task token spend by mapping tokscale workspaces to task IDs.
Defaults to today's spend (--today) if no arguments are passed.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v tokscale >/dev/null 2>&1 || { echo "fm-spend: tokscale not found" >&2; exit 1; }

FM_SPEND_MAPPINGS=""
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    task_id="$(basename "$meta" .meta)"
    worktree="$(grep '^worktree=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
    if [ -n "$worktree" ]; then
      # tokscale mangles paths by replacing / and . with -
      label="${worktree//[\/.]/-}"
      FM_SPEND_MAPPINGS="${FM_SPEND_MAPPINGS}${label}	${task_id}"$'\n'
    fi
  done
fi
export FM_SPEND_MAPPINGS

FM_MANGLED_HOME="${FM_HOME//[\/.]/-}"
FM_HOME_NAME="$(basename "$FM_HOME")"
export FM_MANGLED_HOME FM_HOME_NAME

tokscale_args=()
if [ "$#" -eq 0 ]; then
  tokscale_args=(--today)
else
  tokscale_args=("$@")
fi

# tokscale sizes its table to the terminal width and, when piped without a width,
# drops the token columns (Input/Output/Cache/Total) entirely, so request a wide table.
RAW_OUTPUT=$(COLUMNS="${FM_SPEND_COLUMNS:-400}" tokscale --light --group-by workspace,model "${tokscale_args[@]}") || exit $?

printf '%s\n' "$RAW_OUTPUT" | sed -E $'s/\033\\[[0-9;]*[a-zA-Z]//g' | awk -F'│' '
function format_num(n,   res, len, i) {
  res = ""
  n = sprintf("%d", n)
  len = length(n)
  for (i = 1; i <= len; i++) {
    res = res substr(n, i, 1)
    if ((len - i) % 3 == 0 && i != len) res = res ","
  }
  return res
}
function shorten_ws(ws,   s) {
  s = ws
  gsub(/^-Users-[^\-]+--treehouse-|-home-[^\-]+--treehouse-/, "~/.treehouse/", s)
  gsub(/^-Users-[^\-]+--no-mistakes-worktrees-|-home-[^\-]+--no-mistakes-worktrees-/, "~/.no-mistakes/", s)
  gsub(/^-Users-[^\-]+-|-home-[^\-]+-/, "~/", s)
  gsub(/^-private-tmp-/, "/tmp/", s)
  return s
}
BEGIN {
  mappings = ENVIRON["FM_SPEND_MAPPINGS"]
  mangled_home = ENVIRON["FM_MANGLED_HOME"]
  home_name = ENVIRON["FM_HOME_NAME"]
  split(mappings, lines, "\n")
  for (i in lines) {
    if (lines[i] != "") {
      split(lines[i], pair, "\t")
      task_map[pair[1]] = pair[2]
    }
  }
  ws_col = 0; total_col = 0; cost_col = 0
}
NF > 1 {
  for (i = 1; i <= NF; i++) {
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", $i)
  }
  if ($2 == "Workspace") {
    for (i = 1; i <= NF; i++) {
      if ($i == "Workspace") ws_col = i
      if ($i == "Total") total_col = i
      if ($i == "Cost") cost_col = i
    }
    if (total_col == 0) {
      print "fm-spend: tokscale table has no Total column; output format unsupported" > "/dev/stderr"
      bad = 1
      exit 1
    }
  } else if (ws_col > 0 && $ws_col != "" && $ws_col != "Total" && index($0, "─") == 0) {
    ws = $(ws_col)
    # tokscale 4.x labels worktree rows "repo ⑃ repo (<mangled-path>)"; key on the path.
    if (match(ws, /\([^()]*\)$/)) ws = substr(ws, RSTART + 1, RLENGTH - 2)
    t_str = $(total_col)
    gsub(/,/, "", t_str)
    c_str = $(cost_col)
    gsub(/[^0-9.]/, "", c_str)

    if (!(ws in seen)) {
      seen[ws] = 1
      order[++count] = ws
    }
    tokens[ws] += (t_str + 0)
    costs[ws] += (c_str + 0.0)
  }
}
END {
  if (bad) exit 1
  if (count == 0) {
    exit 0
  }
  for (i = 1; i <= count; i++) {
    ws = order[i]
    if (ws in task_map) {
      name = task_map[ws]
    } else if (ws == mangled_home || ws == home_name || ws == "firstmate" || ws ~ /-firstmate$/) {
      name = "(firstmate)"
    } else {
      name = shorten_ws(ws)
    }
    printf "%-38s %12s tokens   $%6.2f\n", name, format_num(tokens[ws]), costs[ws]
  }
}'
