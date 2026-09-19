#!/usr/bin/env bash
# fm-ext.sh - the single owner of firstmate's out-of-tree extension contract:
# install, update, uninstall, status, inventory, declared load triggers, and
# hook enumeration for extension packages that live in their own repository.
#
# An extension is a self-contained package directory carrying an ext.json
# manifest. It is never copied into a home. Install places symlinks - one for
# the package's agent skill, one per package-owned command - and records a
# receipt, so exactly one copy of the code exists and it lives in the extension
# repository.
#
# Usage:
#   fm-ext.sh install <package-path-or-name> [--home <h>] [--allow-multiple-launch-wrap] [configure flags...]
#   fm-ext.sh update <name> [--home <h>] [--allow-multiple-launch-wrap]
#   fm-ext.sh uninstall <name> [--home <h>] [--purge] [--force]
#   fm-ext.sh status [<name>] [--home <h>]
#   fm-ext.sh list [--home <h>]
#   fm-ext.sh triggers [--home <h>]
#   fm-ext.sh hooks <kind> [--home <h>]
#       One "<name><TAB><path><TAB><status>" line per installed extension that
#       registers a hook of that kind, in extension-name order. <status> is "ok"
#       or the reason the registered hook cannot be run; a broken registration is
#       reported rather than dropped, so a caller can tell it apart from an
#       extension that has no hook at all. bin/fm-ext-hook-lib.sh runs them.
#   fm-ext.sh lint <package-path>
#
# <package-path-or-name>: a package directory, or a bare name resolved as
# $FM_EXT_ROOT/extensions/<name> when FM_EXT_ROOT is set.
# --home defaults to $FM_HOME, then the current directory.
#
# Manifest (ext.json), schema "firstmate.ext.v1":
#   schema   (required) exactly "firstmate.ext.v1"
#   name     (required) [a-z0-9][a-z0-9-]*, must equal the package directory name
#   version  (required) non-empty string
#   trigger  (required) the load condition, prose, stated as a condition
#   commands (optional) package-relative executables symlinked into <home>/bin
#   config   (optional) <home>/config file names the extension reads; home-owned,
#            never written by update, removed only by --purge
#   state    (optional) <home>/state subdirectory names the extension owns
#   hooks    (optional) object of kind -> package-relative executable
#   requires (optional) capability tokens this firstmate checkout must provide
#   dependency_check (optional) package-relative command run before install
#   configure        (optional) package-relative command run after install
#   inherit  (optional) boolean; config[] propagates to secondmate homes
#
# The launch-wrap hook contract (the worker-launch seam bin/fm-spawn.sh
# composes). The hook executable is invoked two ways:
#   <hook> prefix     required. stdout is shell text spliced verbatim
#                     immediately before the agent binary of every verified
#                     launch this home performs, after firstmate's own env
#                     assignments, so env prefixes set before the wrapper are
#                     preserved through it. The text must be ONE line, must
#                     carry its own shell quoting, and - when nonempty - must
#                     end in a space so it cannot fuse with the binary's first
#                     argument. Empty stdout means this launch is not wrapped:
#                     an installed-but-opted-out extension contributes nothing
#                     and costs nothing. A failing, hanging, multi-line,
#                     oversized, or space-less prefix REFUSES THE SPAWN before
#                     any task state is created, because launching a worker
#                     without the configured wrapper is the silent failure this
#                     hook exists to prevent.
#   <hook> preflight  optional (exit 0 silently when there is nothing to
#                     prepare). Runs only when the same hook's prefix actually
#                     contributed to this launch. ADVISORY: a preflight failure
#                     prints a warning and the spawn proceeds, because the
#                     launch postcondition - not the preflight - is what proves
#                     a worker came up.
# Environment for both: FM_HOME, FM_ROOT, FM_EXT_NAME, FM_EXT_DIR,
# FM_EXT_PHASE=launch, FM_TASK_ID, FM_TASK_KIND (ship, scout, or secondmate),
# FM_HARNESS, and FM_WORKTREE - the task's isolated worktree when one is already
# known (a relaunch's recorded worktree, a secondmate's home), empty for a fresh
# crewmate/scout whose worktree is allocated after resolution, by design: a
# refusal must happen before anything exists to clean up.
# Composition: prefixes concatenate in extension-name order, first-ordered
# outermost, and every hook in the chain must exec its argument WITH THE
# ENVIRONMENT INTACT - one wrapper that sanitizes the environment silently
# destroys every wrapper after it. Install therefore refuses a second
# launch-wrap extension unless --allow-multiple-launch-wrap is passed, and
# update runs the same gate when a package newly registers one.
# A secret's VALUE never belongs in this seam: a wrapper handles key NAMES at
# most, and the value stays inside the wrapped process.
#
# Capabilities this checkout provides are listed in FM_EXT_CAPABILITIES below.
# A manifest requiring a capability this checkout does not provide is refused,
# by name, rather than installed into a home that cannot honour it.
#
# The `../` escape rule: a package file may not reference a path that escapes
# the package root. A symlinked skill resolves `../` differently for the agent
# (lexically, back into the firstmate repo) than for any script, `cat`, or test
# (physically, into the extension repo), so such a reference works when read and
# fails when executed. `lint` enforces this, and install and update run it.
#
# The `.git/info/exclude` rule: the symlinks land in tracked directories, so
# install writes exclude entries into the home's own per-clone exclude file and
# verifies them with `git check-ignore`. That file is NOT copied by `git clone`,
# so a re-cloned home shows extension symlinks as untracked and invites a manual
# cleanup that leaves a stale receipt behind. `status` detects and names that
# state rather than letting it pass.
#
# Exit codes:
#   0  healthy
#   1  status: the named extension is not installed here
#   2  usage, manifest, or safety refusal
#   3  status: an installation is broken (missing symlink, retargeted symlink,
#      missing target, unusable receipt, or an exclude entry that no longer hides
#      the symlink)
#   4  status: a name in config/ext-required is not installed here
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# shellcheck source=bin/fm-ext-hook-lib.sh
. "$SCRIPT_DIR/fm-ext-hook-lib.sh"

