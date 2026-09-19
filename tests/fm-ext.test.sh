#!/usr/bin/env bash
# Behavioral coverage for the firstmate extension contract in bin/fm-ext.sh:
# the install/status/update/uninstall loop against a synthetic package, the
# loud failures for a stale receipt, a missing symlink, a lost per-clone
# exclude entry, and an absent-but-required extension, plus the `../` escape
# lint and the capability refusal.
set -u

# shellcheck source=tests/ext-fixture-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/ext-fixture-helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by fm-ext.sh)"; exit 0; }

EXT="$ROOT/bin/fm-ext.sh"
TMP_ROOT=$(fm_test_tmproot fm-ext)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# --- the full loop against a synthetic package -----------------------------
PKG="$TMP_ROOT/extrepo/extensions/hello-ext"
fm_ext_fixture "$PKG"
HOME_ONE=$(fm_ext_home "$TMP_ROOT/home-one")

out=$("$EXT" install "$PKG" --home "$HOME_ONE" --flagged)
assert_contains "$out" 'installed: hello-ext 1.0.0' "install reports the package name and version"
assert_contains "$out" 'next skill-registry scan' "install states that the skill is not invocable this instant"
assert_contains "$out" 'configured: --flagged' "install runs the declared guided configuration with its flags"
[ -L "$HOME_ONE/.agents/skills/hello-ext" ] || fail "install symlinks the package into the home's skills directory"
[ "$(readlink "$HOME_ONE/.agents/skills/hello-ext")" = "$PKG" ] || fail "the skill symlink points at the package"
[ -L "$HOME_ONE/bin/fm-hello-ext-report.sh" ] || fail "install symlinks each package-owned command into the home's bin"
assert_present "$HOME_ONE/state/ext/hello-ext/install.json" "install records a receipt"
assert_contains "$(cat "$HOME_ONE/.agents/skills/hello-ext/SKILL.md")" '# hello-ext' \
  "the symlinked skill reads through to the package"

# Nothing the installer wrote may show up as untracked dirt in the home.
dirt=$(git -C "$HOME_ONE" status --short)
assert_not_contains "$dirt" 'hello-ext' "install leaves the home's git status clean"
git -C "$HOME_ONE" check-ignore -q -- "$HOME_ONE/.agents/skills/hello-ext" \
  || fail "the per-clone exclude entry hides the skill symlink"
assert_grep '.agents/skills/hello-ext' "$HOME_ONE/.git/info/exclude" \
  "the exclude entry lands in the home's own per-clone exclude file"
assert_absent "$HOME_ONE/.gitignore" "install adds no tracked ignore line for the extension"

out=$("$EXT" status --home "$HOME_ONE")
assert_contains "$out" 'ok: hello-ext 1.0.0' "status reports a healthy installation"
assert_contains "$out" 'context: hello-ext skill=' "status reports the extension's estimated context cost"
assert_contains "$out" 'digest_cap=' "status prices the session-start hook's capped digest contribution"
assert_contains "$out" 'context: aggregate total=' "status reports the aggregate extension context cost"
assert_contains "$out" 'startup-memory-budget does not govern' \
  "status names the budget that does not cover extension output"

out=$("$EXT" list --home "$HOME_ONE")
assert_contains "$out" 'hello-ext' "list names the installed extension"
assert_contains "$out" '1.0.0' "list reports the installed version"

out=$("$EXT" triggers --home "$HOME_ONE")
assert_contains "$out" '- hello-ext - load when config/hello-ext.json opts the home in' \
  "triggers prints the extension's declared load condition verbatim"

out=$("$EXT" hooks session-start --home "$HOME_ONE")
assert_contains "$out" "hello-ext	$PKG/hooks/session-start" \
  "hooks enumerates the registered session-start hook with its executable path"
out=$("$EXT" hooks launch-wrap --home "$HOME_ONE")
[ -z "$out" ] || fail "hooks prints nothing for a kind no installed extension registers"

# Install refuses a second time and points at update.
out=$("$EXT" install "$PKG" --home "$HOME_ONE" 2>&1) && fail "install refuses to install twice"
assert_contains "$out" 'already installed' "the double-install refusal points at update"

