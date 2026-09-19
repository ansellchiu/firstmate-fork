#!/usr/bin/env bash
# fm-ext-hook-lib.sh - the single owner of extension hook EXECUTION.
#
# Sourced, never executed. bin/fm-ext.sh owns the extension contract itself -
# manifests, receipts, links, and which hooks an installed extension registers.
# This library owns what happens when one of those hooks is actually run: the
# bounds it runs under, how its output becomes digest content, and how its
# failure becomes a typed diagnostic. The two are split because the digest must
# be able to run a hook without also owning install semantics.
#
#   fm_ext_hook_bounds
#       Prints "<timeout-seconds> <byte-cap>" - the bounds every session-start
#       hook runs under. fm-ext.sh reports the byte cap as an estimated context
#       cost, so both callers read the numbers from here.
#
#   fm_ext_hook_capture <home> <root> <name> <hook-path> <status>
#       Runs one session-start hook and populates three globals:
#         FM_EXT_HOOK_TITLE  subsection title
#         FM_EXT_HOOK_BODY   bounded contribution, empty when there is none
#         FM_EXT_HOOK_DIAG   an EXT_HOOK: line, empty when the hook was healthy
#       Returns 0 when the hook contributed a body, 1 otherwise. A caller that
#       gets 1 with an empty FM_EXT_HOOK_DIAG had a healthy hook that chose to
#       contribute nothing, which is an expected condition and prints nothing.
#
#   fm_ext_launchwrap_resolve <home> <root> <task-id> <task-kind> <harness> <worktree>
#       Resolves every installed launch-wrap hook's prefix for one spawn and
#       populates three globals:
#         FM_EXT_LAUNCHWRAP_PREFIX  the concatenated prefix, empty when none
#         FM_EXT_LAUNCHWRAP_ERROR   the refusal reason, empty on success
#         FM_EXT_LAUNCHWRAP_WARN    advisory preflight lines, newline separated
#       Returns 0 when the spawn may proceed (including zero wrappers), 1 when
#       it must be refused. bin/fm-ext.sh's header owns the launch-wrap hook
#       contract; this library owns only its execution. The failure philosophy
#       is the INVERSE of fm_ext_hook_capture's, and deliberately so: a failing
#       digest contributor steps aside because its blast radius is one missing
#       subsection, while a failing launch-wrap hook refuses the whole spawn
#       because launching without the configured wrapper is exactly the silent
#       failure the wrapper exists to prevent - a worker missing what the home
#       configured it to get fails later, unexplained, far from the cause.
#
# WHY A FAILING HOOK DOES NOT BLOCK SESSION START.
# Session start is firstmate's recovery infrastructure: it takes the session
# lock, drains the durable wake queue, and reconciles the fleet. An extension's
# digest contribution is a reporting surface layered on top of that. Aborting
# the digest because a contributor failed would strand every live crewmate and
# every queued wake behind a cosmetic section, which inverts severity: the
# failure's real blast radius is "one subsection is missing", not "the fleet is
# unsupervised". So a failing hook is stepped over - but never silently. It
# prints an EXT_HOOK: line, which is in AGENTS.md section 13's actionable list
# and routed by the bootstrap-diagnostics skill exactly like MISSING: or
# TANGLE:. Stepping aside and failing silently are different things, and the
# difference is the whole point of this seam.
#
# The timeout is what makes that guarantee real rather than aspirational: a
# hook that hangs is killed at the bound, by process group, so a wedged
# contributor cannot wedge the session it is contributing to.
#
# Repeated identical failures are deduped against a per-home marker so a
# permanently broken hook costs one line with a repeat count rather than the
# same paragraph at the top of every session.
set -u

# The bounds are overridable so tests can drive the timeout and truncation paths
# without a five-second wait or a four-kilobyte fixture. Nothing in normal
# operation sets them.
FM_EXT_HOOK_TIMEOUT_SECONDS=${FM_EXT_HOOK_TIMEOUT_SECONDS:-5}
FM_EXT_HOOK_BYTE_CAP=${FM_EXT_HOOK_BYTE_CAP:-4000}

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

fm_ext_hook_bounds() {
  printf '%s %s\n' "$FM_EXT_HOOK_TIMEOUT_SECONDS" "$FM_EXT_HOOK_BYTE_CAP"
}

