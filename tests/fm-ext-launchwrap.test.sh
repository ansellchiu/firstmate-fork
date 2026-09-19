#!/usr/bin/env bash
# tests/fm-ext-launchwrap.test.sh - the worker-launch wrapper seam
# (bin/fm-ext-hook-lib.sh's fm_ext_launchwrap_resolve, bin/fm-ext.sh's
# launch-wrap capability and composition gate, and bin/fm-spawn.sh's
# __EXTWRAP__ consumer).
#
# The property under test is the seam's two-sided contract. When no wrapper
# contributes, every verified launch is byte-identical to the unwrapped
# template - an extension home and a plain home must be indistinguishable at
# the launch line. When a wrapper contributes, its prefix is spliced verbatim
# immediately before the agent binary, after firstmate's env assignments, with
# every argument boundary intact; and a registered hook that cannot produce a
# usable prefix refuses the spawn BEFORE any task state exists, because
# launching a worker without the configured wrapper is the silent failure the
# seam exists to prevent.
#
# Coverage:
#   - no installed extension resolves to an empty prefix and no warning
#   - a valid wrapper's prefix is the hook's stdout, verbatim
#   - two wrappers compose in extension-name order, first-ordered outermost
#   - an installed-but-opted-out hook (empty stdout) contributes nothing
#   - a failing hook, a hanging hook, a malformed-config hook, multi-line
#     output, a missing trailing space, and an oversized prefix each refuse
#   - a registered hook that cannot run (missing file) refuses by name
#   - preflight is advisory: a failing preflight warns but proceeds, and an
#     opted-out launch runs no preflight at all
#   - the hook receives the spawn's facts (task id, kind, harness, worktree)
#   - a corrupt install record refuses only for an extension that registers a
#     launch-wrap hook; a non-wrapper in the same state never blocks a spawn
#   - a home-path precondition (symlinked, unreadable) resolves or warns rather
#     than refusing every spawn the home performs
#   - install and update both refuse a second launch-wrap extension unless
#     --allow-multiple-launch-wrap is passed, and the gate is scoped to
#     launch-wrap only
#   - end to end through the real fm-spawn.sh: byte identity with no wrapper,
#     exact insertion point with one, refusal with nothing half-created, raw
#     launch bypass, key-NAMES-only credential composition, and a secondmate
#     relaunch handing the hook the home the worker runs in
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/ext-fixture-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/ext-fixture-helpers.sh"

EXT="$ROOT/bin/fm-ext.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-ext-launchwrap)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# Short bounds so the timeout path is a test, not a wait, and a small prefix
# cap so the oversize path is a test, not a four-kilobyte heredoc. Both are
# read by bin/fm-ext-hook-lib.sh when this file sources it below.
export FM_EXT_HOOK_TIMEOUT_SECONDS=2
export FM_EXT_HOOK_BYTE_CAP=256
# shellcheck source=bin/fm-ext-hook-lib.sh
. "$ROOT/bin/fm-ext-hook-lib.sh"

# wrap_case <name> <ext-name> [hook-script]: build a package + home, optionally
# declaring a launch-wrap hook with the given script text. Echoes
# "<pkg>|<home>". Empty hook-script leaves the manifest without launch-wrap.
wrap_case() {  # <name> <ext-name> [hook-script]
  local name=$1 ext=$2 script=${3:-} base pkg home
  base="$TMP_ROOT/$name"
  pkg="$base/exts/$ext"
  home="$base/home"
  mkdir -p "$base/exts" "$home" "$home/state" "$home/config"
  fm_ext_fixture "$pkg" "$ext"
  [ -z "$script" ] || fm_ext_fixture_add_launchwrap "$pkg" "$script"
  fm_ext_home "$home" >/dev/null
  printf '%s|%s\n' "$pkg" "$home"
}

install_case() {  # <pkg> <home> [extra-install-arg...]
  local pkg=$1 home=$2
  shift 2
  "$EXT" install "$pkg" --home "$home" "$@" >/dev/null 2>&1 \
    || fail "installing the fixture extension failed"
}

# resolve_one <home> <task-id> <kind> <harness> <worktree>: run the resolver
# through the real enumeration path. Sets RESOLVED_RC, FM_EXT_LAUNCHWRAP_PREFIX,
# FM_EXT_LAUNCHWRAP_ERROR, and FM_EXT_LAUNCHWRAP_WARN in the caller.
resolve_one() {  # <home> <task-id> <kind> <harness> <worktree>
  local home=$1
  FM_EXT_LAUNCHWRAP_PREFIX=
  FM_EXT_LAUNCHWRAP_ERROR=
  FM_EXT_LAUNCHWRAP_WARN=
  fm_ext_launchwrap_resolve "$home" "$ROOT" "${2:-t1}" "${3:-ship}" "${4:-claude}" "${5:-}" \
    && RESOLVED_RC=0 || RESOLVED_RC=$?
}

# --- resolution: absent, valid, composed, opted out -------------------------

