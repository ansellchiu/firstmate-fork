#!/usr/bin/env bash
# fm-upstream-guard-lib.sh - refusal and post-merge warning for a pull request
# that carries public upstream commits.
#
# bin/fm-upstream.sh pr-guard and pr-landed own the test. This library owns
# how a merge turns that result into a refusal or an actionable warning.
# Sourced by bin/fm-pr-merge.sh. No side effects on source.
#
# FM_UPSTREAM_GUARD_CMD, when set, replaces bin/fm-upstream.sh so a test can
# stub the two verbs. SCRIPT_DIR is the sourcing script's directory.

# fm_upstream_guard_eval <repo-url> <pr-ref> <head> <base>
#
# Runs pr-guard and records the verdict in FM_UPSTREAM_GUARD,
# FM_UPSTREAM_GUARD_REASON, FM_UPSTREAM_GUARD_COUNT, and
# FM_UPSTREAM_GUARD_THROUGH. A non-zero exit, an empty base, or output with
# no upstream-guard line is unknown. Always returns 0.
fm_upstream_guard_eval() {
  local repo_url=${1:-} pr_ref=${2:-} head=${3:-} base=${4:-}
  local cmd out status=0 line rest verdict=""
  FM_UPSTREAM_GUARD=unknown
  FM_UPSTREAM_GUARD_REASON="the upstream guard could not run"
  FM_UPSTREAM_GUARD_COUNT=
  FM_UPSTREAM_GUARD_THROUGH=
  if [ -z "$base" ]; then
    return 0
  fi
  # shellcheck disable=SC2154 # SCRIPT_DIR is set by the sourcing merge script.
  cmd=${FM_UPSTREAM_GUARD_CMD:-$SCRIPT_DIR/fm-upstream.sh}
  # The verdict is the stdout contract. The child's own diagnostics stay out
  # of the merge's stderr; a failed run is reported as unknown below.
  out=$("$cmd" pr-guard \
    --repo-url "$repo_url" \
    --pr-ref "$pr_ref" \
    --head "$head" \
    --base "$base" 2>/dev/null) || status=$?
  if [ "$status" -ne 0 ]; then
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "upstream-guard:"*)
        if [ -z "$verdict" ]; then
          rest=${line#"upstream-guard:"}
          rest=${rest#" "}
          verdict=${rest%%:*}
          case "$rest" in
            *:*) FM_UPSTREAM_GUARD_REASON=${rest#*: } ;;
            *) FM_UPSTREAM_GUARD_REASON= ;;
          esac
        fi
        ;;
      "upstream-carried-commits:"*)
        FM_UPSTREAM_GUARD_COUNT=${line#"upstream-carried-commits:"}
        FM_UPSTREAM_GUARD_COUNT=${FM_UPSTREAM_GUARD_COUNT#" "}
        ;;
      "upstream-carried-through:"*)
        FM_UPSTREAM_GUARD_THROUGH=${line#"upstream-carried-through:"}
        FM_UPSTREAM_GUARD_THROUGH=${FM_UPSTREAM_GUARD_THROUGH#" "}
        ;;
    esac
  done <<EOF
$out
EOF
  case "$verdict" in
    not-applicable|clear|carries|unknown) FM_UPSTREAM_GUARD=$verdict ;;
    *)
      FM_UPSTREAM_GUARD=unknown
      FM_UPSTREAM_GUARD_REASON="the upstream guard could not run"
      ;;
  esac
  return 0
}

# fm_upstream_guard_refuse <url> <method> <auto:true|false>
#
# Prints one refusal to stderr and returns 1, or returns 0 when the merge
# may proceed. First match wins.
fm_upstream_guard_refuse() {
  local url=${1:-} method=${2:-} auto=${3:-} method_lc short
  method_lc=$(printf '%s' "$method" | tr '[:upper:]' '[:lower:]')
  short=${FM_UPSTREAM_GUARD_THROUGH:-}
  short=${short:0:8}
  case "${FM_UPSTREAM_GUARD:-}" in
    not-applicable|clear) return 0 ;;
  esac
  if [ "${FM_UPSTREAM_GUARD:-}" = carries ] && [ "$auto" = true ]; then
    printf 'error: refusing to merge %s: it carries %s public upstream commits and --auto can hand it to a merge queue that applies its own method; merge it synchronously with: -- --merge\n' \
      "$url" "${FM_UPSTREAM_GUARD_COUNT:-}" >&2
    return 1
  fi
  if [ "$method_lc" = merge ]; then
    return 0
  fi
  if [ "${FM_UPSTREAM_GUARD:-}" = carries ]; then
    printf 'error: refusing to merge %s: it carries %s public upstream commits (through %s) and merge method "%s" would discard their ancestry; rerun with: -- --merge\n' \
      "$url" "${FM_UPSTREAM_GUARD_COUNT:-}" "$short" "$method" >&2
    return 1
  fi
  if [ "${FM_UPSTREAM_GUARD:-}" = unknown ]; then
    printf 'error: refusing to merge %s with merge method "%s": could not prove it carries no public upstream commits (%s); rerun with: -- --merge, which is safe either way\n' \
      "$url" "$method" "${FM_UPSTREAM_GUARD_REASON:-}" >&2
    return 1
  fi
  return 0
}

# fm_upstream_guard_refuse_gitlab <url>
#
# GitLab does not tell this script which merge method it will apply, so a
# carrying or unchecked merge request is refused outright. Returns 0 for
# not-applicable and clear. The parenthetical is the guard's reason, or the
# verdict when the guard stated none.
fm_upstream_guard_refuse_gitlab() {
  local url=${1:-} reason
  case "${FM_UPSTREAM_GUARD:-}" in
    not-applicable|clear) return 0 ;;
  esac
  reason=${FM_UPSTREAM_GUARD_REASON:-}
  if [ -z "$reason" ]; then
    reason=${FM_UPSTREAM_GUARD:-unknown}
  fi
  printf 'error: refusing to merge %s: it carries public upstream commits, or that could not be ruled out (%s), and this script cannot prove which merge method GitLab will apply; merge it on the forge with a merge commit\n' \
    "$url" "$reason" >&2
  return 1
}

# fm_upstream_guard_landed <url> <base>
#
# After a merge this run reported as landed, warns when a carried upstream
# commit is not on the base branch. Always returns 0.
fm_upstream_guard_landed() {
  local url=${1:-} base=${2:-}
  local cmd out through short
  [ "${FM_UPSTREAM_GUARD:-}" = carries ] || return 0
  through=${FM_UPSTREAM_GUARD_THROUGH:-}
  short=${through:0:8}
  # shellcheck disable=SC2154 # SCRIPT_DIR is set by the sourcing merge script.
  cmd=${FM_UPSTREAM_GUARD_CMD:-$SCRIPT_DIR/fm-upstream.sh}
  out=$("$cmd" pr-landed --through "$through" --base "$base" 2>/dev/null) || true
  case "$out" in
    *"upstream-ancestry: lost"*)
      printf 'actionable: merged %s but public upstream ancestry through %s is not on %s; run bin/fm-upstream.sh check\n' \
        "$url" "$short" "$base" >&2
      ;;
  esac
  return 0
}