# fm_ext_hook_sanitize <text>: one legible line for a diagnostic. Hook stderr is
# untrusted text landing in the agent's startup context, so every control
# character except tab is stripped and the result is bounded. Carriage return
# matters most: left in, it lets a hook overwrite the rendered line and forge a
# different typed diagnostic than the failure that actually happened.
fm_ext_hook_sanitize() {
  printf '%s' "$1" | tr -d '\000-\010\013-\037\177' | cut -c1-200
}

# fm_ext_hook_failure_marker <home> <name>
fm_ext_hook_failure_marker() {
  printf '%s/state/.ext-hook-%s.failure\n' "$1" "$2"
}

# fm_ext_hook_dedupe <home> <name> <signature>: print the repeat suffix for this
# failure, remembering it. Empty for a first or changed failure.
fm_ext_hook_dedupe() {
  local home=$1 name=$2 signature=$3 marker prev count=1
  marker=$(fm_ext_hook_failure_marker "$home" "$name")
  if [ -f "$marker" ]; then
    prev=$(sed -n '1p' "$marker" 2>/dev/null || true)
    if [ "$prev" = "$signature" ]; then
      count=$(sed -n '2p' "$marker" 2>/dev/null || true)
      case "$count" in ''|*[!0-9]*) count=1 ;; esac
      count=$((count + 1))
    fi
  fi
  if [ -d "$home/state" ]; then
    printf '%s\n%s\n' "$signature" "$count" > "$marker" 2>/dev/null || true
  fi
  [ "$count" -le 1 ] || printf ' (repeated %sx)' "$count"
}

fm_ext_hook_clear_failure() {
  rm -f "$(fm_ext_hook_failure_marker "$1" "$2")" 2>/dev/null || true
}

fm_ext_hook_capture() {  # <home> <root> <name> <hook-path> <status>
  local home=$1 root=$2 name=$3 hook=$4 status=$5
  local out_file err_file rc=0 started=0 elapsed=0 body first_err suffix read_cap

  FM_EXT_HOOK_TITLE=$name
  FM_EXT_HOOK_BODY=
  FM_EXT_HOOK_DIAG=

  # Declared but unusable. fm-ext.sh reports the receipt's declaration and this
  # library reports that it cannot be honoured, because an extension that was
  # installed with a hook and contributes nothing at all is a broken invariant,
  # not an opt-out.
  if [ "$status" = receipt-unreadable ]; then
    suffix=$(fm_ext_hook_dedupe "$home" "$name" "unusable:$status")
    FM_EXT_HOOK_DIAG="EXT_HOOK: $name has an unreadable or schema-mismatched install record at $hook, so whether it registers a session-start hook cannot be read$suffix"
    return 1
  fi
  if [ "$status" != ok ]; then
    suffix=$(fm_ext_hook_dedupe "$home" "$name" "unusable:$status")
    FM_EXT_HOOK_DIAG="EXT_HOOK: $name session-start is registered but $status at $hook$suffix"
    return 1
  fi

  out_file=$(mktemp "${TMPDIR:-/tmp}/fm-ext-hook-out.XXXXXX") || return 1
  err_file="$out_file.err"
  : > "$err_file"
  # Read a little past the cap rather than exactly one byte past it: the
  # optional #title line is stripped AFTER the read, so reading only cap+1 would
  # let a body land under the cap purely because its title consumed the margin,
  # and an oversized contribution would then be silently un-truncated. The read
  # is still bounded, which is what keeps a runaway hook off the disk.
  read_cap=$((FM_EXT_HOOK_BYTE_CAP + 1024))

  started=$(date +%s)
  fm_run_timed "$FM_EXT_HOOK_TIMEOUT_SECONDS" \
    env \
      FM_HOME="$home" \
      FM_ROOT="$root" \
      FM_EXT_NAME="$name" \
      FM_EXT_DIR="$(dirname "$(dirname "$hook")")" \
      FM_EXT_PHASE=digest \
      "$hook" \
    2>"$err_file" </dev/null | head -c "$read_cap" > "$out_file"
  rc=${PIPESTATUS[0]}
  elapsed=$(( $(date +%s) - started ))

  first_err=$(fm_ext_hook_sanitize "$(sed -n '1p' "$err_file" 2>/dev/null || true)")

  if [ "$rc" -eq 124 ]; then
    rm -f "$out_file" "$err_file"
    suffix=$(fm_ext_hook_dedupe "$home" "$name" "timeout")
    FM_EXT_HOOK_DIAG="EXT_HOOK: $name session-start timed out after ${FM_EXT_HOOK_TIMEOUT_SECONDS}s and was killed$suffix"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$out_file" "$err_file"
    suffix=$(fm_ext_hook_dedupe "$home" "$name" "exit:$rc:$first_err")
    # shellcheck disable=SC2034 # Result variable read by bin/fm-session-start.sh after this call.
    FM_EXT_HOOK_DIAG="EXT_HOOK: $name session-start failed (exit $rc, ${elapsed}s)${first_err:+ - $first_err}$suffix"
    return 1
  fi

  fm_ext_hook_clear_failure "$home" "$name"
  body=$(cat "$out_file" 2>/dev/null || true)
  rm -f "$out_file" "$err_file"

  # An optional first line names the subsection; otherwise it is the extension.
  case "$body" in
    '#title: '*)
      FM_EXT_HOOK_TITLE=$(fm_ext_hook_sanitize "$(printf '%s\n' "$body" | sed -n '1s/^#title: //p')")
      body=$(printf '%s\n' "$body" | sed '1d')
      [ -n "$FM_EXT_HOOK_TITLE" ] || FM_EXT_HOOK_TITLE=$name
      ;;
  esac

  # Empty stdout is a deliberate contribution of nothing - an inert extension
  # costs no section and no diagnostic. This is the expected condition, and it
  # is why an uninstalled extension and an idle one look the same in the digest.
  [ -n "${body//[[:space:]]/}" ] || return 1

  if [ "${#body}" -gt "$FM_EXT_HOOK_BYTE_CAP" ]; then
    body="${body:0:$FM_EXT_HOOK_BYTE_CAP}"
    body="$body