t=$(wrap_case absent hello-ext)
IFS='|' read -r pkg home <<< "$t"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] || fail "a home with no extensions must resolve, got $RESOLVED_RC"
[ -z "$FM_EXT_LAUNCHWRAP_PREFIX" ] || fail "no extensions must mean an empty prefix"
[ -z "$FM_EXT_LAUNCHWRAP_WARN" ] || fail "no extensions must mean no preflight warning"
pass "a home with no launch-wrap extension resolves to an empty prefix and no warning"

t=$(wrap_case valid wrap-ext "printf \"'%s' hold -- \\n\" \"\$FM_EXT_DIR/wrapper\"")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] || fail "a valid wrapper must resolve, got $RESOLVED_RC: $FM_EXT_LAUNCHWRAP_ERROR"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "'$pkg/wrapper' hold -- " ] \
  || fail "the prefix must be the hook's stdout verbatim minus one trailing newline, got: $FM_EXT_LAUNCHWRAP_PREFIX"
pass "a valid wrapper contributes its stdout as the prefix"

t=$(wrap_case composed a-wrap "printf 'first -- \n'")
IFS='|' read -r pkg_a home <<< "$t"
fm_ext_fixture_add_launchwrap "$pkg_a" "printf 'first -- \n'"
base="$TMP_ROOT/composed"
pkg_b="$base/exts/b-wrap"
fm_ext_fixture "$pkg_b" b-wrap
fm_ext_fixture_add_launchwrap "$pkg_b" "printf 'second -- \n'"
install_case "$pkg_b" "$home"
install_case "$pkg_a" "$home" --allow-multiple-launch-wrap
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] || fail "composed wrappers must resolve, got $RESOLVED_RC: $FM_EXT_LAUNCHWRAP_ERROR"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "first -- second -- " ] \
  || fail "prefixes must concatenate in extension-name order, got: $FM_EXT_LAUNCHWRAP_PREFIX"
pass "two wrappers compose in extension-name order, first-ordered outermost"

t=$(wrap_case optedout quiet-ext "exit 0")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] || fail "an opted-out hook is healthy, got $RESOLVED_RC"
[ -z "$FM_EXT_LAUNCHWRAP_PREFIX" ] || fail "an opted-out hook must contribute no prefix"
pass "an installed-but-opted-out hook contributes nothing and costs nothing"

# --- resolution: every refusal shape ----------------------------------------

refuse_case() {  # <name> <ext-name> <hook-script> <expected-fragment>
  local name=$1 ext=$2 script=$3 fragment=$4 t pkg home
  t=$(wrap_case "$name" "$ext" "$script")
  IFS='|' read -r pkg home <<< "$t"
  install_case "$pkg" "$home"
  resolve_one "$home"
  [ "$RESOLVED_RC" -eq 1 ] || fail "$name must refuse the spawn, got rc $RESOLVED_RC"
  assert_contains "$FM_EXT_LAUNCHWRAP_ERROR" "$fragment" "$name refusal names the cause"
}

refuse_case fails wrap-ext \
  "printf 'wrapper is broken\n' >&2
exit 3" \
  "failed (exit 3): wrapper is broken"
pass "a failing hook refuses the spawn naming the extension, exit code, and first stderr line"

refuse_case hangs wrap-ext \
  "sleep 300 &
wait" \
  "timed out after 2s"
pass "a hanging hook is killed at the bound and refuses the spawn"

refuse_case malformed wrap-ext \
  "cfg=\"\$FM_HOME/config/wrap.json\"
jq -e . \"\$cfg\" >/dev/null 2>&1 || { printf 'wrapper configuration is not valid JSON: %s\n' \"\$cfg\" >&2; exit 4; }
exit 0" \
  "failed (exit 4): wrapper configuration is not valid JSON"
pass "a hook whose configuration is malformed refuses with the hook's own diagnostic"

refuse_case multiline wrap-ext \
  "printf 'one\ntwo -- \n'" \
  "multi-line"
pass "multi-line prefix output refuses rather than corrupting the launch line"

refuse_case nospace wrap-ext \
  "printf '\"\$FM_EXT_DIR/wrapper\" --'" \
  "does not end in a space"
pass "a prefix without its trailing space refuses rather than fusing with the binary"

refuse_case oversize wrap-ext \
  "for _ in \$(seq 1 300); do printf 'x'; done" \
  "produced a 300-byte prefix; the cap is 256 bytes"
pass "an oversized prefix refuses and reports the hook's real size, not the read bound"

# A first line of exactly the cap followed by more output is the case a
# cap-sized read cannot tell apart from a compliant prefix: it must refuse
# rather than splice a silently truncated shell fragment into the launch line.
refuse_case exactly-at-cap wrap-ext \
  "for _ in \$(seq 1 255); do printf 'x'; done; printf ' \n'; printf 'JUNK\n'" \
  "produced a 261-byte prefix"
pass "a first line of exactly the cap followed by more output refuses instead of being truncated"

