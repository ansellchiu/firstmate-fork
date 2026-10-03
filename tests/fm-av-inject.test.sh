#!/usr/bin/env bash
# tests/fm-av-inject.test.sh - unit tests for the Automic Vault point-of-use
# injection library (bin/fm-av-inject-lib.sh) and its front end
# (bin/fm-av-run.sh), plus a spawn-path regression proving bin/fm-spawn.sh never
# wraps a worker launch in `av inject` on any verified adapter, even for a home
# that opted in. Uses a fake `av`, a fake tmux, and a real isolated git worktree
# - no live harness and no real Automic Vault app required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-av-inject-lib.sh"

AV_RUN="$ROOT/bin/fm-av-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-av-inject)

# --- fm_av_inject_mode: default-off with truthy precedence -------------------

CFG_ON="$TMP_ROOT/cfg-on"; CFG_OFF="$TMP_ROOT/cfg-off"; CFG_GARBAGE="$TMP_ROOT/cfg-garbage"
mkdir -p "$CFG_ON" "$CFG_OFF" "$CFG_GARBAGE"
printf 'on\n' > "$CFG_ON/av-inject"
printf 'off\n' > "$CFG_OFF/av-inject"
printf 'maybe\n' > "$CFG_GARBAGE/av-inject"

[ "$(fm_av_inject_mode "$TMP_ROOT/nope")" = off ] || fail "absent config/av-inject must be off by default"
[ "$(fm_av_inject_mode "$CFG_OFF")" = off ] || fail "explicit off must be off"
[ "$(fm_av_inject_mode "$CFG_GARBAGE")" = off ] || fail "an unrecognized value must fail safe to off"
[ "$(fm_av_inject_mode "$CFG_ON")" = on ] || fail "explicit on must enable"
for truthy in on ON true TRUE yes YES 1; do
  printf '%s\n' "$truthy" > "$CFG_ON/av-inject"
  [ "$(fm_av_inject_mode "$CFG_ON")" = on ] || fail "'$truthy' must enable"
done
printf 'on\n' > "$CFG_ON/av-inject"
[ "$(FM_AV_INJECT=off fm_av_inject_mode "$CFG_ON")" = off ] || fail "FM_AV_INJECT=off must override a present on file"
[ "$(FM_AV_INJECT=on fm_av_inject_mode "$CFG_OFF")" = on ] || fail "FM_AV_INJECT=on must override an off file"
[ "$(FM_AV_INJECT='' fm_av_inject_mode "$CFG_ON")" = on ] || fail "empty FM_AV_INJECT must defer to a present on file"
pass "fm_av_inject_mode is default-off; FM_AV_INJECT overrides with truthy/other precedence, unset/empty defers to the file"

# --- fm_av_inject_keys: exact selection, no default set ----------------------

fm_av_inject_keys "EXA_API_KEY" || fail "a single valid key must validate"
[ "${#FM_AV_INJECT_KEYARGS[@]}" -eq 1 ] || fail "one key must produce one argument"
[ "${FM_AV_INJECT_KEYARGS[0]}" = "+EXA_API_KEY" ] || fail "a key must become +NAME, got '${FM_AV_INJECT_KEYARGS[0]}'"

fm_av_inject_keys "TAVILY_API_KEY,BRAVE_SEARCH_API_KEY DEEPSEEK_API_KEY" || fail "comma and space separators must both work"
[ "${#FM_AV_INJECT_KEYARGS[@]}" -eq 3 ] || fail "three keys must produce three arguments"
[ "${FM_AV_INJECT_KEYARGS[2]}" = "+DEEPSEEK_API_KEY" ] || fail "keys must keep their order"

fm_av_inject_keys "" 2>/dev/null && fail "an empty key spec must refuse: a call must name its exact keys"
fm_av_inject_keys "GOOD_KEY bad-key" 2>/dev/null && fail "a hyphenated key name must refuse"
fm_av_inject_keys "1LEADING_DIGIT" 2>/dev/null && fail "a key name starting with a digit must refuse"
[ -n "$FM_AV_INJECT_ERROR" ] || fail "a refusal must leave an actionable error"
pass "fm_av_inject_keys validates names, splits on commas and spaces, and refuses an empty selection"

# --- fm_av_inject_exec / fm-av-run.sh: refusals ------------------------------

