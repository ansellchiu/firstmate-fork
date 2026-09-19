#!/usr/bin/env bash
# agy (Antigravity CLI) authentication preflight.
# Sourced by bin/fm-spawn.sh. This file is sourced by scripts and has no side
# effects on source.
#
# Why this gate exists: agy picks its credential store PER PROCESS. A session
# it detects as SSH uses a file-based token store; every other session uses the
# OS keyring (macOS Keychain). Firstmate's workers run in SSH-detected
# sessions, so a desktop/Keychain sign-in is structurally invisible to them.
# When the file store is empty, `agy ... -i` keeps its TTY and parks forever on
# an interactive OAuth prompt instead of failing, so the task reads as working
# while no work happens and only stale escalation eventually notices.
#
# `agy models` exercises that exact credential path, read-only, in about a
# second: exit 0 with a model list means the lane is usable, and exit 1 with
# "Please sign in to view available models" means it is down. Gating the spawn
# on it turns a silent park into an immediate, explainable refusal.
#
# Environment parity is the whole point of the probe, not a detail. A probe run
# in a NON-SSH context consults the keyring and can pass while every worker
# still fails - that asymmetry is the original bug. So the probe always runs
# with SSH markers present: inherited unchanged when this process already has
# them, and otherwise synthesized for the probe alone. Synthesizing them only
# ever selects the file store, which is the strictly less privileged of the two
# and the one workers get, so the probe can refuse a lane a desktop session
# could use but can never pass a lane a worker cannot.
#
# Verified 2026-08-30 against Antigravity CLI 1.1.22 on an unauthenticated
# SSH session: `agy models` returned exit 1 in ~1s with
# "Error: Please sign in to view available models." The authenticated verdict
# (exit 0 plus a model list) is the documented contract for the same command.
#
# The wall-clock bound is resolved per machine rather than assumed. GNU
# coreutils' timeout(1) is absent from a stock macOS, so requiring it turned
# the gate into a blanket refusal of every agy spawn on a healthy Mac lane.
# fm_agy_resolve_bound below prefers timeout, then Homebrew's gtimeout, then
# perl's alarm - perl ships with macOS - and every branch reports an expired
# bound as exit 124, exactly as timeout(1) does.

# Seconds the probe may run before it counts as a refusal.
: "${FM_AGY_PREFLIGHT_TIMEOUT:=10}"

# Where the captain's sign-in procedure lives, quoted in every refusal so the
# reason line is actionable on its own.
FM_AGY_SIGNIN_POINTER='data/agy-auth-state-s1/report.md section 3 (run agy with no arguments in an SSH shell and paste the browser code)'

# The perl fallback, kept as a named constant so the quoting stays readable.
# It forks rather than execing directly because a pending alarm survives exec
# while its handler does not, which would surface an expired bound as a
# SIGALRM death (142) instead of timeout(1)'s 124.
# shellcheck disable=SC2016  # perl source, not shell; $-vars are perl's.
FM_AGY_PERL_BOUND='
  my $limit = shift;
  my $pid = fork();
  defined $pid or exit 125;
  if ($pid == 0) { exec { $ARGV[0] } @ARGV; exit 127 }
  $SIG{ALRM} = sub { kill "KILL", $pid; exit 124 };
  alarm $limit;
  waitpid($pid, 0);
  alarm 0;
  my $st = $?;
  exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
'

# Command prefix that bounds the probe, resolved by fm_agy_resolve_bound.
FM_AGY_BOUND_CMD=()

# Resolve the wall-clock bound this machine can actually enforce into
# FM_AGY_BOUND_CMD. Returns non-zero only when no bound exists at all, which
# is the one case that has to refuse: an unbounded probe can park exactly the
# way the parked worker this gate exists to prevent does.
fm_agy_resolve_bound() {  # <seconds>
  FM_AGY_BOUND_CMD=()
  if command -v timeout >/dev/null 2>&1; then
    FM_AGY_BOUND_CMD=(timeout "$1")
  elif command -v gtimeout >/dev/null 2>&1; then
    FM_AGY_BOUND_CMD=(gtimeout "$1")
  elif command -v perl >/dev/null 2>&1; then
    FM_AGY_BOUND_CMD=(perl -e "$FM_AGY_PERL_BOUND" "$1")
  else
    return 1
  fi
}

# Emit the one-line refusal reason. Deliberately the ONLY thing this gate ever
# prints: the probe's own stdout/stderr can carry a model catalog or auth
# noise, and neither belongs in a supervisor-facing log.
fm_agy_preflight_refusal() {  # <detail>
  echo "error: refusing agy launch - the Gemini lane is down ($1). Sign in with $FM_AGY_SIGNIN_POINTER, then retry." >&2
}

# True when the agy lane at <path> can actually serve a worker.
#
# Fails closed on every uncertain outcome - a missing or non-executable
# binary, no way to bound the probe at all, a probe that runs long, or any non-zero
# exit - because each of those leaves the worker's credential path unproven,
# which is exactly the state that produces a parked pane.
fm_agy_preflight() {  # <agy-path>
  local path=$1 status=0
  if [ -z "$path" ] || [ ! -x "$path" ]; then
    fm_agy_preflight_refusal "no usable agy executable at '${path:-none}'"
    return 1
  fi
  if ! fm_agy_resolve_bound "$FM_AGY_PREFLIGHT_TIMEOUT"; then
    fm_agy_preflight_refusal "no timeout, gtimeout, or perl available to bound the sign-in check"
    return 1
  fi

  # SSH markers are only synthesized when this process has none; a real SSH
  # session keeps its own values so the probe reads the identical environment
  # the worker will inherit.
  local -a env_prefix
  env_prefix=()
  if [ -z "${SSH_CONNECTION:-}" ] && [ -z "${SSH_CLIENT:-}" ] && [ -z "${SSH_TTY:-}" ]; then
    env_prefix=(env "SSH_CONNECTION=127.0.0.1 0 127.0.0.1 22" "SSH_CLIENT=127.0.0.1 0 22")
  fi

  ${env_prefix[@]+"${env_prefix[@]}"} "${FM_AGY_BOUND_CMD[@]}" "$path" models >/dev/null 2>&1 || status=$?
  case "$status" in
    0) return 0 ;;
    124|137)
      fm_agy_preflight_refusal "the sign-in check did not finish within ${FM_AGY_PREFLIGHT_TIMEOUT}s"
      ;;
    125|126|127)
      fm_agy_preflight_refusal "the sign-in check could not run agy at '$path' (exit $status)"
      ;;
    *)
      fm_agy_preflight_refusal "'agy models' exited $status, which means this lane is not signed in"
      ;;
  esac
  return 1
}