# Update after a package version bump keeps home-owned config and state.
printf '{"keep":true}\n' > "$HOME_ONE/config/hello-ext.json"
mkdir -p "$HOME_ONE/state/hello-ext"
printf 'keep\n' > "$HOME_ONE/state/hello-ext/preserve-me"
tmp="$PKG/.ext.json.tmp"
jq '.version="1.1.0"' "$PKG/ext.json" > "$tmp"; mv "$tmp" "$PKG/ext.json"
out=$("$EXT" update hello-ext --home "$HOME_ONE")
assert_contains "$out" 'updated: hello-ext 1.1.0' "update picks up the package's new version"
assert_present "$HOME_ONE/config/hello-ext.json" "update preserves home-owned config"
assert_present "$HOME_ONE/state/hello-ext/preserve-me" "update preserves home-owned state"
out=$("$EXT" status hello-ext --home "$HOME_ONE")
assert_contains "$out" 'ok: hello-ext 1.1.0' "status reports the updated version"

# Default uninstall preserves config and state; --purge is explicit.
out=$("$EXT" uninstall hello-ext --home "$HOME_ONE")
assert_contains "$out" 'config and state preserved' "default uninstall states its preservation behavior"
assert_absent "$HOME_ONE/.agents/skills/hello-ext" "uninstall removes the skill symlink"
assert_absent "$HOME_ONE/bin/fm-hello-ext-report.sh" "uninstall removes the command symlink"
assert_absent "$HOME_ONE/state/ext/hello-ext" "uninstall removes the receipt"
assert_present "$HOME_ONE/config/hello-ext.json" "default uninstall preserves config"
assert_present "$HOME_ONE/state/hello-ext/preserve-me" "default uninstall preserves state"
assert_no_grep '.agents/skills/hello-ext' "$HOME_ONE/.git/info/exclude" \
  "uninstall removes the per-clone exclude entry it added"

"$EXT" install "$PKG" --home "$HOME_ONE" >/dev/null
"$EXT" uninstall hello-ext --home "$HOME_ONE" --purge >/dev/null
assert_absent "$HOME_ONE/config/hello-ext.json" "purge removes the declared config"
assert_absent "$HOME_ONE/state/hello-ext" "purge removes the declared state"
pass "the install, status, update, and uninstall loop runs against a synthetic package"

# --- a missing symlink is loud and names its remedy ------------------------
HOME_BROKEN=$(fm_ext_home "$TMP_ROOT/home-broken")
"$EXT" install "$PKG" --home "$HOME_BROKEN" >/dev/null
rm -f "$HOME_BROKEN/.agents/skills/hello-ext"
out=$("$EXT" status --home "$HOME_BROKEN" 2>&1); rc=$?
expect_code 3 "$rc" "status fails when a recorded symlink is gone"
assert_contains "$out" 'EXT_BROKEN: hello-ext skill link is missing' \
  "status names the missing symlink as a typed failure"
assert_contains "$out" 're-cloned home shows these symlinks as untracked' \
  "the diagnostic explains how a home loses the symlinks"
assert_contains "$out" 'bin/fm-ext.sh install' "the diagnostic names the reinstall remedy"
assert_contains "$out" '--force' "the diagnostic names the stale-record remedy"

# The stale record cannot be cleared silently: uninstall refuses without --force.
out=$("$EXT" uninstall hello-ext --home "$HOME_BROKEN" 2>&1) && fail "uninstall refuses a drifted installation"
assert_contains "$out" 'does not match its install record' "the uninstall refusal names the mismatch"
out=$("$EXT" uninstall hello-ext --home "$HOME_BROKEN" --force)
assert_contains "$out" 'uninstalled: hello-ext' "--force clears a stale record deliberately"
pass "a missing symlink is a loud, named, actionable failure"

# --- a forced uninstall can only ever reach into state/ext ------------------
# --force skips the receipt read that used to make a traversing name
# unreachable, so the name itself has to be refused before any path built from
# it is expanded.
VICTIM="$TMP_ROOT/victim-tree"
mkdir -p "$VICTIM"
printf 'keep me\n' > "$VICTIM/keep.txt"
out=$("$EXT" uninstall ../../../victim-tree --home "$HOME_BROKEN" --force 2>&1) \
  && fail "a traversing extension name must be refused even with --force"
assert_contains "$out" 'extension name must match' "the refusal names the rule the name broke"
assert_present "$VICTIM/keep.txt" "a refused traversing name must leave the traversed target untouched"
pass "a forced uninstall refuses a traversing extension name without touching the target"

