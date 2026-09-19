# shellcheck shell=bash
# Automic Vault point-of-use secret-injection primitives.
# Usage: . bin/fm-av-inject-lib.sh
#
# This library owns the contract for running ONE key-dependent tool call as
# `av inject +KEY... -- <tool> [args...]`, so a secret reaches that single
# process and nothing else. bin/fm-av-run.sh is the executable front end a
# worker calls; nothing on the spawn path uses this library.
#
# Why point-of-use and not a launch wrapper. Automic Vault authorizes a
# complete operation, and a Direct Access Rule matches the LAUNCHER - the
# signed process that executes `av` - never the command `av` is about to exec
# (automicvault.com/docs/, plus direct-secret-access.md and
# signed-cli-launchers.md in the automic-vault repository).
# Wrapping a worker launch in `av inject ... -- <agent>` therefore presents the
# pane's shell as the launcher and the agent as the target, which no per-agent
# rule can ever match; every such launch fell back to human approval. Calling
# `av inject` from INSIDE a running agent puts that agent's own Developer ID
# signature in the launch chain, which is what a rule can match. It is also the
# narrower shape: one tool call, the exact keys that call needs, and no
# credential in the agent's own environment.
#
# docs/configuration.md "Automic Vault secret injection" owns what the operator
# must set up for that to hold, including which agents are eligible launchers;
# this header owns the mechanics.
#
# Secret handling: a VALUE never appears here. Only key NAMES are handled, and
# key names are not secret - they are what `av list` prints. `av inject` places
# the value directly into the target process environment, so no value reaches
# argv, a log line, a status file, or a brief.

FM_AV_INJECT_FILE="av-inject"
FM_AV_INJECT_ERROR=""
# Populated by fm_av_inject_keys; one `+NAME` argument per requested secret.
FM_AV_INJECT_KEYARGS=()

SCRIPT_DIR_AV_INJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-vault-lib.sh
. "$SCRIPT_DIR_AV_INJECT/fm-vault-lib.sh"

# Read the enablement decision. FM_AV_INJECT (env) wins over the local,
# gitignored config/<FM_AV_INJECT_FILE> file; absent/empty/off/false/no/0 all
# mean disabled (the default), on/true/yes/1 mean enabled. An unrecognized value
# is treated as disabled so a typo fails safe rather than silently injecting.
# Prints "on" or "off".
# Args: <config-dir>
fm_av_inject_mode() {  # <config-dir>
  local raw="" file="$1/$FM_AV_INJECT_FILE"
  if [ -n "${FM_AV_INJECT:-}" ]; then
    raw=$FM_AV_INJECT
  elif [ -f "$file" ]; then
    # `read` takes the first line with leading/trailing whitespace trimmed; a
    # missing final newline still yields the value, so `|| true` guards the
    # non-zero read at EOF. Builtins only, so the check works even when PATH is
    # too restricted to resolve coreutils.
    IFS= read -r raw < "$file" 2>/dev/null || true
    raw=${raw#"${raw%%[![:space:]]*}"}
    raw=${raw%"${raw##*[![:space:]]}"}
  fi
  # Case-insensitive bracket patterns avoid a lowercasing external command
  # (portable to bash 3.2, and works under a PATH too restricted for coreutils).
  case "$raw" in
    [Oo][Nn]|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1) printf 'on\n' ;;
    *) printf 'off\n' ;;
  esac
}