[truncated at ${FM_EXT_HOOK_BYTE_CAP} bytes - the session-start contribution cap]"
  fi

  # shellcheck disable=SC2034 # Result variable read by bin/fm-session-start.sh after this call.
  FM_EXT_HOOK_BODY=$body
  return 0
}

# --- launch-wrap resolution -------------------------------------------------

# fm_ext_launchwrap_prefix_ok <text> <name>: validate one hook's captured prefix
# against the argument-boundary rules, or set FM_EXT_LAUNCHWRAP_ERROR and
# return 1. The two structural rules are the argument-boundary guard: the
# prefix is spliced verbatim immediately before the agent binary's template
# slot, so multi-line text would turn one launch line into several commands,
# and a nonempty prefix that does not end in a space would fuse with the
# binary's first argument (`wrap --` + `claude` would launch `--claude`). The
# hook owns shell quoting; core owns only these two shape rules, which quoting
# cannot substitute for.
fm_ext_launchwrap_prefix_ok() {  # <text> <name>
  local text=$1 name=$2 size
  size=$(printf '%s' "$text" | wc -c | tr -d '[:space:]')
  if [ "$size" -gt "$FM_EXT_HOOK_BYTE_CAP" ]; then
    FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: extension '$name' produced a $size-byte prefix; the cap is $FM_EXT_HOOK_BYTE_CAP bytes, because a wrapper prefix is one short shell fragment spliced into the launch line"
    return 1
  fi
  case "$text" in
    *$'\n'*|*$'\r'*)
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: extension '$name' produced multi-line prefix output; a wrapper prefix must be a single line of shell text"
      return 1
      ;;
  esac
  case "$text" in
    ''|*[[:space:]]) ;;
    *)
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: extension '$name' produced a prefix that does not end in a space; the prefix is spliced directly in front of the agent binary, so a missing trailing space would fuse the wrapper with the binary's first argument"
      return 1
      ;;
  esac
  return 0
}