# A record read_receipt has already rejected cannot direct removal at paths this
# extension could never have placed: only the home's own skill and bin links are
# this extension's to retire.
HOME_CRAFTED=$(fm_ext_home "$TMP_ROOT/home-crafted")
"$EXT" install "$PKG" --home "$HOME_CRAFTED" >/dev/null
OUTSIDE="$TMP_ROOT/outside-tree"
mkdir -p "$OUTSIDE"
ln -s "$PKG" "$OUTSIDE/hello-ext"
jq --arg p "$OUTSIDE/hello-ext" \
  '.schema = "firstmate.ext.receipt.v0" | .links = [{kind:"skill",path:$p}]' \
  "$HOME_CRAFTED/state/ext/hello-ext/install.json" > "$TMP_ROOT/crafted.json"
mv "$TMP_ROOT/crafted.json" "$HOME_CRAFTED/state/ext/hello-ext/install.json"
out=$("$EXT" uninstall hello-ext --home "$HOME_CRAFTED" --force 2>&1) \
  || fail "the forced removal must still clear the record: $out"
[ -L "$OUTSIDE/hello-ext" ] \
  || fail "a link path outside the home must be left alone, not unlinked"
assert_absent "$HOME_CRAFTED/.agents/skills/hello-ext" \
  "the extension's own skill link must still be retired"
assert_absent "$HOME_CRAFTED/state/ext/hello-ext" "the forced removal must clear the record"
pass "a forced uninstall ignores link paths the extension could not have placed in the home"

# Every link the damaged record still names is retired on its own, not folded
# into one unusable path: an extension owning a skill link and two commands must
# leave none of the three behind.
PKG_MULTI="$TMP_ROOT/extrepo-multi/extensions/multi-ext"
fm_ext_fixture "$PKG_MULTI" multi-ext
cat > "$PKG_MULTI/bin/fm-multi-ext-extra.sh" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  dependencies) exit 0 ;;
  *) printf 'extra: multi-ext\n' ;;
esac
SH
chmod +x "$PKG_MULTI/bin/fm-multi-ext-extra.sh"
jq '.commands = ["bin/fm-multi-ext-report.sh", "bin/fm-multi-ext-extra.sh"]' \
  "$PKG_MULTI/ext.json" > "$TMP_ROOT/multi.json"
mv "$TMP_ROOT/multi.json" "$PKG_MULTI/ext.json"
HOME_MULTI=$(fm_ext_home "$TMP_ROOT/home-multi")
"$EXT" install "$PKG_MULTI" --home "$HOME_MULTI" >/dev/null
for l in .agents/skills/multi-ext bin/fm-multi-ext-report.sh bin/fm-multi-ext-extra.sh; do
  [ -L "$HOME_MULTI/$l" ] || fail "install should have placed $l"
done
jq '.schema = "firstmate.ext.receipt.v0"' "$HOME_MULTI/state/ext/multi-ext/install.json" \
  > "$TMP_ROOT/multi-receipt.json"
mv "$TMP_ROOT/multi-receipt.json" "$HOME_MULTI/state/ext/multi-ext/install.json"
out=$("$EXT" uninstall multi-ext --home "$HOME_MULTI" --force 2>&1) \
  || fail "the forced removal must succeed: $out"
for l in .agents/skills/multi-ext bin/fm-multi-ext-report.sh bin/fm-multi-ext-extra.sh; do
  assert_absent "$HOME_MULTI/$l" "each link the record still named must be retired on its own: $l"
  assert_no_grep "$l" "$HOME_MULTI/.git/info/exclude" \
    "the exclude entry for $l must be retired with its link"
done
pass "a forced uninstall retires every link the damaged record still names"

# --- a stale receipt whose package is gone --------------------------------
PKG_GONE="$TMP_ROOT/extrepo-gone/extensions/hello-ext"
fm_ext_fixture "$PKG_GONE"
HOME_STALE=$(fm_ext_home "$TMP_ROOT/home-stale")
"$EXT" install "$PKG_GONE" --home "$HOME_STALE" >/dev/null
rm -rf "$TMP_ROOT/extrepo-gone"
out=$("$EXT" status hello-ext --home "$HOME_STALE" 2>&1); rc=$?
expect_code 3 "$rc" "status fails when the receipt outlives its package"
assert_contains "$out" 'EXT_BROKEN: hello-ext skill link' "status names the dangling link"
assert_contains "$out" 'no longer exists' "status says the package target is gone"
out=$("$EXT" update hello-ext --home "$HOME_STALE" 2>&1) && fail "update refuses a dangling installation"
assert_contains "$out" 'not in a state update can repair' "update refuses rather than papering over a stale receipt"
pass "a stale receipt is a loud, named, actionable failure"