# Resolve the `av` executable to an absolute path so the call runs the same
# signed CLI firstmate resolved, whatever the caller's PATH.
# Prints the absolute path on success; returns non-zero when not found.
fm_av_inject_bin() {
  local candidate dir
  candidate=$(type -P -- av 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
      printf '%s/%s\n' "$dir" "$(basename "$candidate")"
      ;;
  esac
}

# Validate a comma- and/or whitespace-separated key spec and populate the
# FM_AV_INJECT_KEYARGS array with one `+NAME` argument per key. `av` validates
# key names as [A-Za-z_][A-Za-z0-9_]*; mirror that here so an invalid name is a
# loud refusal rather than a mangled command line. An empty spec is refused: a
# point-of-use call must name the exact keys it needs, and there is no default
# set to fall back to. Runs in the caller's shell so the array and
# FM_AV_INJECT_ERROR both survive.
# Args: <key-spec>
fm_av_inject_keys() {  # <key-spec>
  local spec=$1 key
  FM_AV_INJECT_ERROR=""
  FM_AV_INJECT_KEYARGS=()
  spec=${spec//,/ }
  for key in $spec; do
    case "$key" in
      [A-Za-z_]*)
        case "$key" in
          *[!A-Za-z0-9_]*)
            FM_AV_INJECT_ERROR="secret name '$key' is not valid ([A-Za-z_][A-Za-z0-9_]*)"
            return 1
            ;;
        esac
        ;;
      *)
        FM_AV_INJECT_ERROR="secret name '$key' is not valid ([A-Za-z_][A-Za-z0-9_]*)"
        return 1
        ;;
    esac
    FM_AV_INJECT_KEYARGS+=("+$key")
  done
  if [ "${#FM_AV_INJECT_KEYARGS[@]}" -eq 0 ]; then
    FM_AV_INJECT_ERROR="no secret names were requested; name the exact keys this call needs"
    return 1
  fi
}

# --- approval-service preflight ---------------------------------------------
#
# `av inject` reaches the Automic Vault approval service over the XPC Mach
# service com.automicvault.av2.approval. When the service is not answering,
# `av inject` refuses and never execs the target, so the tool call fails with
# the vault's diagnostic instead of the tool's own error.
#
# Every probe here is fm_vault_probe (bin/fm-vault-lib.sh), which is hard-bounded
# through the portable process-group timeout runner, so a HUNG service costs a
# bounded wait rather than blocking the call forever. The probe is `av list`,
# which asks the same approval service; it returns only secret NAMES, which are
# not secret, and its output is discarded, so no value is exposed.
#
# Bounding each probe is necessary but not sufficient: a poll COUNT multiplied by
# a per-probe bound is how a "bounded" wait still became minutes. A service that
# hangs every probe would cost polls x per-probe-bound, so the wait also carries a
# total wall-clock ceiling and stops at whichever limit comes first.
FM_AV_INJECT_PREFLIGHT_POLLS=${FM_AV_INJECT_PREFLIGHT_POLLS:-40}
FM_AV_INJECT_PREFLIGHT_INTERVAL=${FM_AV_INJECT_PREFLIGHT_INTERVAL:-0.25}
FM_AV_INJECT_PREFLIGHT_DEADLINE=${FM_AV_INJECT_PREFLIGHT_DEADLINE:-45}

# The approval-carrying `av inject` is the one call a person may have to answer,
# by tapping an iPhone Approval or Touch ID prompt. A liveness bound would cut
# that off mid-tap, so it gets its own, much longer one. It is still a bound: an
# approval nobody answers refuses the call rather than hanging the agent that
# made it.
FM_AV_APPROVAL_TIMEOUT=${FM_AV_APPROVAL_TIMEOUT:-30}

# Make the approval service ready before an injected tool call. Probes once,
# and on failure runs the documented `av open` a single time and re-probes on a
# bounded poll. Returns non-zero with FM_AV_INJECT_ERROR set when the service
# stays down, so the caller refuses instead of running the tool keyless.
# Args: <av-path>
fm_av_inject_preflight() {  # <av-path>
  local av=$1 i=0 started
  FM_AV_INJECT_ERROR=""
  fm_vault_probe && return 0
  # `av open` is itself bounded: a wedged app must not block the poll it precedes.
  fm_run_timed "$FM_AV_INJECT_PREFLIGHT_DEADLINE" "$av" open >/dev/null 2>&1 || true
  started=$SECONDS
  while [ "$i" -lt "$FM_AV_INJECT_PREFLIGHT_POLLS" ]; do
    [ $((SECONDS - started)) -lt "$FM_AV_INJECT_PREFLIGHT_DEADLINE" ] || break
    sleep "$FM_AV_INJECT_PREFLIGHT_INTERVAL"
    fm_vault_probe && return 0
    i=$((i + 1))
  done
  # shellcheck disable=SC2034 # Caller reads the shared error after this function returns.
  FM_AV_INJECT_ERROR="the Automic Vault approval service is not answering after ${FM_AV_INJECT_PREFLIGHT_DEADLINE}s, so this call would run without its keys; open the Automic Vault menu bar app (\`av open\`) or run the tool without vault keys"
  return 1
}