t=$(wrap_case unrunnable wrap-ext "exit 0")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
rm "$pkg/hooks/launch-wrap"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 1 ] || fail "a registered-but-missing hook must refuse, got rc $RESOLVED_RC"
assert_contains "$FM_EXT_LAUNCHWRAP_ERROR" "registers launch-wrap but its hook is missing" \
  "the unrunnable-hook refusal names the receipt's declaration and the verdict"
pass "a registered hook that cannot run refuses by name, not silently"

# An unreadable install record matters only for an extension that actually
# registers a launch-wrap hook. The registration record beside the receipt
# still answers that question, so a wrapper whose receipt is corrupt refuses
# the spawn while a session-start-only extension in the same state has no
# effect on this seam at all.
t=$(wrap_case unreadable-receipt-wrap wrap-ext "printf 'w -- \n'")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
printf 'not json\n' > "$home/state/ext/wrap-ext/install.json"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 1 ] || fail "a wrapper's unreadable install record must refuse, got rc $RESOLVED_RC"
assert_contains "$FM_EXT_LAUNCHWRAP_ERROR" "unreadable or schema-mismatched" \
  "the refusal did not name the unreadable install record"
assert_not_contains "$FM_EXT_LAUNCHWRAP_ERROR" "registers launch-wrap but" \
  "the refusal claimed a launch-wrap registration it could not read"
pass "a launch-wrap extension whose install record is unreadable refuses the spawn"

t=$(wrap_case unreadable-receipt-plain plain-ext)
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
printf '{"schema":"firstmate.ext.install.v2"}\n' > "$home/state/ext/plain-ext/install.json"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] \
  || fail "a non-wrapper's unreadable install record must not block a spawn: $FM_EXT_LAUNCHWRAP_ERROR"
[ -z "$FM_EXT_LAUNCHWRAP_PREFIX" ] || fail "a non-wrapper must contribute no prefix"
pass "an extension that registers no launch-wrap hook cannot block a spawn with a corrupt receipt"

# A receipt that was deleted outright is the same fact as one that cannot be
# parsed - core cannot read the install record - and the surviving registration
# record still says this home installed a wrapper, so it refuses rather than
# launching unwrapped and silently.
t=$(wrap_case deleted-receipt-wrap wrap-ext "printf 'w -- \n'")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
rm "$home/state/ext/wrap-ext/install.json"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 1 ] \
  || fail "a deleted install record beside a launch-wrap registration must refuse, got rc $RESOLVED_RC"
assert_contains "$FM_EXT_LAUNCHWRAP_ERROR" "unreadable or schema-mismatched" \
  "the deleted-receipt refusal did not name the unreadable install record"
[ -z "$FM_EXT_LAUNCHWRAP_PREFIX" ] || fail "a refused resolution must contribute no prefix"
# Narrowly scoped: the other commands still treat a receipt-less directory as
# not installed, so list and triggers are unchanged.
out=$("$EXT" list --home "$home")
assert_not_contains "$out" 'wrap-ext' "list must keep ignoring a receipt-less directory"
pass "a deleted install record beside a launch-wrap registration refuses the spawn"

# A receipt-less directory that never registered launch-wrap is not evidence of
# a wrapper, so it must not refuse every spawn this home performs.
t=$(wrap_case deleted-receipt-plain plain-ext)
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
rm "$home/state/ext/plain-ext/install.json"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] \
  || fail "a non-wrapper's deleted install record must not block a spawn: $FM_EXT_LAUNCHWRAP_ERROR"
pass "a deleted install record for a non-wrapper cannot block a spawn"

# The registration record is what makes a receipt-less wrapper fail closed, and
# an extension installed before the record existed carries none - so losing its
# receipt would silently stop wrapping. Enumeration backfills the record from a
# still-readable receipt, closing that window at the first spawn.
t=$(wrap_case backfill-registration wrap-ext "printf 'w -- \n'")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
rm "$home/state/ext/wrap-ext/registered-hooks"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] || fail "a readable receipt must still resolve: $FM_EXT_LAUNCHWRAP_ERROR"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "w -- " ] || fail "the wrapper must still contribute its prefix"
rm "$home/state/ext/wrap-ext/install.json"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 1 ] \
  || fail "a pre-record install that loses its receipt must fail closed once enumeration has backfilled the record"
pass "enumeration backfills a missing registration record so a lost receipt still fails closed"

# The refusal names a recovery, and that recovery has to work in exactly the
# state that produced it: update cannot repair a record it cannot read, so
# uninstall --force is the escape hatch and it must not need the broken record.
t=$(wrap_case force-uninstall-corrupt wrap-ext "printf 'w -- \n'")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
link="$home/.agents/skills/wrap-ext"
[ -e "$link" ] || link=$(jq -r '.links[0].path' "$home/state/ext/wrap-ext/install.json")
printf 'not json\n' > "$home/state/ext/wrap-ext/install.json"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 1 ] || fail "the corrupt receipt must refuse before recovery is exercised"
assert_contains "$FM_EXT_LAUNCHWRAP_ERROR" "uninstall wrap-ext --home $home --force" \
  "the refusal must name the recovery that actually works in this state"