FAKE_BIN=$(fm_fakebin "$TMP_ROOT/av")
# A fake `av` that records exactly what it was asked to run. `list` is the
# preflight probe; `inject` records its full argv and then runs the target.
cat > "$FAKE_BIN/av" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  list) exit "\${FM_FAKE_AV_LIST_RC:-0}" ;;
  open) exit 0 ;;
  inject)
    printf '%s\n' "\$*" >> "$TMP_ROOT/av-argv.log"
    shift
    while [ "\${1:-}" != "--" ] && [ "\$#" -gt 0 ]; do shift; done
    shift || true
    exec "\$@"
    ;;
esac
exit 0
SH
chmod +x "$FAKE_BIN/av"

run_av() {  # <config-dir> <keys> <tool...>
  local cfg=$1; shift
  env FM_CONFIG_OVERRIDE="$cfg" PATH="$FAKE_BIN:$PATH" "$AV_RUN" "$@" 2>&1
}

out=$(run_av "$CFG_OFF" EXA_API_KEY -- /bin/echo hi); rc=$?
expect_code 1 "$rc" "an off home must refuse rather than run the tool keyless"
assert_contains "$out" "config/av-inject" "the refusal must name the toggle the operator must set"
[ ! -s "$TMP_ROOT/av-argv.log" ] || fail "an off home must not reach av at all"
pass "point-of-use injection refuses on an opted-out home instead of running the tool without its key"

# A PATH with the usual system directories but no `av` anywhere on it.
NO_AV_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" PATH="$NO_AV_PATH" "$AV_RUN" EXA_API_KEY -- /bin/echo hi 2>&1); rc=$?
expect_code 1 "$rc" "an enabled home with no av CLI must refuse"
assert_contains "$out" "Automic Vault" "the missing-CLI refusal must name the tool to install"
pass "point-of-use injection refuses when enabled but the av CLI is missing"

out=$(run_av "$CFG_ON" 'GOOD_KEY bad-key' -- /bin/echo hi); rc=$?
expect_code 1 "$rc" "an invalid key name must refuse"
assert_contains "$out" "bad-key" "the refusal must name the offending secret"
pass "point-of-use injection rejects secret names outside [A-Za-z_][A-Za-z0-9_]*"

out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" "$AV_RUN" EXA_API_KEY 2>&1); rc=$?
expect_code 2 "$rc" "a missing -- separator must be a usage error"
out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" "$AV_RUN" EXA_API_KEY -- 2>&1); rc=$?
expect_code 2 "$rc" "a missing tool must be a usage error"
out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" "$AV_RUN" --help 2>&1); rc=$?
expect_code 0 "$rc" "--help must succeed"
assert_contains "$out" "fm-av-run.sh <KEY" "--help must print the calling syntax"
pass "fm-av-run.sh separates usage errors from refusals and documents its own syntax"

# --- fm_av_inject_exec: the injected call names exactly the requested keys ----

: > "$TMP_ROOT/av-argv.log"
out=$(run_av "$CFG_ON" 'EXA_API_KEY,TAVILY_API_KEY' -- /bin/echo ran-the-tool); rc=$?
expect_code 0 "$rc" "an enabled home with a healthy service must run the tool"
assert_contains "$out" "ran-the-tool" "the target tool must actually run"
argv=$(cat "$TMP_ROOT/av-argv.log")
assert_contains "$argv" "+EXA_API_KEY" "the injected call must request the first named key"
assert_contains "$argv" "+TAVILY_API_KEY" "the injected call must request the second named key"
assert_contains "$argv" "-- /bin/echo ran-the-tool" "the tool must follow the inject boundary"
assert_not_contains "$argv" "+BRAVE_SEARCH_API_KEY" "no key beyond the exact selection may be requested"
assert_not_contains "$argv" "+DEEPSEEK_API_KEY" "there must be no implicit default key set"
pass "an injected call requests exactly the named keys and nothing else"

# --- secret backend: selection and the varlock-op branch ---------------------

CFG_VL="$TMP_ROOT/cfg-vl"; mkdir -p "$CFG_VL/varlock"
printf 'on\n' > "$CFG_VL/av-inject"
printf 'varlock-op\n' > "$CFG_VL/secret-backend"
: > "$CFG_VL/varlock/.env.schema"
[ "$(fm_secret_backend_mode "$TMP_ROOT/nope")" = automic ] || fail "absent secret-backend must be automic"
[ "$(fm_secret_backend_mode "$CFG_VL")" = varlock-op ] || fail "varlock-op must select varlock-op"
[ "$(FM_SECRET_BACKEND=automic fm_secret_backend_mode "$CFG_VL")" = automic ] || fail "FM_SECRET_BACKEND must override the file"
[ "$(FM_SECRET_BACKEND=VARLOCK-OP fm_secret_backend_mode "$CFG_ON")" = varlock-op ] || fail "selection must be case-insensitive"
FM_SECRET_BACKEND=maybe fm_secret_backend_mode "$CFG_ON" >/dev/null 2>&1 && fail "a garbage backend must refuse, not default"
pass "fm_secret_backend_mode defaults to automic, honors the override, and refuses garbage"