# fm_ext_launchwrap_resolve <home> <root> <task-id> <task-kind> <harness> <worktree>
# See the header for the globals and the return contract. Enumeration comes from
# `fm-ext.sh hooks launch-wrap` so resolution reads the same receipt truth the
# install contract wrote; the row order IS the composition order (extension
# names, lexicographic), so the first-ordered extension becomes the outermost
# wrapper. A wrapper that contributes an empty prefix is an expected condition:
# the extension is installed but opts this launch out, costing nothing.
fm_ext_launchwrap_resolve() {  # <home> <root> <task-id> <task-kind> <harness> <worktree>
  local home=$1 root=$2 task_id=$3 task_kind=$4 harness=$5 worktree=$6
  local rows name path status out_file err_file rc text first_err dir
  local enum_err enum_rc=0 enum_msg home_phys precondition=
  FM_EXT_LAUNCHWRAP_PREFIX=
  FM_EXT_LAUNCHWRAP_ERROR=
  FM_EXT_LAUNCHWRAP_WARN=
  # A precondition on the home path itself is not evidence about wrappers: it
  # is decided before any extension state is consulted, so it warns and leaves
  # the launch unwrapped rather than refusing every spawn this home performs.
  # Resolving the home physically first also removes the symlinked-home
  # precondition entirely, which is the common way this used to trip.
  home_phys=$(cd "$home" 2>/dev/null && pwd -P) || home_phys=
  if [ -z "$home_phys" ]; then
    precondition="the home path is not a readable directory"
  else
    case "$home_phys" in
      /) precondition="the home resolves to the filesystem root" ;;
      *$'\n'*|*$'\r'*|*$'\t'*) precondition="the home path contains a control separator" ;;
    esac
  fi
  if [ -n "$precondition" ]; then
    FM_EXT_LAUNCHWRAP_WARN+="launch-wrap: this home's extensions could not be enumerated because $precondition ($home); no extension state was consulted, so the spawn proceeds with no wrapper"$'\n'
    return 0
  fi
  # Enumeration failing and enumerating nothing are different answers. An empty
  # result means the home installed no wrapper; a nonzero exit means core cannot
  # tell whether it did, and launching on that assumption is exactly the silent
  # unwrapped launch this seam exists to prevent.
  enum_err=$(mktemp "${TMPDIR:-/tmp}/fm-ext-wrap-enum.XXXXXX") || enum_err=
  rows=$("$root/bin/fm-ext.sh" hooks launch-wrap --home "$home_phys" 2>"${enum_err:-/dev/null}") || enum_rc=$?
  if [ "$enum_rc" -ne 0 ]; then
    enum_msg=$(fm_ext_hook_sanitize "$(sed -n '1p' "${enum_err:-/dev/null}" 2>/dev/null || true)")
    [ -z "$enum_err" ] || rm -f "$enum_err"
    # shellcheck disable=SC2034 # Result variable read by bin/fm-spawn.sh after this call.
    FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: could not enumerate this home's extensions (bin/fm-ext.sh hooks launch-wrap --home $home_phys exited $enum_rc)${enum_msg:+: $enum_msg}; the spawn refuses rather than launch without a wrapper the home may have configured"
    return 1
  fi
  [ -z "$enum_err" ] || rm -f "$enum_err"
  [ -n "$rows" ] || return 0
  local contributors=
  while IFS=$'\t' read -r name path status; do
    [ -n "$name" ] || continue
    # An extension whose install record cannot be read may or may not register
    # a launch-wrap hook; core cannot tell, and launching on the assumption it
    # does not is the silent unwrapped launch this seam exists to prevent.
    if [ "$status" = receipt-unreadable ]; then
      # shellcheck disable=SC2034 # Result variable read by bin/fm-spawn.sh after this call.
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: extension '$name''s install record at $path is unreadable or schema-mismatched, so core cannot tell whether it registers a launch-wrap hook; remove the extension (bin/fm-ext.sh uninstall $name --home $home_phys --force), then reinstall it from its package - update cannot repair a record it cannot read"
      return 1
    fi
    # A registered hook core cannot run is a broken invariant, same as a hook
    # that runs and fails: the home was told to wrap launches and cannot.
    if [ "$status" != ok ]; then
      # shellcheck disable=SC2034 # Result variable read by bin/fm-spawn.sh after this call.
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: extension '$name' registers launch-wrap but its hook is $status at $path; repair or update the extension (bin/fm-ext.sh update $name --home $home_phys), or uninstall it (bin/fm-ext.sh uninstall $name --home $home_phys)"
      return 1
    fi
    out_file=$(mktemp "${TMPDIR:-/tmp}/fm-ext-wrap-out.XXXXXX") || {
      # shellcheck disable=SC2034 # Result variable read by bin/fm-spawn.sh after this call.
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: could not create a temporary file to capture extension '$name''s prefix"
      return 1
    }
    err_file=$(mktemp "${TMPDIR:-/tmp}/fm-ext-wrap-err.XXXXXX") || {
      rm -f "$out_file"
      # shellcheck disable=SC2034 # Result variable read by bin/fm-spawn.sh after this call.
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: could not create a temporary file to capture extension '$name''s prefix diagnostics"
      return 1
    }
    dir=$(dirname "$(dirname "$path")")
    fm_run_timed "$FM_EXT_HOOK_TIMEOUT_SECONDS" \
      env \
        FM_HOME="$home" \
        FM_ROOT="$root" \
        FM_EXT_NAME="$name" \
        FM_EXT_DIR="$dir" \
        FM_EXT_PHASE=launch \
        FM_TASK_ID="$task_id" \
        FM_TASK_KIND="$task_kind" \
        FM_HARNESS="$harness" \
        FM_WORKTREE="$worktree" \
        "$path" prefix \
      2>"$err_file" </dev/null \
      | { head -c "$((FM_EXT_HOOK_BYTE_CAP + 1024))" >"$out_file"; cat >/dev/null; }
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 124 ]; then
      rm -f "$out_file" "$err_file"
      # shellcheck disable=SC2034 # Result variable read by bin/fm-spawn.sh after this call.
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: extension '$name''s launch-wrap hook timed out after ${FM_EXT_HOOK_TIMEOUT_SECONDS}s and was killed; the spawn refuses rather than launch without the configured wrapper"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      first_err=$(fm_ext_hook_sanitize "$(sed -n '1p' "$err_file" 2>/dev/null || true)")
      rm -f "$out_file" "$err_file"
      # shellcheck disable=SC2034 # Result variable read by bin/fm-spawn.sh after this call.
      FM_EXT_LAUNCHWRAP_ERROR="launch-wrap: extension '$name''s launch-wrap hook failed (exit $rc)${first_err:+: $first_err}; the spawn refuses rather than launch without the configured wrapper"
      return 1
    fi
    # One trailing newline is the natural printf ending, not content.
    text=$(cat "$out_file" 2>/dev/null || true)
    text=${text%$'\n'}
    rm -f "$out_file" "$err_file"
    fm_ext_launchwrap_prefix_ok "$text" "$name" || return 1
    if [ -n "${text//[[:space:]]/}" ]; then
      FM_EXT_LAUNCHWRAP_PREFIX+=$text
      contributors+="$name"$'\t'"$path"$'\n'
    fi
  done <<ROWS_EOF