out=$("$EXT" update wrap-ext --home "$home" 2>&1) \
  && fail "update must stay receipt-gated"
out=$("$EXT" uninstall wrap-ext --home "$home" --force 2>&1) \
  || fail "uninstall --force must clear an unreadable install record: $out"
assert_absent "$home/state/ext/wrap-ext" "uninstall --force must remove the extension directory"
assert_absent "$home/.agents/skills/wrap-ext" \
  "the skill link is derivable from the name, so the forced removal must retire it"
assert_contains "$out" 'must be removed by hand' \
  "the forced removal must say which leftovers it could not identify without the record"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] \
  || fail "after the named recovery the home must spawn again: $FM_EXT_LAUNCHWRAP_ERROR"
# A command link is named by the package, not the extension, so an unreadable
# record cannot point at it; install says exactly which path is in the way.
if out=$("$EXT" install "$pkg" --home "$home" 2>&1); then
  leftover=''
else
  leftover=${out##*: }
  assert_contains "$out" 'already exists without this extension' \
    "a leftover link must be reported as such, not as some other failure"
  [ ! -L "$leftover" ] || rm -f "$leftover"
  out=$("$EXT" install "$pkg" --home "$home" 2>&1) \
    || fail "the home must be reinstallable once the named leftover is cleared: $out"
fi
assert_contains "$out" 'installed: wrap-ext' "the reinstall must complete"
pass "uninstall --force clears an unreadable install record and restores the home"

# The home path itself is decided before any extension state is read, so a home
# reached through a symlink resolves its wrappers normally rather than failing
# an enumeration precondition and refusing every spawn.
t=$(wrap_case symlinked-home wrap-ext "printf 'w -- \n'")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
ln -s "$home" "$TMP_ROOT/symlinked-home/home-link"
resolve_one "$TMP_ROOT/symlinked-home/home-link"
[ "$RESOLVED_RC" -eq 0 ] \
  || fail "a symlinked home must resolve, not refuse: $FM_EXT_LAUNCHWRAP_ERROR"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "w -- " ] \
  || fail "a symlinked home must resolve the same wrapper, got: $FM_EXT_LAUNCHWRAP_PREFIX"
pass "a home reached through a symlink resolves its wrapper instead of refusing every spawn"

# A refusal names a recovery command, and resolve_home refuses a symlinked home
# outright - so in the very case above, a refusal that quoted the logical path
# would print a command that dies before it starts. The printed recovery has to
# run, so the test runs exactly the command the refusal prints.
t=$(wrap_case symlinked-home-refusal wrap-ext "printf 'w -- \n'")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
home_link="$TMP_ROOT/symlinked-home-refusal/home-link"
ln -s "$home" "$home_link"
printf 'not json\n' > "$home/state/ext/wrap-ext/install.json"
resolve_one "$home_link"
[ "$RESOLVED_RC" -eq 1 ] || fail "a corrupt receipt reached through a symlinked home must refuse"
recovery=${FM_EXT_LAUNCHWRAP_ERROR#*(bin/fm-ext.sh }
recovery=${recovery%%)*}
# shellcheck disable=SC2086 # the printed command is deliberately re-split here.
out=$("$EXT" $recovery 2>&1) \
  || fail "the recovery the refusal prints must run: 'bin/fm-ext.sh $recovery' failed with: $out"
assert_absent "$home/state/ext/wrap-ext" "the printed recovery must actually remove the extension"
resolve_one "$home_link"
[ "$RESOLVED_RC" -eq 0 ] || fail "after the printed recovery the home must spawn again"
pass "a refusal names a recovery command that runs even when the home is reached through a symlink"

# A home that cannot be read at all is not evidence a wrapper exists either: it
# warns and leaves the launch unwrapped rather than refusing.
resolve_one "$TMP_ROOT/symlinked-home/no-such-home"
[ "$RESOLVED_RC" -eq 0 ] || fail "an unreadable home must not refuse the spawn"
[ -z "$FM_EXT_LAUNCHWRAP_PREFIX" ] || fail "an unreadable home must contribute no prefix"
assert_contains "$FM_EXT_LAUNCHWRAP_WARN" "not a readable directory" \
  "an unreadable home must warn observably about the precondition"
pass "a home-path precondition warns and proceeds unwrapped rather than refusing"

# --- resolution: preflight is advisory and scoped ---------------------------

t=$(wrap_case preflight wrap-ext \
  "case \"\${1:-}\" in
    prefix) printf 'wrapped -- \n' ;;
    preflight) printf 'vault unreachable\n' >&2; exit 5 ;;
  esac")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] || fail "a failing preflight must not refuse, got $RESOLVED_RC: $FM_EXT_LAUNCHWRAP_ERROR"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "wrapped -- " ] || fail "the prefix must survive a failing preflight"
assert_contains "$FM_EXT_LAUNCHWRAP_WARN" "preflight failed (exit 5): vault unreachable" \
  "the advisory preflight warning names the extension and its diagnostic"
pass "a failing preflight warns and the spawn proceeds, because the postcondition owns liveness"