VL_BIN=$(fm_fakebin "$TMP_ROOT/vl")
cat > "$VL_BIN/varlock" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/vl-argv.log"
printf '%s\n' "\${OP_SERVICE_ACCOUNT_TOKEN:+token-present}" >> "$TMP_ROOT/vl-env.log"
while [ "\${1:-}" != "--" ] && [ "\$#" -gt 0 ]; do shift; done
shift || true
exec "\$@"
SH
cat > "$VL_BIN/security" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_TOKEN+x}" ] || exit 44
printf '%s\n' "$FM_FAKE_TOKEN"
SH
chmod +x "$VL_BIN/varlock" "$VL_BIN/security"
FAKE_TOKEN="ops_FAKE_TEST_TOKEN_NOT_REAL"

run_vl() {  # <keys> <tool...>   (token from FM_FAKE_TOKEN in env)
  local keys=$1; shift
  env FM_CONFIG_OVERRIDE="$CFG_VL" PATH="$VL_BIN:$FAKE_BIN:$PATH" "$AV_RUN" "$keys" -- "$@" 2>&1
}

: > "$TMP_ROOT/vl-argv.log"; : > "$TMP_ROOT/vl-env.log"; : > "$TMP_ROOT/av-argv.log"
out=$(FM_FAKE_TOKEN=$FAKE_TOKEN run_vl 'EXA_API_KEY,TAVILY_API_KEY' /bin/echo ran-vl); rc=$?
expect_code 0 "$rc" "varlock-op must run the tool for allowed keys"
assert_contains "$out" "ran-vl" "the tool must run"
vargv=$(cat "$TMP_ROOT/vl-argv.log")
assert_contains "$vargv" "--filter EXA_API_KEY,TAVILY_API_KEY" "key spec must translate to an exact --filter"
assert_contains "$vargv" "--path $CFG_VL/varlock" "the schema directory must be passed"
assert_not_contains "$vargv" "ops_" "the token must never reach argv"
assert_not_contains "$out" "ops_" "the token must never be printed"
assert_contains "$(cat "$TMP_ROOT/vl-env.log")" "token-present" "varlock must receive the token in its environment"
[ ! -s "$TMP_ROOT/av-argv.log" ] || fail "varlock-op must never touch av"
[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || fail "the token must not leak into this shell's environment"
pass "varlock-op translates the spec to --filter, passes the token only by environment, and never calls av"

# Validation is shared and not bypassed by the fork.
: > "$TMP_ROOT/vl-argv.log"
out=$(FM_FAKE_TOKEN=$FAKE_TOKEN run_vl 'EXA_API_KEY bad-key' /bin/echo no); rc=$?
expect_code 1 "$rc" "an invalid name must refuse under varlock-op"
assert_contains "$out" "bad-key" "the refusal must name the bad key"
out=$(FM_FAKE_TOKEN=$FAKE_TOKEN run_vl 'EXA_API_KEY,*' /bin/echo no); rc=$?
expect_code 1 "$rc" "a glob must refuse, never reach --filter"
[ ! -s "$TMP_ROOT/vl-argv.log" ] || fail "an invalid spec must not exec varlock"
pass "key validation is not bypassed under varlock-op"

# A search-only call needs no av at all.
: > "$TMP_ROOT/vl-argv.log"
out=$(env FM_CONFIG_OVERRIDE="$CFG_VL" FM_FAKE_TOKEN=$FAKE_TOKEN PATH="$VL_BIN:$NO_AV_PATH" "$AV_RUN" EXA_API_KEY -- /bin/echo ran-no-av 2>&1); rc=$?
expect_code 0 "$rc" "a search-only varlock-op call must not require av"
assert_contains "$out" "ran-no-av" "the tool must run without av"
pass "a search-only varlock-op call runs through varlock without the av CLI"

# Per-key routing: a non-search key stays on Automic while varlock-op is selected.
: > "$TMP_ROOT/vl-argv.log"; : > "$TMP_ROOT/av-argv.log"
out=$(FM_FAKE_TOKEN=$FAKE_TOKEN run_vl DEEPSEEK_API_KEY /bin/echo ran-automic); rc=$?
expect_code 0 "$rc" "a non-search key must still be served under varlock-op"
assert_contains "$out" "ran-automic" "the tool must run"
assert_contains "$(cat "$TMP_ROOT/av-argv.log")" "inject +DEEPSEEK_API_KEY -- /bin/echo ran-automic" "a non-search key must go through av inject"
[ ! -s "$TMP_ROOT/vl-argv.log" ] || fail "a non-search-only call must never touch varlock"
out=$(env FM_CONFIG_OVERRIDE="$CFG_VL" FM_FAKE_TOKEN=$FAKE_TOKEN PATH="$VL_BIN:$NO_AV_PATH" "$AV_RUN" DEEPSEEK_API_KEY -- /bin/echo no 2>&1); rc=$?
expect_code 1 "$rc" "a non-search key must still require av"
assert_contains "$out" "Automic Vault" "the refusal must name the missing av CLI"
pass "under varlock-op a non-search key keeps the unchanged Automic path"

# A mixed call resolves each key through its own backend, av outermost.
: > "$TMP_ROOT/vl-argv.log"; : > "$TMP_ROOT/vl-env.log"; : > "$TMP_ROOT/av-argv.log"
out=$(FM_FAKE_TOKEN=$FAKE_TOKEN run_vl 'EXA_API_KEY,DEEPSEEK_API_KEY' /bin/echo ran-mixed); rc=$?
expect_code 0 "$rc" "a mixed call must run the tool"
assert_contains "$out" "ran-mixed" "the tool must run"
aargv=$(cat "$TMP_ROOT/av-argv.log")
assert_contains "$aargv" "inject +DEEPSEEK_API_KEY -- true" "the Automic approval probe must run for the non-search key"
assert_contains "$aargv" "inject +DEEPSEEK_API_KEY -- $VL_BIN/varlock run" "av must wrap varlock for the non-search key"
assert_not_contains "$aargv" "+EXA_API_KEY" "a search key must never reach av"
vargv=$(cat "$TMP_ROOT/vl-argv.log")
assert_contains "$vargv" "--filter EXA_API_KEY -- /bin/echo ran-mixed" "varlock must filter only the search key"
assert_not_contains "$vargv" "DEEPSEEK_API_KEY" "a non-search key must never reach varlock"
assert_not_contains "$aargv$vargv" "ops_" "the token must never reach argv"
assert_contains "$(cat "$TMP_ROOT/vl-env.log")" "token-present" "varlock must receive the token in its environment"
pass "a mixed varlock-op call resolves each key through its own backend"

# The five-key guard still holds for a direct varlock-op request.
: > "$TMP_ROOT/vl-argv.log"
( FM_AV_INJECT_KEYARGS=(+EXA_API_KEY +DEEPSEEK_API_KEY); FM_FAKE_TOKEN=$FAKE_TOKEN PATH="$VL_BIN:$PATH" \
  fm_varlock_op_exec "$CFG_VL" /bin/echo no >/dev/null 2>&1; printf '%s\n' "$FM_AV_INJECT_ERROR" > "$TMP_ROOT/vl-guard.err" )
assert_contains "$(cat "$TMP_ROOT/vl-guard.err")" "DEEPSEEK_API_KEY" "the direct guard must name the disallowed key"
[ ! -s "$TMP_ROOT/vl-argv.log" ] || fail "a disallowed key must not exec varlock"
pass "fm_varlock_op_exec itself serves only the allowlisted search keys"

# Missing / malformed token refuses without exec; the tool never runs.
out=$(run_vl EXA_API_KEY /bin/echo ran-keyless); rc=$?
expect_code 1 "$rc" "a missing token must refuse"
assert_not_contains "$out" "ran-keyless" "the tool must not run without a token"
out=$(FM_FAKE_TOKEN='not-a-token' run_vl EXA_API_KEY /bin/echo ran-keyless); rc=$?
expect_code 1 "$rc" "a malformed token must refuse"
assert_not_contains "$out" "ran-keyless" "the tool must not run on a bad token"
assert_not_contains "$out" "not-a-token" "a bad token value must not be echoed"
[ ! -s "$TMP_ROOT/vl-argv.log" ] || fail "a bad token must not exec varlock"
rm -f "$CFG_VL/varlock/.env.schema"
out=$(FM_FAKE_TOKEN=$FAKE_TOKEN run_vl EXA_API_KEY /bin/echo no); rc=$?
expect_code 1 "$rc" "a missing schema must refuse"
: > "$CFG_VL/varlock/.env.schema"
out=$(env FM_CONFIG_OVERRIDE="$CFG_VL" FM_SECRET_BACKEND=garbage PATH="$VL_BIN:$FAKE_BIN:$PATH" "$AV_RUN" EXA_API_KEY -- /bin/echo no 2>&1); rc=$?
expect_code 1 "$rc" "a garbage backend must refuse the whole call"
pass "varlock-op refuses without running the tool on a missing or bad token, missing schema, or garbage backend"

# --- secondmate homes inherit the varlock schema ------------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
SM_HOME="$TMP_ROOT/sm-home"; mkdir -p "$SM_HOME/config"
propagate_inheritable_config "$CFG_VL" "$SM_HOME/config" 2>/dev/null || fail "local propagation must succeed"
cmp -s "$CFG_VL/varlock/.env.schema" "$SM_HOME/config/varlock/.env.schema" || fail "the schema must reach a local secondmate home"
: > "$TMP_ROOT/vl-argv.log"
out=$(env FM_CONFIG_OVERRIDE="$SM_HOME/config" FM_FAKE_TOKEN=$FAKE_TOKEN PATH="$VL_BIN:$FAKE_BIN:$PATH" "$AV_RUN" EXA_API_KEY -- /bin/echo ran-sm 2>&1); rc=$?
expect_code 0 "$rc" "an inherited home must resolve the schema"
assert_contains "$(cat "$TMP_ROOT/vl-argv.log")" "--path $SM_HOME/config/varlock" "the inherited home must use its own schema copy"

RM_HOME="$TMP_ROOT/rm-home"; mkdir -p "$RM_HOME/config"
printf '# schema\n' > "$TMP_ROOT/schema-src"
sbytes=$(LC_ALL=C wc -c < "$TMP_ROOT/schema-src" | tr -d ' ')
shash=$(shasum -a 256 "$TMP_ROOT/schema-src" | awk '{print $1}')
FM_HOME="$RM_HOME" "$ROOT/bin/fm-remote-inherit.sh" put config/varlock/.env.schema "$sbytes" "$shash" 1 \
  < "$TMP_ROOT/schema-src" >/dev/null 2>&1 || fail "the remote receiver must accept the nested schema path"
cmp -s "$TMP_ROOT/schema-src" "$RM_HOME/config/varlock/.env.schema" || fail "the schema must reach a remote secondmate home"
mkdir -p "$TMP_ROOT/rm2/config"; ln -s "$TMP_ROOT/elsewhere" "$TMP_ROOT/rm2/config/varlock"
FM_HOME="$TMP_ROOT/rm2" "$ROOT/bin/fm-remote-inherit.sh" put config/varlock/.env.schema "$sbytes" "$shash" 1 \
  < "$TMP_ROOT/schema-src" >/dev/null 2>&1 && fail "the remote receiver must refuse a symlinked schema directory"
[ ! -e "$TMP_ROOT/elsewhere/.env.schema" ] || fail "a symlinked schema directory must not be written through"
pass "local and remote secondmate homes inherit config/varlock/.env.schema and resolve it"

# --- preflight: a service that stays down refuses on a bounded poll -----------

: > "$TMP_ROOT/av-argv.log"
start=$(date +%s)
out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" PATH="$FAKE_BIN:$PATH" \
  FM_FAKE_AV_LIST_RC=1 FM_AV_INJECT_PREFLIGHT_POLLS=2 FM_AV_INJECT_PREFLIGHT_INTERVAL=0.05 \
  "$AV_RUN" EXA_API_KEY -- /bin/echo should-not-run 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
expect_code 1 "$rc" "a down approval service must refuse the call"
assert_contains "$out" "approval service" "the refusal must name the approval service"
assert_not_contains "$out" "should-not-run" "the tool must not run when the service is down"
[ "$elapsed" -le 30 ] || fail "the preflight poll must stay bounded, took ${elapsed}s"
pass "a down approval service refuses on a bounded poll instead of running the tool keyless"

# --- preflight: one probe when healthy, one `av open` when down --------------

AV_OK=$(fm_fakebin "$TMP_ROOT/av-ok")
cat > "$AV_OK/av" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) exit 0 ;;
  open) printf 'open\n' >> "$FM_TEST_AV_OPEN_LOG"; exit 0 ;;