$rows
ROWS_EOF
  # Preflight is advisory by contract: a hook that prepares the environment for
  # its own wrapper may fail without blocking the spawn, because the launch
  # postcondition - not the preflight - is what proves the worker came up. Only
  # extensions whose prefix contributed this launch preflight; an opted-out
  # launch is not one the wrapper is preparing for.
  local wname wpath first_werr wrap_err_file
  while IFS=$'\t' read -r wname wpath; do
    [ -n "$wname" ] || continue
    rc=0
    wrap_err_file=$(mktemp "${TMPDIR:-/tmp}/fm-ext-wrap-preflight.XXXXXX") || {
      FM_EXT_LAUNCHWRAP_WARN+="launch-wrap: extension '$wname''s preflight was skipped because no temporary file could be created to capture its diagnostics; the spawn proceeds because preflight is advisory"$'\n'
      continue
    }
    fm_run_timed "$FM_EXT_HOOK_TIMEOUT_SECONDS" \
      env \
        FM_HOME="$home" \
        FM_ROOT="$root" \
        FM_EXT_NAME="$wname" \
        FM_EXT_DIR="$(dirname "$(dirname "$wpath")")" \
        FM_EXT_PHASE=launch \
        FM_TASK_ID="$task_id" \
        FM_TASK_KIND="$task_kind" \
        FM_HARNESS="$harness" \
        FM_WORKTREE="$worktree" \
        "$wpath" preflight \
      >/dev/null 2>"$wrap_err_file" </dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      first_werr=$(fm_ext_hook_sanitize "$(sed -n '1p' "$wrap_err_file" 2>/dev/null || true)")
      FM_EXT_LAUNCHWRAP_WARN+="launch-wrap: extension '$wname''s preflight failed (exit $rc)${first_werr:+: $first_werr}; the spawn proceeds because preflight is advisory and the launch postcondition owns liveness"$'\n'
    fi
    rm -f "$wrap_err_file"
  done <<CONTRIB_EOF
$contributors
CONTRIB_EOF
  return 0
}
