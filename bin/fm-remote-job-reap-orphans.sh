#!/usr/bin/env bash
# Reap remote job workers whose code root no longer exists.
#
# Usage: fm-remote-job-reap-orphans.sh [--dry-run]
#   --dry-run reports what would be reaped and signals nothing.
#
# A remote job worker (bin/fm-remote-job-worker.sh) is launched from a specific
# Firstmate code root: the account's own checkout under the LaunchAgent, a
# remote secondmate's checkout, a no-mistakes gate worktree, a pooled task
# worktree, or a test fixture root. When that root is pruned while the worker is
# running, the worker is reparented to init and, on older builds, keeps polling
# and logging indefinitely. Current workers stop themselves once their root is
# gone (bin/fm-remote-job-worker.sh); this sweep is the belt-and-suspenders pass
# that clears workers already orphaned that way, including ones started before
# self-termination shipped.
#
# The reap condition is exactly fm_remote_job_root_is_live failing for the root
# named in the worker's own command line. That is deliberately the whole test:
# a worker whose root is gone can never claim, validate, or execute another job,
# and no healthy worker can present a missing root. The account's healthy
# LaunchAgent worker, a live remote secondmate's worker, and any worker whose
# checkout still exists are therefore never candidates, with no dependence on
# log paths, process age, or which home is sweeping.
#
# Only this user's processes are inspected, and this process, its own process
# group, and any ancestor are never signalled. Each candidate is stopped through
# the shared fm_remote_job_stop_worker_tree, so the whole worker tree goes at
# once (TERM first, KILL only for a survivor) and a group whose leader is not
# itself a worker is stopped as a single process instead.
#
# The same sweep also stops a watcher arm (bin/fm-watch-arm.sh) whose code root
# directory no longer exists, but only when that arm is attributable to the
# sweeping home. An arm whose FM_HOME is another existing directory is left
# alone. An arm with no readable FM_HOME is left alone. When the recorded home
# directory is already gone, the arm is reaped only if its code root lies under
# the sweeping home or under the temp directory, which is where fixture arms
# are launched. FM_HOME must be set to the sweeping home; without it the arm
# pass does nothing and the worker pass is unchanged. Each arm is signalled as
# one process, TERM first and KILL only if it is still there, never as a
# process group.
#
# Prints one line per reaped or surviving candidate and nothing when there is
# nothing to do. Exits 0 unless the process scan itself could not run, so a
# caller can sweep without risking its own outcome.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

DRY_RUN=0
REAP_SUFFIX=/bin/fm-remote-job-worker.sh
REAP_ARM_SUFFIX=/bin/fm-watch-arm.sh

reap_die() { printf 'fm-remote-job-reap-orphans: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: fm-remote-job-reap-orphans.sh [--dry-run]

Stop every remote job worker whose Firstmate code root has been pruned. A
worker whose root still exists - the account's LaunchAgent worker, a live
remote secondmate's worker - is never a candidate. When FM_HOME is set, also
stop a watcher arm whose code root is gone and which belongs to that home,
never an arm whose home is a different existing directory. --dry-run reports
the candidates and signals nothing. Read this script's header for the full rule.
TXT
}