esac
exit 0
SH
chmod +x "$AV_OK/av"
: > "$TMP_ROOT/av-open-ok.log"
FM_TEST_AV_OPEN_LOG="$TMP_ROOT/av-open-ok.log" PATH="$AV_OK:$PATH" \
  fm_av_inject_preflight "$AV_OK/av"; rc=$?
expect_code 0 "$rc" "preflight must succeed when the approval service answers"
[ ! -s "$TMP_ROOT/av-open-ok.log" ] || fail "a healthy service must not be restarted"
pass "the vault preflight succeeds on one probe and never restarts a healthy approval service"

AV_DOWN=$(fm_fakebin "$TMP_ROOT/av-down")
cat > "$AV_DOWN/av" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "av list: Automic Vault approval service is not running" >&2; exit 1 ;;
  open) printf 'open\n' >> "$FM_TEST_AV_OPEN_LOG"; exit 0 ;;
esac
exit 0
SH
chmod +x "$AV_DOWN/av"
: > "$TMP_ROOT/av-open-down.log"
# Called directly, not in a command substitution: the refusal reason is
# returned in FM_AV_INJECT_ERROR, which a subshell would discard.
FM_TEST_AV_OPEN_LOG="$TMP_ROOT/av-open-down.log" PATH="$AV_DOWN:$PATH" \
  FM_AV_INJECT_PREFLIGHT_POLLS=2 FM_AV_INJECT_PREFLIGHT_INTERVAL=0.05 \
  fm_av_inject_preflight "$AV_DOWN/av"; rc=$?