t=$(wrap_case preflight-scoped quiet-ext \
  "case \"\${1:-}\" in
    prefix) exit 0 ;;
    preflight) touch \"\$FM_EXT_DIR/preflight-ran\"; exit 0 ;;
  esac")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
resolve_one "$home"
[ "$RESOLVED_RC" -eq 0 ] || fail "the opted-out case must resolve"
[ ! -e "$pkg/preflight-ran" ] || fail "an opted-out launch must not run the hook's preflight"
pass "an opted-out launch runs no preflight"

# --- resolution: the hook receives the spawn's facts ------------------------

t=$(wrap_case facts wrap-ext \
  "env | grep '^FM_' | sort > \"\$FM_EXT_DIR/spawn-facts\"
printf 'seen -- \n'")
IFS='|' read -r pkg home <<< "$t"
install_case "$pkg" "$home"
fm_ext_launchwrap_resolve "$home" "$ROOT" "task-f1" "scout" "pi-signed" "/tmp/wt-path" || \
  fail "the facts case must resolve"
grep -qx 'FM_TASK_ID=task-f1' "$pkg/spawn-facts" || fail "the hook must receive FM_TASK_ID"
grep -qx 'FM_TASK_KIND=scout' "$pkg/spawn-facts" || fail "the hook must receive FM_TASK_KIND"
grep -qx 'FM_HARNESS=pi-signed' "$pkg/spawn-facts" || fail "the hook must receive FM_HARNESS"
grep -qx 'FM_WORKTREE=/tmp/wt-path' "$pkg/spawn-facts" || fail "the hook must receive FM_WORKTREE"
grep -qx 'FM_EXT_NAME=wrap-ext' "$pkg/spawn-facts" || fail "the hook must receive FM_EXT_NAME"
grep -qx 'FM_EXT_PHASE=launch' "$pkg/spawn-facts" || fail "the hook must receive FM_EXT_PHASE"
pass "the hook receives the spawn's facts: task id, kind, harness, worktree, extension name"

# --- install: the composition gate ------------------------------------------

t=$(wrap_case gate first-wrap "printf 'w -- \n'")
IFS='|' read -r pkg_first home <<< "$t"
base="$TMP_ROOT/gate"
pkg_second="$base/exts/second-wrap"
fm_ext_fixture "$pkg_second" second-wrap
fm_ext_fixture_add_launchwrap "$pkg_second" "printf 'w2 -- \n'"
pkg_plain="$base/exts/plain-ext"
fm_ext_fixture "$pkg_plain" plain-ext
install_case "$pkg_first" "$home"
out=$("$EXT" install "$pkg_second" --home "$home" 2>&1) \
  && fail "installing a second launch-wrap extension must refuse"
assert_contains "$out" '--allow-multiple-launch-wrap' \
  "the composition refusal names the acknowledgement flag"
assert_absent "$home/state/ext/second-wrap" "the refused install leaves no receipt behind"
out=$("$EXT" install "$pkg_second" --home "$home" --allow-multiple-launch-wrap)
assert_contains "$out" 'installed: second-wrap' "the acknowledgement installs the second wrapper"
out=$("$EXT" install "$pkg_plain" --home "$home")
assert_contains "$out" 'installed: plain-ext' \
  "the gate is scoped to launch-wrap: a plain extension installs freely"
pass "install refuses a second launch-wrap extension without --allow-multiple-launch-wrap"

# Reinstalling an already-installed extension is an already-installed error,
# not a composition one, even when another wrapper is installed alongside it.
out=$("$EXT" install "$pkg_first" --home "$home" 2>&1) \
  && fail "reinstalling an already-installed extension must refuse"
assert_contains "$out" "already installed" \
  "the reinstall refusal did not name the real cause"
assert_not_contains "$out" '--allow-multiple-launch-wrap' \
  "the reinstall refusal misreported itself as a composition refusal"
pass "reinstalling a launch-wrap extension reports already-installed, not the composition gate"

# Update runs the gate only when the update introduces a launch-wrap
# registration: a package that newly registers the hook takes the same
# acknowledgement through update as it would through install.
t=$(wrap_case update-gate first-wrap "printf 'w -- \n'")
IFS='|' read -r pkg_w home <<< "$t"
base="$TMP_ROOT/update-gate"
pkg_late="$base/exts/late-wrap"
fm_ext_fixture "$pkg_late" late-wrap
install_case "$pkg_w" "$home"
install_case "$pkg_late" "$home"
fm_ext_fixture_add_launchwrap "$pkg_late" "printf 'late -- \n'"
out=$("$EXT" update late-wrap --home "$home" 2>&1) \
  && fail "an update that introduces a second launch-wrap extension must refuse"
assert_contains "$out" '--allow-multiple-launch-wrap' \
  "the update composition refusal names the acknowledgement flag"
resolve_one "$home"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "w -- " ] \
  || fail "the refused update must not have registered a second wrapper, got: $FM_EXT_LAUNCHWRAP_PREFIX"