# --- a lost per-clone exclude entry is detected, not tolerated -------------
HOME_EXCL=$(fm_ext_home "$TMP_ROOT/home-excl")
"$EXT" install "$PKG" --home "$HOME_EXCL" >/dev/null
: > "$HOME_EXCL/.git/info/exclude"   # exactly what a fresh clone of the home has
out=$("$EXT" status --home "$HOME_EXCL" 2>&1); rc=$?
expect_code 3 "$rc" "status fails when the per-clone exclude no longer hides the symlinks"
assert_contains "$out" 'EXT_EXCLUDE: hello-ext link' "status names the unhidden link"
assert_contains "$out" 'one tidy-up away' "the diagnostic names the failure it prevents"
"$EXT" update hello-ext --home "$HOME_EXCL" >/dev/null
"$EXT" status --home "$HOME_EXCL" >/dev/null || fail "update rewrites the missing exclude entry"
pass "a lost per-clone exclude entry is a loud, named, actionable failure"

# --- absent-but-enabled refuses loudly ------------------------------------
HOME_REQ=$(fm_ext_home "$TMP_ROOT/home-required")
printf '# the home needs this\nhello-ext\n' > "$HOME_REQ/config/ext-required"
out=$("$EXT" status --home "$HOME_REQ" 2>&1); rc=$?
expect_code 4 "$rc" "a home that requires an absent extension fails"
assert_contains "$out" 'EXT_MISSING: hello-ext is listed in' "the refusal names the missing extension"
assert_contains "$out" 'config/ext-required' "the refusal names the file that enabled it"
assert_contains "$out" 'bin/fm-ext.sh install' "the refusal names the install remedy"
assert_contains "$out" 'remove its line' "the refusal names the opt-out remedy"
"$EXT" install "$PKG" --home "$HOME_REQ" >/dev/null
"$EXT" status --home "$HOME_REQ" >/dev/null || fail "installing the required extension clears the refusal"
pass "an absent-but-enabled extension refuses loudly with a named remedy"

# --- the ../ escape lint --------------------------------------------------
ESCAPE="$TMP_ROOT/extrepo/extensions/escape-ext"
fm_ext_fixture_escape "$ESCAPE"
out=$("$EXT" lint "$ESCAPE" 2>&1); rc=$?
expect_code 2 "$rc" "lint fails a package that escapes its own root"
assert_contains "$out" 'EXT_ESCAPE: SKILL.md' "lint names the offending file"
assert_contains "$out" '../../../docs/configuration.md' "lint names the offending reference"
assert_contains "$out" 'lexically for the agent and physically for every script' \
  "lint explains why the reference is worse than a clean break"
out=$("$EXT" lint "$PKG" 2>&1)
assert_contains "$out" 'no references escaping its package root' "lint passes a package that stays inside itself"

# A reference that escapes by exactly ONE level, from a file at the package root.
# This is the shallowest escape there is, and it is the shape a package README
# reaches firstmate's docs/ with, so it is the case most likely to be written.
# It is also the case a per-expansion word split scores as staying inside: bash
# splits `$dir/$token` in two halves, and the literal slash fuses `.` onto the
# leading `..`, swallowing one level. Drive the depth deliberately so the lint
# cannot go quietly vacuous on the shallow end while still catching deep ones.
SHALLOW="$TMP_ROOT/extrepo/extensions/shallow-ext"
fm_ext_fixture "$SHALLOW" shallow-ext
printf 'See [configuration](../../docs/configuration.md) for the rest.\n' >> "$SHALLOW/README.md"
out=$("$EXT" lint "$SHALLOW" 2>&1); rc=$?
expect_code 2 "$rc" "lint fails a one-level escape from a file at the package root"
assert_contains "$out" 'EXT_ESCAPE: README.md' "lint names the root-level file that escapes by one level"