expect_code 1 "$rc" "preflight must refuse when the approval service stays down"
[ "$(wc -l < "$TMP_ROOT/av-open-down.log")" -eq 1 ] \
  || fail "preflight must attempt 'av open' exactly once, saw $(wc -l < "$TMP_ROOT/av-open-down.log")"
assert_contains "$FM_AV_INJECT_ERROR" "approval service" "the refusal must name the vault approval service"
assert_contains "$FM_AV_INJECT_ERROR" "av open" "the refusal must name the manual command"
pass "the vault preflight starts the service once, bounds its wait, then refuses naming the service and the manual command"

# --- approval bound: long enough for a human, still a bound -------------------
#
# The approval-carrying inject is the one call a person may have to answer with
# an iPhone Approval or Touch ID tap, so it must not inherit the fast liveness
# bound. It must also stay bounded, or an approval nobody answers hangs the agent
# that made the call. The bash mechanism is forced so the bounds are really
# enforced rather than delegated to any `timeout` that happens to be on PATH.

AV_SLOW=$(fm_fakebin "$TMP_ROOT/av-slow-approval")
cat > "$AV_SLOW/av" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) exit 0 ;;
  inject)
    # The approval "tap" takes 3s; afterwards the real call runs the tool.
    sleep 3
    shift
    while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do shift; done
    shift || true
    exec "$@"
    ;;
