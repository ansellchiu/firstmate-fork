#!/usr/bin/env bash
# Run one key-dependent tool call with Automic Vault secrets applied to it.
# Usage: fm-av-run.sh <KEY[,KEY...]> -- <tool> [args...]
#
# The secret reaches that single process and nothing else: it is never written
# to disk, never printed, and never placed in this agent's own environment.
# Call this at the moment the tool runs, not around a long-lived session.
#
# This only avoids a per-run approval prompt when the calling agent is itself an
# eligible vault launcher with a rule for every requested secret name.
# bin/fm-av-inject-lib.sh's header owns why, and docs/configuration.md
# "Automic Vault secret injection" owns the operator setup.
#
# Exits 2 on usage error, 1 on refusal (injection off, no `av`, invalid secret
# name, approval service down), otherwise execs the tool and returns its status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-av-inject-lib.sh
. "$SCRIPT_DIR/fm-av-inject-lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: fm-av-run.sh <KEY[,KEY...]> -- <tool> [args...]

Runs <tool> once with the named Automic Vault secrets applied to that process
only. Secret names are comma- or space-separated and must name the exact keys
this call needs; there is no default set.

  fm-av-run.sh EXA_API_KEY -- exa-search "query"
  fm-av-run.sh "TAVILY_API_KEY,BRAVE_SEARCH_API_KEY" -- ./search.sh

Requires config/av-inject on for this home, and a per-secret Direct Access rule
for the calling agent's launcher in the Automic Vault app.
USAGE
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
if [ "$#" -lt 3 ]; then
  usage
  exit 2
fi
KEYS=$1
shift
if [ "$1" != "--" ]; then
  usage
  exit 2
fi
shift
if [ "$#" -eq 0 ]; then
  usage
  exit 2
fi

# fm_av_inject_exec execs the tool on success, so anything after it is a refusal.
fm_av_inject_exec "$CONFIG" "$KEYS" "$@"
echo "error: $FM_AV_INJECT_ERROR" >&2
exit 1