# The same token one directory deeper stays inside the package and must pass,
# so the rule is depth arithmetic and not a ban on the characters '../'.
INSIDE="$TMP_ROOT/extrepo/extensions/inside-ext"
fm_ext_fixture "$INSIDE" inside-ext
printf 'See [the manifest](../ext.json).\n' > "$INSIDE/examples/deep.md"
out=$("$EXT" lint "$INSIDE" 2>&1)
assert_contains "$out" 'no references escaping its package root' \
  "lint passes a ../ reference that resolves back inside the package"


HOME_ESC=$(fm_ext_home "$TMP_ROOT/home-escape")
out=$("$EXT" install "$ESCAPE" --home "$HOME_ESC" 2>&1) && fail "install refuses an escaping package"
assert_contains "$out" 'outside its own package' "the install refusal names the escape rule"
assert_absent "$HOME_ESC/.agents/skills/escape-ext" "the refused install leaves no symlink behind"
assert_absent "$HOME_ESC/state/ext/escape-ext" "the refused install leaves no receipt behind"
pass "the ../ escape lint catches a violating package and blocks its install"

# --- a capability this checkout does not provide refuses by name ----------
# The stand-in token must be one FM_EXT_CAPABILITIES genuinely lacks, or the
# case goes vacuous - which is exactly what happened to hook:session-start
# when the session-start contributor was built, and would have happened to
# hook:launch-wrap when the worker-launch seam landed. hook:future-seam names
# a seam that does not exist; replace it the day one with that name does.
FUTURE="$TMP_ROOT/extrepo/extensions/future-ext"
fm_ext_fixture_requires "$FUTURE" hook:future-seam
HOME_FUT=$(fm_ext_home "$TMP_ROOT/home-future")
out=$("$EXT" install "$FUTURE" --home "$HOME_FUT" 2>&1) && fail "install refuses an unmet capability"
assert_contains "$out" 'hook:future-seam' "the capability refusal names the missing capability"
assert_contains "$out" 'does not provide' "the capability refusal is explicit about the checkout"
pass "a manifest requiring an unavailable capability refuses by name"

# --- a capability this checkout DOES provide installs ----------------------
# The other half of the same contract: a token in FM_EXT_CAPABILITIES must not
# refuse, or every extension declaring what it needs would be unusable.
PROVIDED="$TMP_ROOT/extrepo/extensions/provided-ext"
fm_ext_fixture_requires "$PROVIDED" hook:session-start provided-ext
HOME_PROV=$(fm_ext_home "$TMP_ROOT/home-provided")
"$EXT" install "$PROVIDED" --home "$HOME_PROV" >/dev/null 2>&1 \
  || fail "install refused a capability this checkout provides"
pass "a manifest requiring a provided capability installs"

# --- manifest validation --------------------------------------------------
BAD="$TMP_ROOT/extrepo/extensions/bad-ext"
fm_ext_fixture "$BAD" bad-ext
tmp="$BAD/.ext.json.tmp"
jq 'del(.trigger)' "$BAD/ext.json" > "$tmp"; mv "$tmp" "$BAD/ext.json"
out=$("$EXT" install "$BAD" --home "$(fm_ext_home "$TMP_ROOT/home-bad")" 2>&1) \
  && fail "install refuses a manifest with no declared trigger"
assert_contains "$out" 'declares no trigger' "a trigger-less extension is refused, not silently untriggerable"

jq '.schema="firstmate.ext.v9"' "$BAD/ext.json" > "$tmp"; mv "$tmp" "$BAD/ext.json"
out=$("$EXT" install "$BAD" --home "$TMP_ROOT/home-bad" 2>&1) \
  && fail "install refuses an unknown manifest schema"
assert_contains "$out" 'firstmate.ext.v1' "the schema refusal names the expected schema"
pass "manifest validation refuses rather than defaulting"

# --- a pre-existing unowned target is never replaced ----------------------
HOME_OWN=$(fm_ext_home "$TMP_ROOT/home-owned")
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_OWN/bin/fm-hello-ext-report.sh"
out=$("$EXT" install "$PKG" --home "$HOME_OWN" 2>&1) && fail "install refuses to clobber an unowned command"
assert_contains "$out" 'already exists without this extension' "the refusal names the unowned target"
assert_absent "$HOME_OWN/state/ext/hello-ext" "the refused install records nothing"
pass "install never replaces a path it does not own"