# Capabilities this firstmate checkout provides to extensions. A manifest's
# requires[] is checked against exactly this list, so an extension built against
# a seam this checkout does not have refuses loudly instead of installing into a
# home that cannot honour it.
#   ext.v1              this manifest schema and the install contract around it
#   hook:session-start  the digest contributor bin/fm-session-start.sh runs
#   hook:launch-wrap    the worker-launch wrapper bin/fm-spawn.sh composes
FM_EXT_CAPABILITIES="ext.v1 hook:session-start hook:launch-wrap"

# Byte cap one extension's session-start contribution may add to a digest,
# reported by `status` as an estimated context cost because
# config/startup-memory-budget governs data/captain.md, data/captain-shared.md,
# and data/learnings.md only - it does not govern extension output.
# fm-ext-hook-lib.sh owns the number; this is the reporting name for it.
FM_EXT_DIGEST_BYTE_CAP=$FM_EXT_HOOK_BYTE_CAP

MANIFEST_SCHEMA="firstmate.ext.v1"
RECEIPT_SCHEMA="firstmate.ext.install.v1"

die() { printf 'fm-ext.sh: %s\n' "$*" >&2; exit 2; }

usage() {
  sed -n '/^# Usage:/,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required to read extension manifests"
}

# --- home and package resolution -------------------------------------------

resolve_home() {
  local home=$1
  [ -n "$home" ] || die "home path must not be empty"
  case "$home" in *$'\n'*|*$'\r'*|*$'\t'*) die "home path contains a control separator" ;; esac
  [ "$home" != / ] || die "refusing to use the filesystem root as a home"
  [ ! -L "$home" ] || die "home must not be a symlink: $home"
  [ -d "$home" ] || die "home does not exist: $home"
  (cd "$home" && pwd -P)
}

resolve_package() {
  local arg=$1 path
  [ -n "$arg" ] || die "package path or name is required"
  case "$arg" in
    */*|.|..) path=$arg ;;
    *)
      if [ -n "${FM_EXT_ROOT:-}" ] && [ -d "${FM_EXT_ROOT}/extensions/$arg" ]; then
        path="${FM_EXT_ROOT}/extensions/$arg"
      else
        path=$arg
      fi
      ;;
  esac
  [ -d "$path" ] || die "no extension package directory at: $path"
  [ ! -L "$path" ] || die "extension package must not be reached through a symlink: $path"
  (cd "$path" && pwd -P)
}

ext_name_valid() {
  case "$1" in
    ''|*[!a-z0-9-]*) return 1 ;;
    -*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- manifest ---------------------------------------------------------------

# read_manifest <pkg>: validate ext.json and export EXT_NAME/EXT_VERSION/EXT_TRIGGER.
read_manifest() {
  local pkg=$1 manifest
  require_jq
  manifest="$pkg/ext.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || die "extension manifest is missing or unsafe: $manifest"
  jq -e . "$manifest" >/dev/null 2>&1 || die "extension manifest is not valid JSON: $manifest"
  local schema
  schema=$(jq -r '.schema // ""' "$manifest")
  [ "$schema" = "$MANIFEST_SCHEMA" ] \
    || die "extension manifest schema is '$schema', expected '$MANIFEST_SCHEMA': $manifest"
  EXT_NAME=$(jq -r '.name // ""' "$manifest")
  EXT_VERSION=$(jq -r '.version // ""' "$manifest")
  EXT_TRIGGER=$(jq -r '.trigger // ""' "$manifest")
  EXT_MANIFEST=$manifest
  ext_name_valid "$EXT_NAME" || die "extension name must match [a-z0-9-]+ and not start with '-': '$EXT_NAME'"
  [ "$EXT_NAME" = "$(basename "$pkg")" ] \
    || die "extension name '$EXT_NAME' does not match its package directory '$(basename "$pkg")'"
  [ -n "$EXT_VERSION" ] || die "extension manifest has no version: $manifest"
  [ -n "$EXT_TRIGGER" ] || die "extension '$EXT_NAME' declares no trigger; every extension must state its load condition"
}

manifest_list() { jq -r --arg k "$1" '(.[$k] // []) | .[]' "$EXT_MANIFEST"; }

check_capabilities() {
  local token missing=
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case " $FM_EXT_CAPABILITIES " in
      *" $token "*) ;;
      *) missing="$missing $token" ;;
    esac
  done < <(manifest_list requires)
  [ -z "$missing" ] || die "extension '$EXT_NAME' requires capabilities this firstmate checkout does not provide:$missing (provided: $FM_EXT_CAPABILITIES)"
}

# --- ../ escape lint --------------------------------------------------------

# path_escapes <dir-relative-to-package-root> <token>
# Lexically resolve <token> from <dir> and report whether it leaves the package.
path_escapes() {
  local base=$1 token=$2 depth=0 seg rc=1 joined
  case "$token" in /*) return 1 ;; esac
  # Join before splitting. Bash 3.2 word-splits each expansion in `$base/$token`
  # separately, so the literal slash fuses the last field of one with the first
  # field of the next: `.` + `/` + `../../x` yields `./..` as one segment, one
  # `..` is swallowed, and a reference that escapes by exactly one level is
  # scored as staying inside the package.
  joined="$base/$token"
  set -f
  local IFS=/
  for seg in $joined; do
    case "$seg" in
      ''|.) ;;
      ..)
        depth=$((depth - 1))
        if [ "$depth" -lt 0 ]; then rc=0; break; fi
        ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
  set +f
  return "$rc"
}

# lint_package <pkg>: print one violation per line, return 1 if any were found.
lint_package() {
  local pkg=$1 file rel dir line token found=0
  while IFS= read -r file; do
    rel=${file#"$pkg/"}
    dir=$(dirname "$rel")
    grep -Iq . "$file" 2>/dev/null || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      token=${line#*:}
      case "$token" in *../*) ;; *) continue ;; esac
      if path_escapes "$dir" "$token"; then
        printf 'EXT_ESCAPE: %s:%s references %s, which escapes the package root\n' \
          "$rel" "${line%%:*}" "$token"
        found=1
      fi
    done < <(grep -noE '[A-Za-z0-9_.@/-]*\.\./[A-Za-z0-9_.@/-]*' "$file" 2>/dev/null || true)
  done < <(find "$pkg" -type f ! -path '*/.git/*' | LC_ALL=C sort)
  [ "$found" -eq 0 ]
}

# --- home paths -------------------------------------------------------------

receipt_dir() { printf '%s/state/ext/%s\n' "$1" "$2"; }
receipt_path() { printf '%s/state/ext/%s/install.json\n' "$1" "$2"; }
skill_link_path() { printf '%s/.agents/skills/%s\n' "$1" "$2"; }

# ownable_link_path <home> <name> <link>: true when <link> is one of the paths
# link_rows can place for <name> in <home> - the extension's own skill link, or
# a bare-named command link in the home's bin.
ownable_link_path() {
  local home=$1 name=$2 link=$3 bare
  [ "$link" != "$(skill_link_path "$home" "$name")" ] || return 0
  case "$link" in "$home/bin/"*) bare=${link#"$home/bin/"} ;; *) return 1 ;; esac
  case "$bare" in ''|*/*|.|..) return 1 ;; esac
  return 0
}

