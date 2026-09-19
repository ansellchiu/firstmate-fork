#!/usr/bin/env bash
# shellcheck shell=bash
# fm-vault-lib.sh - Automic Vault approval service liveness probe.
#
# Sourced, never executed. Provides a cheap bounded probe for vault service health.
#
#   fm_vault_probe [<timeout-seconds>]
#       Returns 0 when the vault service is healthy (or av is not present).
#       Returns 1 when av is present but degraded (hang, timeout, or refusal).
#
#   fm_vault_diagnostic [<timeout-seconds>]
#       If degraded, prints the VAULT diagnostic line and returns 1.
#       If healthy or av is absent, stays silent and returns 0.
#
# Bounded at <= 10s hard limit (FM_VAULT_PROBE_TIMEOUT, default 10s).
# This is a pure liveness probe with no human in the loop, so it fails fast.
# It is deliberately NOT the bound for an approval-carrying call, which a person
# may have to answer; bin/fm-av-inject-lib.sh's FM_AV_APPROVAL_TIMEOUT owns that.
# Uses fm-timeout-lib.sh's portable process-group runner (timeout/gtimeout/perl/bash).

SCRIPT_DIR_VAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR_VAULT/fm-timeout-lib.sh"

fm_vault_probe() {
  local timeout=${1:-${FM_VAULT_PROBE_TIMEOUT:-10}}
  case "$timeout" in ''|*[!0-9]*|0) timeout=10 ;; esac
  [ "$timeout" -le 10 ] || timeout=10

  command -v av >/dev/null 2>&1 || return 0

  if fm_run_timed "$timeout" av list >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

fm_vault_diagnostic() {
  if ! fm_vault_probe "${1:-}"; then
    echo "VAULT: approval service degraded - key-injecting tool calls will refuse (open the menu-bar vault app)"
    return 1
  fi
  return 0
}