out=$("$EXT" update late-wrap --home "$home" --allow-multiple-launch-wrap)
assert_contains "$out" 'updated: late-wrap' "the acknowledgement lets the update through"
resolve_one "$home"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "w -- late -- " ] \
  || fail "the acknowledged update must compose both wrappers, got: $FM_EXT_LAUNCHWRAP_PREFIX"
pass "update runs the same composition gate install does"

# The gate reads other extensions' receipts to count wrappers; update reads its
# OWN receipt afterwards to retire links the new manifest dropped. If the gate
# leaves the shared receipt handle pointing at another extension, update
# retires that extension's links instead - so the bystander must survive intact.
out=$("$EXT" status first-wrap --home "$home" 2>&1) \
  || fail "the acknowledged update destroyed the other wrapper's install: $out"
assert_contains "$out" 'ok: first-wrap' \
  "the other launch-wrap extension must be untouched by an update it only gated"
pass "the composition gate leaves the other extension's links intact through update"

# Updating an extension that is the home's only wrapper is not a second one.
t=$(wrap_case update-gate-single only-wrap "printf 'only -- \n'")
IFS='|' read -r pkg_only home_only <<< "$t"
install_case "$pkg_only" "$home_only"
out=$("$EXT" update only-wrap --home "$home_only")
assert_contains "$out" 'updated: only-wrap' \
  "updating the home's only wrapper must not trip the composition gate"
pass "the composition gate does not count the extension being updated against itself"

# The gate asks whether an update INTRODUCES a wrapper. Once a two-wrapper home
# has been acknowledged at install time, updating either wrapper changes no hook
# state, so it must not demand the acknowledgement again - forever, on every
# later update, recording nothing.
t=$(wrap_case update-gate-acknowledged first-wrap "printf 'first -- \n'")
IFS='|' read -r pkg_ack home_ack <<< "$t"
base="$TMP_ROOT/update-gate-acknowledged"
pkg_ack2="$base/exts/second-wrap"
fm_ext_fixture "$pkg_ack2" second-wrap
fm_ext_fixture_add_launchwrap "$pkg_ack2" "printf 'second -- \n'"
install_case "$pkg_ack" "$home_ack"
install_case "$pkg_ack2" "$home_ack" --allow-multiple-launch-wrap
out=$("$EXT" update first-wrap --home "$home_ack" 2>&1) \
  || fail "updating a wrapper in an already-acknowledged home must not re-demand the flag: $out"
assert_contains "$out" 'updated: first-wrap' "the update must complete"
out=$("$EXT" update second-wrap --home "$home_ack" 2>&1) \
  || fail "updating the other wrapper must not re-demand the flag either: $out"
resolve_one "$home_ack"
[ "$FM_EXT_LAUNCHWRAP_PREFIX" = "first -- second -- " ] \
  || fail "the acknowledged composition must survive both updates, got: $FM_EXT_LAUNCHWRAP_PREFIX"
pass "updating an already-acknowledged multi-wrapper home does not re-demand the flag"

# --- end to end through the real fm-spawn.sh --------------------------------

# Fake tmux that records every send-keys payload, so assertions run against the
# launch line firstmate actually delivers, and markers for window creation.
make_fakebin() {  # <dir> <window-name>
  local dir=$1 window=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) printf '%s\n' "/dev/null/nonexistent"; exit 0 ;;
  *"#{pane_current_command}"*)
    cat "$dir/pane-command" 2>/dev/null || printf 'zsh\n'
    exit 0
    ;;
esac
case "\${1:-}" in
  list-windows) [ -f "$dir/window-created" ] && printf '%s\n' "$window"; exit 0 ;;
  new-window) : > "$dir/window-created"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|kill-window) exit 0 ;;
  send-keys)
    shift
    printf '%s\n' "\$*" >> "$dir/launch-lines"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
# fm_run_timed invokes GNU timeout as: timeout -k 1 <seconds> bash -c ...
# Drop both flags and run unbounded - the spawn cases here have no hanging
# hook; the bound itself is covered at library level with the real mechanism.
if [ "${1:-}" = -k ]; then shift 2; fi
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# spawn_case <name> <id> <hook-script|''> : build a home (+ optional installed
# launch-wrap extension), project, and worktree trio. The id is a parameter so
# byte-identity cases can share one, leaving only the home path to mask.
# Echoes "<home>|<proj>|<wt>|<fakebin>|<case-dir>|<id>".
spawn_case() {  # <name> <id> <hook-script>
  local name=$1 id=$2 script=$3 case_dir home proj wt fakebin pkg
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake" "fm-$id")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the launch-wrap seam for $id.

## Firstmate spec
Keep the fixture brief minimal.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  if [ -n "$script" ]; then
    pkg="$case_dir/exts/wrap-ext"
    mkdir -p "$case_dir/exts"
    fm_ext_fixture "$pkg" wrap-ext
    fm_ext_fixture_add_launchwrap "$pkg" "$script"
    "$EXT" install "$pkg" --home "$home" >/dev/null 2>&1 \
      || fail "installing the spawn-case extension failed"
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$case_dir" "$id"
}