esac
exit 0
SH
chmod +x "$AV_SLOW/av"
out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" PATH="$AV_SLOW:$PATH" \
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_VAULT_PROBE_TIMEOUT=1 \
  "$AV_RUN" EXA_API_KEY -- /bin/echo approved-late 2>&1); rc=$?
expect_code 0 "$rc" "an approval slower than the liveness bound must still run the tool"
assert_contains "$out" "approved-late" "the tool must run once the approval lands"
pass "an approval slower than the fast liveness bound still runs the tool"

# An approval nobody ever answers: bounded refusal, tool never runs.
AV_UNANSWERED=$(fm_fakebin "$TMP_ROOT/av-unanswered")
cat > "$AV_UNANSWERED/av" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) exit 0 ;;
  inject) exec sleep 300 ;;
esac
exit 0
SH
chmod +x "$AV_UNANSWERED/av"
start=$(date +%s)
out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" PATH="$AV_UNANSWERED:$PATH" \
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_AV_APPROVAL_TIMEOUT=2 \
  "$AV_RUN" EXA_API_KEY -- /bin/echo should-not-run 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
expect_code 1 "$rc" "an unanswered approval must refuse the call"
assert_not_contains "$out" "should-not-run" "the tool must not run without its keys"
assert_contains "$out" "not granted" "the refusal must say the approval never landed"
[ "$elapsed" -le 30 ] || fail "an unanswered approval must stay bounded, took ${elapsed}s"
pass "an approval nobody answers is bounded and refuses instead of hanging the caller"

# --- preflight: a total ceiling, not just a poll count ------------------------
#
# Bounding each probe is not enough on its own: polls x per-probe-bound is how a
# "bounded" wait still became minutes. With every probe hanging, the wait must
# stop at the deadline rather than paying the full poll count.