assert_writable_home_dirs() {
  local home=$1 d
  for d in .agents .agents/skills bin state state/ext config; do
    if [ -e "$home/$d" ] && [ -L "$home/$d" ]; then
      die "home directory must not be a symlink: $home/$d"
    fi
  done
}

# --- per-clone exclude ------------------------------------------------------

# exclude_file <home>: absolute path to the home's own info/exclude, or empty
# when the home is not a git working tree.
exclude_file() {
  local home=$1 p
  git -C "$home" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return 0; }
  p=$(git -C "$home" rev-parse --git-path info/exclude 2>/dev/null) || { printf ''; return 0; }
  case "$p" in /*) printf '%s\n' "$p" ;; *) printf '%s/%s\n' "$home" "$p" ;; esac
}

# exclude_pattern <home> <abs-path>: the toplevel-anchored pattern for a path.
exclude_pattern() {
  local home=$1 abs=$2 top rel
  top=$(git -C "$home" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd "$top" && pwd -P)
  case "$abs" in
    "$top"/*) rel=${abs#"$top"/} ;;
    *) return 1 ;;
  esac
  printf '/%s\n' "$rel"
}

exclude_add() {
  local home=$1 abs=$2 file pattern
  file=$(exclude_file "$home")
  [ -n "$file" ] || return 0
  pattern=$(exclude_pattern "$home" "$abs") || return 0
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ] && grep -Fxq -- "$pattern" "$file"; then :; else
    printf '%s\n' "$pattern" >> "$file"
  fi
  git -C "$home" check-ignore -q -- "$abs" \
    || die "wrote '$pattern' to $file but git still reports $abs as untracked; refusing to leave the home dirty"
}

exclude_remove() {
  local home=$1 abs=$2 file pattern tmp
  file=$(exclude_file "$home")
  [ -n "$file" ] && [ -f "$file" ] || return 0
  pattern=$(exclude_pattern "$home" "$abs") || return 0
  tmp=$(mktemp "$file.XXXXXX")
  grep -Fxv -- "$pattern" "$file" > "$tmp" || true
  mv "$tmp" "$file"
}

# exclude_effective <home> <abs-path>: 0 when git hides the path, 1 when it does
# not, 2 when the home is not a git working tree (nothing to hide it from).
exclude_effective() {
  local home=$1 abs=$2
  git -C "$home" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
  git -C "$home" check-ignore -q -- "$abs"
}

# --- links and receipt ------------------------------------------------------

link_place() {
  local link=$1 target=$2
  [ -e "$target" ] || die "package target does not exist: $target"
  mkdir -p "$(dirname "$link")"
  if [ -L "$link" ]; then
    rm -f "$link"
  elif [ -e "$link" ]; then
    die "refusing to replace an existing non-symlink path: $link"
  fi
  ln -s "$target" "$link"
}

# link_rows <home> <pkg>: emit "kind<TAB>link<TAB>target<TAB>sha" per link.
link_rows() {
  local home=$1 pkg=$2 cmd link target sha
  printf 'skill\t%s\t%s\t%s\n' "$(skill_link_path "$home" "$EXT_NAME")" "$pkg" "$(fm_pr_sha256 "$EXT_MANIFEST")"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    case "$cmd" in /*|*..*) die "command path must be package-relative and must not contain '..': $cmd" ;; esac
    target="$pkg/$cmd"
    [ -f "$target" ] || die "declared command is missing from the package: $cmd"
    [ -x "$target" ] || die "declared command is not executable: $cmd"
    link="$home/bin/$(basename "$cmd")"
    sha=$(fm_pr_sha256 "$target")
    printf 'command\t%s\t%s\t%s\n' "$link" "$target" "$sha"
  done < <(manifest_list commands)
}

write_receipt() {
  local home=$1 pkg=$2 rows=$3 dir tmp commit
  dir=$(receipt_dir "$home" "$EXT_NAME")
  [ ! -L "$dir" ] || die "extension receipt directory must not be a symlink: $dir"
  mkdir -p "$dir"
  commit=$(git -C "$pkg" rev-parse HEAD 2>/dev/null || printf '')
  tmp=$(mktemp "$dir/.install.XXXXXX")
  chmod 600 "$tmp"
  jq -n \
    --arg schema "$RECEIPT_SCHEMA" \
    --arg name "$EXT_NAME" \
    --arg version "$EXT_VERSION" \
    --arg trigger "$EXT_TRIGGER" \
    --arg source_path "$pkg" \
    --arg source_commit "$commit" \
    --rawfile rows "$rows" \
    --slurpfile manifest "$EXT_MANIFEST" \
    '{schema:$schema, name:$name, version:$version, trigger:$trigger,
      source_path:$source_path, source_commit:$source_commit,
      hooks:($manifest[0].hooks // {}),
      config:($manifest[0].config // []),
      state:($manifest[0].state // []),
      inherit:($manifest[0].inherit // false),
      links:[$rows | split("\n") | .[] | select(length>0) | split("\t")
             | {kind:.[0], path:.[1], target:.[2], target_sha256:.[3]}]}' > "$tmp"
  mv "$tmp" "$(receipt_path "$home" "$EXT_NAME")"

  # The hook kinds the extension registers, recorded beside the receipt rather
  # than only inside it. A receipt that cannot be parsed hides every field it
  # carries, including WHICH hooks exist; this one-fact-per-line record keeps
  # that question answerable, so an extension registering no hook of a kind
  # cannot be mistaken for one whose registration is unknowable.
  tmp=$(mktemp "$dir/.hooks.XXXXXX")
  chmod 600 "$tmp"
  jq -r '(.hooks // {}) | keys[]' "$EXT_MANIFEST" > "$tmp"
  mv "$tmp" "$(registration_path "$home" "$EXT_NAME")"
}

registration_path() { printf '%s/state/ext/%s/registered-hooks\n' "$1" "$2"; }

# read_registration <home> <name> <kind>: 0 when the extension is known to
# register that kind, 1 when it is known not to, 2 when the record is missing
# or unreadable and the registration is therefore unknowable.
read_registration() {
  local file
  file=$(registration_path "$1" "$2")
  [ -f "$file" ] && [ ! -L "$file" ] || return 2
  if grep -Fxq -- "$3" "$file"; then return 0; fi
  return 1
}

# backfill_registration <home> <name> <receipt>: write the hook-kind record for
# an extension whose receipt is still readable but that predates the record.
# write_receipt is its only other writer, so without this an extension installed
# before the record existed has no registration to fall back on the moment its
# receipt goes missing. Idempotent, silent, and never fatal: it repairs the
# evidence when it can and leaves a read-only home exactly as it found it.
backfill_registration() {
  local home=$1 name=$2 receipt=$3 file dir tmp
  file=$(registration_path "$home" "$name")
  [ ! -e "$file" ] || return 0
  dir=$(dirname "$file")
  { [ -d "$dir" ] && [ ! -L "$dir" ] && [ -w "$dir" ]; } || return 0
  tmp=$(mktemp "$dir/.hooks.XXXXXX" 2>/dev/null) || return 0
  chmod 600 "$tmp" 2>/dev/null || true
  if jq -r '(.hooks // {}) | keys[]' "$receipt" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

read_receipt() {
  local home=$1 name=$2 receipt
  receipt=$(receipt_path "$home" "$name")
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  jq -e --arg s "$RECEIPT_SCHEMA" 'select(.schema==$s)' "$receipt" >/dev/null 2>&1 || return 1
  RECEIPT=$receipt
}

installed_names() {
  local home=$1 d
  for d in "$home"/state/ext/*/; do
    [ -d "$d" ] || continue
    d=$(basename "$d")
    [ -f "$(receipt_path "$home" "$d")" ] || continue
    printf '%s\n' "$d"
  done | LC_ALL=C sort
}