# True when a real `av inject` of the requested keys is authorized right now,
# bounded by FM_AV_APPROVAL_TIMEOUT.
#
# Why this is a separate call and not a bound on the exec below. `av inject`
# waits for approval and then EXECS the tool, so after that moment the same
# process IS the tool. A timeout wrapped around the exec could not tell "still
# waiting on a human" from "the tool is doing its job", and would kill every tool
# call that outlived the approval window. Probing first bounds only the part a
# person answers, and leaves the tool itself unbounded.
#
# The probe runs the real command shape against `true`: nothing weaker
# distinguishes an authorized launcher from one that would sit on a prompt.
# `true` prints nothing and exits immediately, so the secrets reach only that
# one-instruction process and never a log, a file, or the caller's environment.
#
# Cost of the approach: when NO Direct Access rule matches, this consumes one
# approval prompt before the real call makes its own. That is the already-broken
# configuration route A exists to fix - with a matching rule, this probe is
# silent and fast - so the trade buys a bounded failure for the common case at
# the price of one extra prompt in the case that is misconfigured anyway.
# Args: <av-path>
fm_av_inject_approved() {  # <av-path>
  local av=$1
  fm_run_timed "$FM_AV_APPROVAL_TIMEOUT" \
    "$av" inject "${FM_AV_INJECT_KEYARGS[@]}" -- true >/dev/null 2>&1 </dev/null
}

# Run ONE tool call with the named secrets applied to it, and nothing else.
# Validates enablement, the `av` CLI, and every key name, brings the approval
# service up on a bounded poll, then execs `av inject +KEY... -- <tool> [args]`
# so this process is replaced by the target and no wrapper lingers.
# Every failure is a refusal with FM_AV_INJECT_ERROR set and the tool NOT run,
# because running a key-dependent tool without its key produces a confusing
# downstream error rather than an actionable one.
# Args: <config-dir> <key-spec> <tool> [args...]
fm_av_inject_exec() {  # <config-dir> <key-spec> <tool> [args...]
  local config_dir=$1 spec=$2 av
  shift 2
  FM_AV_INJECT_ERROR=""
  if [ "$#" -eq 0 ]; then
    FM_AV_INJECT_ERROR="no tool command was given"
    return 1
  fi
  if [ "$(fm_av_inject_mode "$config_dir")" != on ]; then
    FM_AV_INJECT_ERROR="vault key injection is off for this home; add the per-secret Direct Access rules for this agent launcher in the Automic Vault app, then set config/$FM_AV_INJECT_FILE to on"
    return 1
  fi
  if ! av=$(fm_av_inject_bin); then
    # shellcheck disable=SC2034 # Caller reads the shared error after this function returns.
    FM_AV_INJECT_ERROR="the 'av' CLI (Automic Vault) was not found on PATH; install Automic Vault or set config/$FM_AV_INJECT_FILE to off"
    return 1
  fi
  fm_av_inject_keys "$spec" || return 1
  fm_av_inject_preflight "$av" || return 1
  if ! fm_av_inject_approved "$av"; then
    # shellcheck disable=SC2034 # Caller reads the shared error after this function returns.
    FM_AV_INJECT_ERROR="the Automic Vault approval for these keys was not granted within ${FM_AV_APPROVAL_TIMEOUT}s, so this call would run without them; approve the request, add a Direct Access rule for this agent launcher, or run the tool without vault keys"
    return 1
  fi
  exec "$av" inject "${FM_AV_INJECT_KEYARGS[@]}" -- "$@"
}