AV_HANG=$(fm_fakebin "$TMP_ROOT/av-hang-probe")
cat > "$AV_HANG/av" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list) exec sleep 300 ;;
  open) exit 0 ;;
esac
exit 0
SH
chmod +x "$AV_HANG/av"
start=$(date +%s)
out=$(env FM_CONFIG_OVERRIDE="$CFG_ON" PATH="$AV_HANG:$PATH" \
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_VAULT_PROBE_TIMEOUT=1 \
  FM_AV_INJECT_PREFLIGHT_POLLS=40 FM_AV_INJECT_PREFLIGHT_INTERVAL=0.05 \
  FM_AV_INJECT_PREFLIGHT_DEADLINE=3 \
  "$AV_RUN" EXA_API_KEY -- /bin/echo should-not-run 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))
expect_code 1 "$rc" "a hung approval service must refuse the call"
assert_not_contains "$out" "should-not-run" "the tool must not run when every probe hangs"
# 40 polls x a 1s probe bound would be ~40s; the deadline must cut it far shorter.
[ "$elapsed" -le 20 ] || fail "the deadline must cap the poll count, took ${elapsed}s"
pass "a hung approval service stops at the total ceiling instead of paying every poll"

# --- spawn regression: no launch is ever wrapped ------------------------------
#
# Route A moved injection to the point of use, so the launch path must carry no
# credential at all. This asserts the ABSENCE across every verified adapter, and
# with the home explicitly opted in, because an accidental re-introduction of a
# launch wrapper is exactly the failure this design removed.

SPAWN="$ROOT/bin/fm-spawn.sh"

# Fake tmux: answers the pane-path query and logs the literal launch command.
make_spawn_fakebin() {
  local dir=$1 fakebin tool state_file
  fakebin=$(fm_fakebin "$dir")
  state_file="$dir/kimi.state"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
state=\$(cat "$state_file" 2>/dev/null || true)
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*)
    case "\$state" in
      pointer-typed|ready|delivered) printf '3\n' ;;
      *) printf '1\n' ;;
    esac
    exit 0
    ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  capture-pane)
    case "\$state" in
      ready)
        printf 'Welcome to Kimi Code!\ncontext: 0%%\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
        ;;
      pointer-typed)
        printf 'context: 0%%\n╭────────────────────────────────╮\n│ > Read the brief and follow it │\n│                                │\n╰────────────────────────────────╯\n'
        ;;
      delivered)
        printf '✨ Read the brief\ncontext: 1%%\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
        ;;
      *)
        printf 'Welcome to Kimi Code!\ncontext: 0%%\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
        ;;
    esac
    exit 0
    ;;
  send-keys)
    if [ -n "\${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "\$@"; do
        if [ -n "\$skip_next" ]; then skip_next=; continue; fi
        case "\$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m)
            case "\$state" in
              launched) printf 'ready\n' > "$state_file" ;;
              pointer-typed) printf 'delivered\n' > "$state_file" ;;
            esac
            continue
            ;;
          *)
            # A spawn types a short line sourcing its staged launch file; read the staged command.
            case "\$a" in
              ". '"*"'")
                staged=\${a#". '"}
                staged=\${staged%"'"}
                [ ! -f "\$staged" ] || a=\$(cat "\$staged")
                ;;
            esac
            case "\$a" in
              *' --auto'*)
                printf '%s\n' "\$a" >> "\$FM_FAKE_LAUNCH_LOG"
                printf 'launched\n' > "$state_file"
                ;;
              *'Read the brief'*)
                printf 'pointer-typed\n' > "$state_file"
                ;;
              *)
                printf '%s\n' "\$a" >> "\$FM_FAKE_LAUNCH_LOG"
                ;;
            esac
            ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  # A fake `av` so the resolved absolute path exists for the wrapped launch.
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/av"
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/cursor-agent"
  cat > "$fakebin/kimi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/kimi"
  cat > "$fakebin/muse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/muse"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/agy"
  for tool in pi pi-signed; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=${2:-claude} kind=${3:-crewmate} case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/.kimi-code" "$home/.config/muse"
  printf '# Kimi test config\ndefault_model = "test"\n' > "$home/.kimi-code/config.toml"
  printf '{"schema_version":1}\n' > "$home/.config/muse/auth.json"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  # fm-spawn.sh refuses a ship brief whose task content is empty, so the fixture
  # brief must carry the same filled subsections a real scaffold does.
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the spawn launch path for $id.