run_spawn() {  # <home> <wt> <fakebin> <id> <proj> [extra-env...]
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  shift 5
  env -u FM_AV_INJECT -u FM_AV_INJECT_KEYS \
    HOME="$home" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" "$@" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

launch_line() {  # <case-dir>
  grep 'dangerously-skip-permissions' "$1/fake/launch-lines" 2>/dev/null | tail -n 1
}

rec=$(spawn_case plain seam-z1 '')
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
[ "$rc" -eq 0 ] || fail "a plain spawn must succeed, got $rc: $out"
assert_contains "$out" "spawned $CASE_ID" "the plain home must report the spawn"
BASE_LINE=$(launch_line "$CASE_DIR")
[ -n "$BASE_LINE" ] || fail "the plain spawn must deliver a claude launch line"
pass "a home with no extension spawns and delivers the unwrapped launch line"

rec=$(spawn_case silent seam-z1 "exit 0")
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
[ "$rc" -eq 0 ] || fail "an opted-out extension home must spawn, got $rc: $out"
SILENT_LINE=$(launch_line "$CASE_DIR")
[ "$(printf '%s' "$SILENT_LINE" | sed "s|$HOME_DIR|HOME|g")" = \
  "$(printf '%s' "$BASE_LINE" | sed "s|$TMP_ROOT/spawn-plain/home|HOME|g")" ] \
  || { printf 'silent: %s\nbase:   %s\n' "$SILENT_LINE" "$BASE_LINE"; \
       fail "an installed-but-opted-out extension must leave the launch line byte-identical"; }
pass "an installed-but-opted-out extension leaves the delivered launch line byte-identical"

rec=$(spawn_case wrapped seam-z1 "printf \"'%s' hold -- \\n\" \"\$FM_EXT_DIR/wrapper\"")
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
[ "$rc" -eq 0 ] || fail "a wrapped spawn must succeed, got $rc: $out"
WRAP_LINE=$(launch_line "$CASE_DIR")
expected=$(printf '%s' "$BASE_LINE" \
  | sed "s|$TMP_ROOT/spawn-plain/home|$TMP_ROOT/spawn-wrapped/home|" \
  | sed "s|=0 claude |=0 '$CASE_DIR/exts/wrap-ext/wrapper' hold -- claude |")
[ "$WRAP_LINE" = "$expected" ] \
  || { printf 'wrapped: %s\nexpect:  %s\n' "$WRAP_LINE" "$expected"; \
       fail "the wrapper prefix must be spliced exactly between the env assignments and the binary"; }
assert_contains "$WRAP_LINE" "hold -- claude --dangerously-skip-permissions" \
  "the wrapper's argument boundary survives: -- then the binary with its own args"
pass "a contributing wrapper is spliced immediately before the binary, arguments intact"

rec=$(spawn_case refusing seam-z1 "printf 'wrapper is broken\n' >&2
exit 7")
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
[ "$rc" -ne 0 ] || fail "a failing wrapper must refuse the spawn"
assert_contains "$out" "extension 'wrap-ext'" "the refusal names the extension"
assert_contains "$out" "exit 7" "the refusal carries the hook's exit code"
[ -e "$CASE_DIR/fake/window-created" ] && fail "a refused spawn must not create the pane window"
[ -e "$HOME_DIR/state/$CASE_ID.meta" ] && fail "a refused spawn must not create the task record"
[ -e "$CASE_DIR/fake/launch-lines" ] && fail "a refused spawn must not deliver any launch text"
pass "a failing wrapper refuses before any task state exists: no window, no record, no launch"

rec=$(spawn_case rawbypass raw-z1 "printf 'wrapped -- \n'")
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
# The raw launch rides the third positional (harness slot), so this case calls
# fm-spawn directly instead of through run_spawn's fixed two-positional shape.
out=$(env -u FM_AV_INJECT -u FM_AV_INJECT_KEYS \
    HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" \
    FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05 \
    "$SPAWN" "$CASE_ID" "$PROJ_DIR" 'env FM_RAW_TEST=1 sleep 30' --mode no-mistakes --yolo off 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "a raw launch must spawn, got $rc: $out"
RAW_LINE=$(grep 'FM_RAW_TEST=1 sleep 30' "$CASE_DIR/fake/launch-lines" 2>/dev/null | tail -n 1)
[ -n "$RAW_LINE" ] || fail "the raw spawn must deliver its raw launch line: $out"
assert_not_contains "$RAW_LINE" "wrapped -- " \
  "the raw-adapter escape hatch carries no wrapper: injection applies to verified launches only"
pass "a raw launch command bypasses the seam by construction"

rec=$(spawn_case secrets seam-z1 "keys=\$(cat \"\$FM_EXT_DIR/keys.allow\")
printf 'av inject'
for k in \$keys; do printf ' +%s' \"\$k\"; done
printf ' -- \n'")
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<EOF
$rec
EOF
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
mkdir -p "$CASE_DIR/exts"
pkg="$CASE_DIR/exts/wrap-ext"
printf 'SEARCH_PROVIDER_KEY\n' > "$pkg/keys.allow"
# The secret's VALUE is genuinely within the hook's reach - it is exported into
# the spawn, so the hook inherits it - which is what makes the assertion below
# falsifiable: a wrapper path that composed values rather than names would put
# it on the launch line.
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$CASE_ID" "$PROJ_DIR" \
  SEARCH_PROVIDER_KEY=s3cr3t-vault-value \
  FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05); rc=$?
[ "$rc" -eq 0 ] || fail "a secret-composing wrapper must spawn, got $rc: $out"
assert_contains "$(launch_line "$CASE_DIR")" "av inject +SEARCH_PROVIDER_KEY -- claude" \
  "the launch line carries the key NAME composed in front of the binary"
assert_not_contains "$(launch_line "$CASE_DIR")" "s3cr3t-vault-value" \
  "no secret VALUE may enter the launch line or the wrapper path"
pass "credential composition carries key names only; the value never enters the seam"


# A secondmate relaunch runs in the home resolved for this spawn, not in the
# worktree the task record happens to name, so the hook must be told the path
# the worker will actually run in.
rec=$(spawn_case secondmate-relaunch seam-s1 \
  "printf '%s\n' \"\$FM_WORKTREE\" >> \"\$FM_EXT_DIR/wt-seen\"
printf 'w -- \n'")
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN CASE_DIR CASE_ID <<REC_EOF
$rec
REC_EOF
mkdir -p "$PROJ_DIR/state" "$PROJ_DIR/data" "$PROJ_DIR/config" "$PROJ_DIR/projects" "$PROJ_DIR/bin"
touch "$PROJ_DIR/AGENTS.md"
printf '%s\n' "$CASE_ID" > "$PROJ_DIR/.fm-secondmate-home"
printf 'claude\n' > "$HOME_DIR/config/secondmate-harness"
printf 'claude\n' > "$CASE_DIR/fake/pane-command"
PROJ_PHYS=$(cd "$PROJ_DIR" && pwd -P)
# A relaunch types the launch command into the existing idle pane, so this
# case's fake tmux takes the agent into the foreground on send-keys the way the
# real one does; the launch text itself is asserted by the cases above.
cat > "$FAKEBIN/tmux" <<TMUX_EOF
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) printf '%s\n' "/dev/null/nonexistent"; exit 0 ;;
  *"#{pane_current_command}"*)
    cat "$CASE_DIR/fake/pane-command" 2>/dev/null || printf 'zsh\n'
    exit 0
    ;;
esac
case "\${1:-}" in
  list-windows) [ -f "$CASE_DIR/fake/window-created" ] && printf '%s\n' "fm-$CASE_ID"; exit 0 ;;
  new-window) : > "$CASE_DIR/fake/window-created"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|kill-window|capture-pane) exit 0 ;;
  send-keys) printf 'claude\n' > "$CASE_DIR/fake/pane-command"; exit 0 ;;