# The code root a worker command line was launched from, echoed only when the
# command is unambiguously a worker invocation: an absolute script path ending
# in the worker suffix, optionally preceded by the interpreter ps reports as
# "/bin/bash <script>", with at most the --serve argument after it.
reap_worker_root() { # <command>
  local command=$1 path prefix leading
  case "$command" in
    *"$REAP_SUFFIX --serve") path=${command%" --serve"} ;;
    *"$REAP_SUFFIX") path=$command ;;
    *) return 1 ;;
  esac
  prefix=${path%"$REAP_SUFFIX"}
  case "$prefix" in /*) ;; *) return 1 ;; esac
  leading=${prefix%% *}
  # Drop the leading token only when it really is the interpreter binary, so a
  # code root that itself contains a space is read whole rather than split.
  if [ "$leading" != "$prefix" ] && [ -f "$leading" ] && [ -x "$leading" ]; then
    prefix=${prefix#"$leading" }
  fi
  case "$prefix" in /*) ;; *) return 1 ;; esac
  printf '%s\n' "$prefix"
}

reap_is_self_or_ancestor() { # <pid>
  local pid=$1 walk=$$ i=0
  while [ "$walk" -gt 1 ] && [ "$i" -lt 64 ]; do
    [ "$walk" != "$pid" ] || return 0
    walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
    case "$walk" in ''|*[!0-9]*) return 1 ;; esac
    i=$((i + 1))
  done
  return 1
}

reap_orphans() {
  local uid scan pid command live root own_pgid pgid
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) reap_die "cannot resolve the current uid" ;; esac
  scan=$(ps -u "$uid" -o pid=,command= 2>/dev/null) ||
    reap_die "cannot scan this account's processes for remote job workers"
  own_pgid=$(fm_remote_job_process_pgid "$$" 2>/dev/null || true)
  # ps pads the pid column to the widest pid on the host, so the fields are read
  # with default word splitting rather than by fixed offsets or a single space.
  while read -r pid command; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$command" ] || continue
    root=$(reap_worker_root "$command") || continue
    fm_remote_job_root_is_live "$root" && continue
    [ "$pid" != "$$" ] || continue
    reap_is_self_or_ancestor "$pid" && continue
    if [ -n "$own_pgid" ]; then
      pgid=$(fm_remote_job_process_pgid "$pid" 2>/dev/null || true)
      [ "$pgid" != "$own_pgid" ] || continue
    fi
    # Re-read the command from the live process so a recycled pid cannot be
    # signalled on the strength of a stale scan line.
    live=$(fm_remote_job_process_command "$pid" 2>/dev/null || true)
    read -r live <<< "$live"
    [ "$live" = "$command" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap abandoned remote job worker %s (pruned code root %s)\n' "$pid" "$root"
      continue
    fi
    if fm_remote_job_stop_worker_tree "$pid"; then
      printf 'reaped abandoned remote job worker %s (pruned code root %s)\n' "$pid" "$root"
    else
      printf 'warning: abandoned remote job worker %s survived reaping (pruned code root %s)\n' "$pid" "$root" >&2
    fi
  done <<EOF
$scan
EOF
}

case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1; [ "$#" -eq 1 ] || reap_die "unexpected arguments" ;;
  -h|--help) reap_usage; exit 0 ;;
  *) reap_die "unexpected argument: $1" ;;
esac

# Echo the code root when <command> invokes the watcher arm by absolute path.
reap_arm_root() { # <command>
  local command=$1 tok
  # Intentional split: a code root containing whitespace cannot be attributed
  # from ps output, and those arms are skipped rather than guessed.
  # shellcheck disable=SC2086
  for tok in $command; do
    case "$tok" in
      /*"$REAP_ARM_SUFFIX")
        printf '%s\n' "${tok%"$REAP_ARM_SUFFIX"}"
        return 0
        ;;
    esac
  done
  return 1
}

reap_trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

# The FM_HOME recorded in <pid>'s environment, when it can be read as one
# whitespace-free value. Anything less is not attributable.
reap_process_fm_home() { # <pid>
  local pid=$1 line value
  if [ -r "/proc/$pid/environ" ]; then
    while IFS= read -r -d '' line; do
      case "$line" in
        FM_HOME=*)
          printf '%s\n' "${line#FM_HOME=}"
          return 0
          ;;
      esac
    done < "/proc/$pid/environ"
    return 1
  fi
  value=$(ps eww -p "$pid" -o command= 2>/dev/null | tr ' ' '\n' | sed -n 's/^FM_HOME=//p' | head -n 1) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

reap_canon_dir() { # <path>
  local path=$1
  [ -d "$path" ] || return 1
  (CDPATH='' cd -P -- "$path" && pwd -P)
}

reap_path_under() { # <path> <root>
  [ -n "$2" ] || return 1
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 when this arm's missing code root belongs to the sweeping home. Another
# existing home, or an arm with no readable FM_HOME, is not a candidate.
reap_arm_in_scope() { # <pid> <code-root>
  local pid=$1 root=$2 recorded sweeper canon_recorded canon_sweeper tmp
  [ -n "$root" ] || return 1
  [ -d "$root" ] && return 1
  recorded=$(reap_process_fm_home "$pid") || return 1
  [ -n "$recorded" ] || return 1
  sweeper=${FM_HOME:-}
  [ -n "$sweeper" ] || return 1
  if [ -d "$recorded" ] || [ -L "$recorded" ]; then
    canon_recorded=$(reap_canon_dir "$recorded") || return 1
    canon_sweeper=$(reap_canon_dir "$sweeper") || return 1
    [ "$canon_recorded" = "$canon_sweeper" ]
    return
  fi
  reap_path_under "$root" "$sweeper" && return 0
  tmp=${TMPDIR:-/tmp}
  tmp=${tmp%/}
  reap_path_under "$root" "$tmp" && return 0
  if [ -d "$tmp" ]; then
    tmp=$(reap_canon_dir "$tmp") || return 1
    reap_path_under "$root" "$tmp"
    return
  fi
  return 1
}

reap_stop_pid() { # <pid>
  local pid=$1 i=0
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 10 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    i=$((i + 1))
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 10 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

reap_watch_arms() {
  local uid scan pid command root live home
  [ -n "${FM_HOME:-}" ] || return 0
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) return 0 ;; esac
  scan=$(ps -u "$uid" -ww -o pid=,command= 2>/dev/null) ||
    reap_die "cannot scan this account's processes for watcher arms"
  while read -r pid command; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    command=$(reap_trim "$command")
    [ -n "$command" ] || continue
    case "$command" in
      */bin/fm-watch-arm.sh|*/bin/fm-watch-arm.sh\ *) ;;
      *) continue ;;
    esac
    root=$(reap_arm_root "$command") || continue
    [ "$pid" != "$$" ] || continue
    reap_is_self_or_ancestor "$pid" && continue
    reap_arm_in_scope "$pid" "$root" || continue
    live=$(ps -p "$pid" -ww -o command= 2>/dev/null || true)
    live=$(reap_trim "$live")
    live=$(reap_arm_root "$live" 2>/dev/null || true)
    [ "$live" = "$root" ] || continue
    home=$(reap_process_fm_home "$pid" 2>/dev/null || true)
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap abandoned watcher arm %s (pruned code root %s, home %s)\n' "$pid" "$root" "$home"
      continue
    fi
    if reap_stop_pid "$pid"; then
      printf 'reaped abandoned watcher arm %s (pruned code root %s, home %s)\n' "$pid" "$root" "$home"
    else
      printf 'warning: abandoned watcher arm %s survived reaping (pruned code root %s, home %s)\n' "$pid" "$root" "$home" >&2
    fi
  done <<EOF
$scan
EOF
}

reap_orphans
reap_watch_arms