# launchwrap_orphan_names <home>: extension directories core cannot read an
# install record for, whose surviving registration record still names a
# launch-wrap hook. Registration is the deliberate record that a wrapper was
# installed, so such a directory means "wrapper present, evidence broken" -
# the fail-closed state the seam governs - and it must not read as absent.
launchwrap_orphan_names() {
  local home=$1 d
  for d in "$home"/state/ext/*/; do
    [ -d "$d" ] || continue
    d=$(basename "$d")
    [ ! -f "$(receipt_path "$home" "$d")" ] || continue
    read_registration "$home" "$d" launch-wrap || continue
    printf '%s\n' "$d"
  done | LC_ALL=C sort
}

# hook_enum_names <home> <kind>: the extensions `hooks <kind>` must account
# for. Only launch-wrap widens past installed_names; list, status and triggers
# keep treating a receipt-less directory as not installed.
hook_enum_names() {
  local home=$1 kind=$2
  {
    installed_names "$home"
    [ "$kind" != launch-wrap ] || launchwrap_orphan_names "$home"
  } | LC_ALL=C sort -u
}

required_names() {
  local home=$1 file line
  file="$home/config/ext-required"
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done < "$file" | LC_ALL=C sort -u
}

# verify_links <home> <name>: print one typed diagnostic per broken link.
# Returns 0 when every link matches the receipt.
verify_links() {
  local home=$1 name=$2 kind path target actual broken=0
  read_receipt "$home" "$name" || {
    printf 'EXT_BROKEN: %s has no readable install record in %s; reinstall it with bin/fm-ext.sh install <package> --home %s\n' "$name" "$home" "$home"
    return 1
  }
  while IFS=$'\t' read -r kind path target _sha; do
    [ -n "$path" ] || continue
    if [ ! -L "$path" ]; then
      if [ -e "$path" ]; then
        printf 'EXT_DRIFT: %s %s link at %s is no longer a symlink; remove it and run bin/fm-ext.sh update %s --home %s\n' "$name" "$kind" "$path" "$name" "$home"
      else
        printf 'EXT_BROKEN: %s %s link is missing at %s while its install record still claims it (a re-cloned home shows these symlinks as untracked and invites deleting them); reinstall with bin/fm-ext.sh install %s --home %s, or clear the stale record with bin/fm-ext.sh uninstall %s --home %s --force\n' "$name" "$kind" "$path" "$target" "$home" "$name" "$home"
      fi
      broken=1
      continue
    fi
    actual=$(readlink "$path")
    if [ "$actual" != "$target" ]; then
      printf 'EXT_DRIFT: %s %s link at %s points to %s, not the recorded %s; run bin/fm-ext.sh update %s --home %s\n' "$name" "$kind" "$path" "$actual" "$target" "$name" "$home"
      broken=1
      continue
    fi
    if [ ! -e "$target" ]; then
      printf 'EXT_BROKEN: %s %s link at %s points to %s, which no longer exists; restore the extension repository or run bin/fm-ext.sh uninstall %s --home %s --force\n' "$name" "$kind" "$path" "$target" "$name" "$home"
      broken=1
    fi
  done < <(jq -r '.links[] | [.kind,.path,.target,.target_sha256] | @tsv' "$RECEIPT")
  [ "$broken" -eq 0 ]
}

# verify_excludes <home> <name>: print a diagnostic per link git no longer hides.
verify_excludes() {
  local home=$1 name=$2 path rc broken=0 file
  read_receipt "$home" "$name" || return 1
  file=$(exclude_file "$home")
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$path" ] || [ -L "$path" ] || continue
    rc=0; exclude_effective "$home" "$path" || rc=$?
    if [ "$rc" -eq 1 ]; then
      printf 'EXT_EXCLUDE: %s link %s is not hidden by %s, so it shows as untracked and is one tidy-up away from an uninstall nobody recorded; run bin/fm-ext.sh update %s --home %s to rewrite the entry\n' \
        "$name" "$path" "${file:-the home exclude file}" "$name" "$home"
      broken=1
    fi
  done < <(jq -r '.links[].path' "$RECEIPT")
  [ "$broken" -eq 0 ]
}

# --- estimated context cost -------------------------------------------------

est_tokens() { printf '%s\n' $(( ( ${1:-0} + 2 ) / 3 )); }

file_bytes() {
  [ -f "$1" ] || { printf '0\n'; return 0; }
  wc -c < "$1" | tr -d '[:space:]'
}

# --- commands ---------------------------------------------------------------

PARSED_HOME=
PARSED_REST=()
PARSED_REST_COUNT=0

parse_home_and_rest() {
  PARSED_HOME=${FM_HOME:-$PWD}
  PARSED_REST=()
  PARSED_REST_COUNT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) PARSED_HOME=${2:-}; shift 2 ;;
      *) PARSED_REST+=("$1"); PARSED_REST_COUNT=$((PARSED_REST_COUNT + 1)); shift ;;
    esac
  done
  PARSED_HOME=$(resolve_home "$PARSED_HOME")
}

# Composition gate: prefixes concatenate in extension-name order and every
# wrapper in the chain must exec its argument with the environment intact, so a
# second launch-wrap extension is a declared risk, not a solved problem - one
# sanitizer among wrappers silently strips the others. Install always runs the
# gate, and update runs it only when the update newly registers the hook: a
# composition that was already acknowledged is not changed by an update. The
# extension being written is excluded from the count so re-registering its own
# hook is not a second one.
launchwrap_gate() {  # <home> <allow-multiple>
  # RECEIPT is shadowed for the duration of the count: the gate reads other
  # extensions' receipts, and its callers go on to read their own from the
  # global right afterwards.
  local home=$1 allow=$2 other count=0 RECEIPT
  [ -n "$(jq -r '.hooks["launch-wrap"] // ""' "$EXT_MANIFEST")" ] || return 0
  while IFS= read -r other; do
    [ "$other" != "$EXT_NAME" ] || continue
    read_receipt "$home" "$other" || continue
    if [ -n "$(jq -r '.hooks["launch-wrap"] // ""' "$RECEIPT")" ]; then
      count=$((count + 1))
    fi
  done < <(installed_names "$home")
  if [ "$count" -gt 0 ] && [ "$allow" != true ]; then
    die "extension '$EXT_NAME' registers a launch-wrap hook and $home already has $count launch-wrap extension(s); launch wrappers compose in extension-name order and each must exec its argument with the environment intact, so a second one is refused unless you pass --allow-multiple-launch-wrap"
  fi
}

cmd_install() {
  local allow_multi_wrap=false
  local rest=() arg
  for arg in "$@"; do
    case "$arg" in
      --allow-multiple-launch-wrap) allow_multi_wrap=true ;;
      *) rest+=("$arg") ;;
    esac
  done
  parse_home_and_rest "${rest[@]+"${rest[@]}"}"
  [ "$PARSED_REST_COUNT" -ge 1 ] || die "install requires a package path or name"
  local home=$PARSED_HOME pkg link rows
  pkg=$(resolve_package "${PARSED_REST[0]}")
  read_manifest "$pkg"
  check_capabilities
  [ ! -e "$(receipt_path "$home" "$EXT_NAME")" ] \
    || die "extension '$EXT_NAME' is already installed in $home; use update"
  launchwrap_gate "$home" "$allow_multi_wrap"
  lint_package "$pkg" || die "extension '$EXT_NAME' references paths outside its own package; a symlinked package resolves those differently for the agent than for any script, so install refuses"

  assert_writable_home_dirs "$home"

  rows=$(mktemp "${TMPDIR:-/tmp}/fm-ext-links.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$rows'" EXIT
  link_rows "$home" "$pkg" > "$rows"
  while IFS=$'\t' read -r _kind link _target _sha; do
    if [ -e "$link" ] || [ -L "$link" ]; then
      die "a target path already exists without this extension's install record: $link"
    fi
  done < "$rows"

  local dep
  dep=$(jq -r '.dependency_check // ""' "$EXT_MANIFEST")
  if [ -n "$dep" ]; then
    # shellcheck disable=SC2086
    ( cd "$pkg" && FM_HOME="$home" FM_EXT_NAME="$EXT_NAME" FM_EXT_DIR="$pkg" sh -c "$dep" ) >/dev/null \
      || die "extension '$EXT_NAME' declares unmet dependencies; run '$dep' in $pkg for the detail"
  fi

  mkdir -p "$home/bin" "$home/.agents/skills"
  while IFS=$'\t' read -r _kind link target _sha; do
    link_place "$link" "$target"
    exclude_add "$home" "$link"
  done < "$rows"
  write_receipt "$home" "$pkg" "$rows"
  rm -f "$rows"
  trap - EXIT

  printf 'installed: %s %s in %s (package %s)\n' "$EXT_NAME" "$EXT_VERSION" "$home" "$pkg"
  printf 'note: the skill becomes invocable at the next skill-registry scan, not necessarily this turn\n'

  local configure
  configure=$(jq -r '.configure // ""' "$EXT_MANIFEST")
  if [ -n "$configure" ] && [ "$PARSED_REST_COUNT" -gt 1 ]; then
    ( cd "$pkg" && FM_HOME="$home" FM_EXT_NAME="$EXT_NAME" FM_EXT_DIR="$pkg" \
        sh -c "$configure \"\$@\"" _ "${PARSED_REST[@]:1}" )
  elif [ -n "$configure" ]; then
    printf 'next: configure it with %s in %s\n' "$configure" "$pkg"
  fi
}

cmd_update() {
  local allow_multi_wrap=false
  local rest=() arg
  for arg in "$@"; do
    case "$arg" in
      --allow-multiple-launch-wrap) allow_multi_wrap=true ;;
      *) rest+=("$arg") ;;
    esac
  done
  parse_home_and_rest "${rest[@]+"${rest[@]}"}"
  [ "$PARSED_REST_COUNT" -eq 1 ] || die "update takes exactly one extension name"
  local home=$PARSED_HOME name=${PARSED_REST[0]} pkg rows link target had_wrap
  read_receipt "$home" "$name" || die "extension '$name' is not installed in $home"
  # The gate asks whether this update INTRODUCES a wrapper. A home whose
  # composition was already acknowledged at install time must not re-answer for
  # it on every later update, so the pre-update receipt is read before the
  # manifest replaces it.
  had_wrap=$(jq -r '.hooks["launch-wrap"] // ""' "$RECEIPT")
  verify_links "$home" "$name" >&2 || die "extension '$name' is not in a state update can repair; see the lines above"
  pkg=$(jq -r '.source_path' "$RECEIPT")
  pkg=$(resolve_package "$pkg")
  read_manifest "$pkg"
  [ "$EXT_NAME" = "$name" ] || die "package at $pkg now declares name '$EXT_NAME', not '$name'"
  check_capabilities
  lint_package "$pkg" || die "extension '$name' now references paths outside its own package; update refuses"
  [ -n "$had_wrap" ] || launchwrap_gate "$home" "$allow_multi_wrap"
  assert_writable_home_dirs "$home"

  rows=$(mktemp "${TMPDIR:-/tmp}/fm-ext-links.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$rows'" EXIT
  link_rows "$home" "$pkg" > "$rows"

  # Retire links the new manifest no longer declares.
  while IFS= read -r link; do
    cut -f2 "$rows" | grep -Fxq -- "$link" && continue
    [ ! -L "$link" ] || rm -f "$link"
    exclude_remove "$home" "$link"
  done < <(jq -r '.links[].path' "$RECEIPT")

  while IFS=$'\t' read -r _kind link target _sha; do
    link_place "$link" "$target"
    exclude_add "$home" "$link"
  done < "$rows"
  write_receipt "$home" "$pkg" "$rows"
  rm -f "$rows"
  trap - EXIT
  printf 'updated: %s %s in %s; home-owned config and state untouched\n' "$EXT_NAME" "$EXT_VERSION" "$home"
}

cmd_uninstall() {
  parse_home_and_rest "$@"
  local home=$PARSED_HOME name='' purge=false force=false arg
  for arg in "${PARSED_REST[@]+"${PARSED_REST[@]}"}"; do
    case "$arg" in
      --purge) purge=true ;;
      --force) force=true ;;
      -*) die "uninstall: unknown flag $arg" ;;
      *) [ -z "$name" ] || die "uninstall takes exactly one extension name"; name=$arg ;;
    esac
  done
  [ -n "$name" ] || die "uninstall requires an extension name"
  ext_name_valid "$name" \
    || die "extension name must match [a-z0-9-]+ and must not start with '-': '$name'"
  # --force is the operator's escape hatch, so removal must not require reading
  # the very record that broke: an unreadable receipt is exactly the state the
  # spawn-time refusal tells them to clear.
  local have_receipt=true links
  if ! read_receipt "$home" "$name"; then
    have_receipt=false
    { [ "$force" = true ] && [ -d "$(receipt_dir "$home" "$name")" ]; } \
      || die "extension '$name' is not installed in $home"
  fi
  if [ "$force" != true ]; then
    verify_links "$home" "$name" >&2 \
      || die "extension '$name' does not match its install record; re-check with bin/fm-ext.sh status $name --home $home, then pass --force to clear the record anyway"
  fi

  local link
  if [ "$have_receipt" = true ]; then
    links=$(jq -r '.links[].path' "$RECEIPT")
  else
    # Whatever link paths survive in the unparseable file are still worth
    # retiring, and the skill link is derivable from the name alone, so the
    # forced removal always clears at least that one. Declared command links
    # are named by the package, not the extension, so a file too damaged to
    # yield any can leave those behind; the operator has to be told rather
    # than discovering it at reinstall.
    local claimed kept=''
    claimed=$(jq -r '.links[]?.path? // empty' "$(receipt_path "$home" "$name")" 2>/dev/null || true)
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      ownable_link_path "$home" "$name" "$link" || continue
      kept=$kept$link$'\n'
    done <<CLAIMED_EOF
$claimed
CLAIMED_EOF
    links=$(printf '%s\n%s\n' "$kept" "$(skill_link_path "$home" "$name")" | grep -v '^$' | LC_ALL=C sort -u)
    printf 'warning: %s has no readable install record in %s; its skill link%s was retired, but any command link it placed is named by its package and must be removed by hand if reinstalling reports an existing target path\n' \
      "$name" "$home" "$([ "$(printf '%s\n' "$links" | wc -l | tr -d '[:space:]')" -gt 1 ] && printf ' and the link paths still readable in the record' || printf '')" >&2
  fi
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    [ ! -L "$link" ] || rm -f "$link"
    exclude_remove "$home" "$link"
  done <<LINKS_EOF
$links
LINKS_EOF

  if [ "$purge" = true ] && [ "$have_receipt" != true ]; then
    purge=unknown
    printf 'warning: --purge could not run for %s because its install record does not name the config and state it owns; those are preserved\n' "$name" >&2
  fi
  if [ "$purge" = true ]; then
    local item
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      case "$item" in */*|..|.) die "config entry must be a bare file name: $item" ;; esac
      [ ! -L "$home/config/$item" ] || die "config path must not be a symlink: $home/config/$item"
      rm -f "$home/config/$item"
    done < <(jq -r '.config[]' "$RECEIPT")
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      case "$item" in */*|..|.) die "state entry must be a bare directory name: $item" ;; esac
      [ ! -L "$home/state/$item" ] || die "state path must not be a symlink: $home/state/$item"
      rm -rf "${home:?}/state/$item"
    done < <(jq -r '.state[]' "$RECEIPT")
  fi

  rm -rf "$(receipt_dir "$home" "$name")"
  printf 'uninstalled: %s from %s; home-owned config and state %s\n' \
    "$name" "$home" "$([ "$purge" = true ] && printf removed || printf preserved)"
}

cmd_list() {
  parse_home_and_rest "$@"
  [ "$PARSED_REST_COUNT" -eq 0 ] || die "list accepts only --home"
  local home=$PARSED_HOME name
  while IFS= read -r name; do
    read_receipt "$home" "$name" || { printf '%s\t?\tunreadable install record\n' "$name"; continue; }
    jq -r '[.name, .version, .source_path] | @tsv' "$RECEIPT"
  done < <(installed_names "$home")
}

cmd_triggers() {
  parse_home_and_rest "$@"
  [ "$PARSED_REST_COUNT" -eq 0 ] || die "triggers accepts only --home"
  local home=$PARSED_HOME name
  while IFS= read -r name; do
    read_receipt "$home" "$name" || continue
    jq -r '"- " + .name + " - " + .trigger' "$RECEIPT"
  done < <(installed_names "$home")
}

cmd_hooks() {
  parse_home_and_rest "$@"
  [ "$PARSED_REST_COUNT" -eq 1 ] || die "hooks requires exactly one hook kind"
  local home=$PARSED_HOME kind=${PARSED_REST[0]} name hook pkg reg
  while IFS= read -r name; do
    # A registered hook that cannot be run is reported, not skipped. Silently
    # dropping it would make a broken installation indistinguishable from an
    # extension that deliberately contributes nothing, and the caller could
    # never tell the difference. The third column carries that verdict. An
    # unreadable receipt is a different class - it hides WHICH hooks the
    # extension registers, so the row says exactly that and leaves each caller
    # to decide what an unknowable registration means for it, rather than
    # claiming a registration this command could not read. It is only reported
    # under the kinds whose registration is actually in doubt: the separate
    # registration record answers that question when it survives, and an
    # extension that demonstrably registers no hook of this kind is no
    # different here from one that was never installed.
    if ! read_receipt "$home" "$name"; then
      reg=0
      read_registration "$home" "$name" "$kind" || reg=$?
      [ "$reg" -ne 1 ] || continue
      printf '%s\t%s\t%s\n' "$name" "$(receipt_path "$home" "$name")" \
        "receipt-unreadable"
      continue
    fi
    backfill_registration "$home" "$name" "$RECEIPT"
    hook=$(jq -r --arg k "$kind" '.hooks[$k] // ""' "$RECEIPT")
    [ -n "$hook" ] || continue
    pkg=$(jq -r '.source_path' "$RECEIPT")
    case "$hook" in
      /*|*..*) printf '%s\t%s\t%s\n' "$name" "$pkg/$hook" "not package-relative" ;;
      *)
        if [ ! -e "$pkg/$hook" ]; then
          printf '%s\t%s\t%s\n' "$name" "$pkg/$hook" "missing"
        elif [ ! -x "$pkg/$hook" ]; then
          printf '%s\t%s\t%s\n' "$name" "$pkg/$hook" "not executable"
        else
          printf '%s\t%s\t%s\n' "$name" "$pkg/$hook" "ok"
        fi
        ;;
    esac
  done < <(hook_enum_names "$home" "$kind")
}

status_one() {
  local home=$1 name=$2 rc=0 bytes skill trigger digest total pkg
  if ! read_receipt "$home" "$name"; then
    printf 'not-installed: %s in %s\n' "$name" "$home"
    return 1
  fi
  verify_links "$home" "$name" || rc=3
  verify_excludes "$home" "$name" || rc=3
  pkg=$(jq -r '.source_path' "$RECEIPT")
  bytes=$(file_bytes "$pkg/SKILL.md")
  skill=$(est_tokens "$bytes")
  trigger=$(est_tokens "$(jq -r '.trigger' "$RECEIPT" | wc -c | tr -d '[:space:]')")
  if [ -n "$(jq -r '.hooks["session-start"] // ""' "$RECEIPT")" ]; then
    digest=$(est_tokens "$FM_EXT_DIGEST_BYTE_CAP")
  else
    digest=0
  fi
  total=$((skill + trigger + digest))
  if [ "$rc" -eq 0 ]; then
    printf 'ok: %s %s in %s\n' "$name" "$(jq -r '.version' "$RECEIPT")" "$home"
  fi
  printf 'context: %s skill=%s trigger=%s digest_cap=%s total=%s estimated tokens\n' \
    "$name" "$skill" "$trigger" "$digest" "$total"
  FM_EXT_STATUS_TOTAL=$((${FM_EXT_STATUS_TOTAL:-0} + total))
  return "$rc"
}

cmd_status() {
  parse_home_and_rest "$@"
  [ "$PARSED_REST_COUNT" -le 1 ] || die "status takes at most one extension name"
  local home=$PARSED_HOME rc=0 name one=
  [ "$PARSED_REST_COUNT" -eq 0 ] || one=${PARSED_REST[0]}
  FM_EXT_STATUS_TOTAL=0
  if [ -n "$one" ]; then
    status_one "$home" "$one" || rc=$?
  else
    while IFS= read -r name; do
      status_one "$home" "$name" || { [ "$?" -eq 1 ] || rc=3; }
    done < <(installed_names "$home")
  fi
  # Absent-and-enabled: a home that declares it needs an extension and does not
  # have it must refuse, by name, rather than run on quietly without it.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -z "$one" ] || [ "$one" = "$name" ] || continue
    if ! read_receipt "$home" "$name"; then
      printf 'EXT_MISSING: %s is listed in %s/config/ext-required but is not installed here; install it with bin/fm-ext.sh install <package> --home %s, or remove its line from %s/config/ext-required\n' \
        "$name" "$home" "$home" "$home"
      rc=4
    fi
  done < <(required_names "$home")
  printf 'context: aggregate total=%s estimated tokens (config/startup-memory-budget does not govern extension output)\n' \
    "${FM_EXT_STATUS_TOTAL:-0}"
  return "$rc"
}

cmd_lint() {
  local pkg
  [ $# -eq 1 ] || die "lint requires exactly one package path"
  pkg=$(resolve_package "$1")
  if lint_package "$pkg"; then
    printf 'ok: %s has no references escaping its package root\n' "$pkg"
    return 0
  fi
  printf 'fm-ext.sh: %s references paths outside its package root; a symlinked package resolves those lexically for the agent and physically for every script, so they work when read and fail when run\n' \
    "$pkg" >&2
  return 2
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || { usage; exit 2; }
  shift
  case "$cmd" in
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    status) cmd_status "$@" ;;
    list) cmd_list "$@" ;;
    triggers) cmd_triggers "$@" ;;
    hooks) cmd_hooks "$@" ;;
    lint) cmd_lint "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