## Firstmate spec
Prove the launch carries no injected secret.
EOF
  if [ "$kind" = secondmate ]; then
    mkdir -p "$proj/state" "$proj/data" "$proj/config" "$proj/projects" "$proj/bin"
    touch "$proj/AGENTS.md"
    printf '%s\n' "$id" > "$proj/.fm-secondmate-home"
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6 extra_arg=${7:-}
  : > "$launchlog"
  local -a args=("$id" "$proj")
  if [ -n "$extra_arg" ]; then
    args+=("$extra_arg")
  else
    args+=(--mode no-mistakes --yolo off)
  fi
  # XDG_CONFIG_HOME/XDG_DATA_HOME are set on hosted CI runners and would send
  # adapter credential probes (muse reads $XDG_CONFIG_HOME/muse/auth.json) at
  # the real user's config dir instead of this fixture home, so the pinned HOME
  # only isolates the case once they are cleared too.
  env -u FM_AV_INJECT -u FM_AV_INJECT_KEYS -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
    HOME="$home" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "${args[@]}" 2>&1
}

verified_cases=(
  "claude:crewmate:claude --dangerously-skip-permissions"
  "codex:crewmate:codex --dangerously-bypass-approvals-and-sandbox"
  "codex:secondmate:codex --dangerously-bypass-approvals-and-sandbox"
  "opencode:crewmate:opencode "
  "pi:crewmate:'__FAKEBIN__/pi'"
  "pi:secondmate:'__FAKEBIN__/pi'"
  "pi-signed:crewmate:'__FAKEBIN__/pi-signed'"
  "pi-signed:secondmate:'__FAKEBIN__/pi-signed'"
  "grok:crewmate:grok --always-approve"
  "cursor:crewmate:env -u CLAUDECODE"
  "kimi:crewmate:'__FAKEBIN__/kimi' --auto"
  "muse:crewmate:env -u CLAUDECODE"
)

for entry in "${verified_cases[@]}"; do
  IFS=':' read -r harness kind expected_pattern <<EOF
$entry
EOF
  slug="$harness-$kind"
  # The Kimi adapter installs a global turn-end hook that validates config.toml
  # with python3's tomllib; without it fm-spawn.sh correctly refuses the spawn.
  # agy is deliberately out of this matrix: its spawn only reports success
  # after the live pane shows agy working (folder-trust answer plus the working
  # indicator), which this fixture's fake pane does not render.
  # tests/fm-agy-harness.test.sh owns that launch path; the no-secret property
  # this matrix exists for is identical across the adapters listed above.
  if [ "$harness" = kimi ] && ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    echo "skip: python3 with tomllib not available, so the kimi turn-end hook cannot be installed ($harness $kind spawn)"
    continue
  fi
  rec=$(make_spawn_case "on-$slug" "$harness" "$kind")
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$rec
EOF
  # Opted in on purpose: even then the launch must carry no secret.
  printf 'on\n' > "$HOME_DIR/config/av-inject"
  extra_arg=
  if [ "$kind" = secondmate ]; then
    extra_arg="--secondmate"
    printf '%s\n' "$harness" > "$HOME_DIR/config/secondmate-harness"
  fi
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR" "$extra_arg")
  assert_contains "$out" "spawned $CASE_ID" "spawn for $harness ($kind) should report success"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "inject +" "the launch for $harness ($kind) must carry no injected secret"
  assert_not_contains "$launch" "av inject" "the launch for $harness ($kind) must not invoke av"
  expected_token=${expected_pattern//__FAKEBIN__/$FAKEBIN_DIR}
  assert_contains "$launch" "$expected_token" "the launch for $harness ($kind) must still start the agent"
done
pass "no verified adapter launch is wrapped in av inject, even on an opted-in home"

# An opted-in home with NO av CLI on PATH must still spawn: the launch path no
# longer depends on the vault at all, so a missing vault cannot block a worker.
rec=$(make_spawn_case no-av claude)
IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$rec
EOF
printf 'on\n' > "$HOME_DIR/config/av-inject"
rm -f "$FAKEBIN_DIR/av"
out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
assert_contains "$out" "spawned $CASE_ID" "an opted-in home with no av CLI must still spawn"
launch=$(cat "$LAUNCH_LOG")
assert_contains "$launch" "claude --dangerously-skip-permissions" "the agent must still launch without the vault"
pass "spawning no longer depends on the Automic Vault CLI or its approval service"