esac
exit 0
TMUX_EOF
chmod +x "$FAKEBIN/tmux"
run_secondmate() {  # <pane-path> <spawn-arg...>
  local pane=$1
  shift
  env HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" FM_SPAWN_LAUNCH_WAIT=5 FM_SPAWN_LAUNCH_POLL=0.05 \
    "$SPAWN" "$CASE_ID" "$@" 2>&1
}
out=$(run_secondmate "$PROJ_PHYS" "$PROJ_DIR" --secondmate); rc=$?
[ "$rc" -eq 0 ] || fail "the secondmate spawn must succeed, got $rc: $out"
[ "$(tail -n 1 "$CASE_DIR/exts/wrap-ext/wt-seen")" = "$PROJ_PHYS" ] \
  || fail "a fresh secondmate spawn must hand the hook its home"

# The recorded worktree and the home resolved for the spawn diverge whenever the
# home supplied or registered for the task is not byte-identical to what the
# record names; the relaunch still runs in the home.
DECOY="$CASE_DIR/decoy-worktree"
mkdir -p "$DECOY"
sed "s|^worktree=.*|worktree=$DECOY|" "$HOME_DIR/state/$CASE_ID.meta" > "$CASE_DIR/meta.tmp"
mv "$CASE_DIR/meta.tmp" "$HOME_DIR/state/$CASE_ID.meta"
printf 'zsh\n' > "$CASE_DIR/fake/pane-command"
out=$(run_secondmate "$PROJ_PHYS" --relaunch); rc=$?
[ "$rc" -eq 0 ] || fail "the secondmate relaunch must succeed, got $rc: $out"
SEEN=$(tail -n 1 "$CASE_DIR/exts/wrap-ext/wt-seen")
[ "$SEEN" != "$DECOY" ] \
  || fail "the relaunch handed the hook the recorded worktree the worker never runs in"
[ "$SEEN" = "$PROJ_PHYS" ] \
  || fail "the relaunch must hand the hook the secondmate home, got '$SEEN'"
pass "a secondmate relaunch hands the hook the home the worker runs in"

pass "the worker-launch wrapper seam behaves"
