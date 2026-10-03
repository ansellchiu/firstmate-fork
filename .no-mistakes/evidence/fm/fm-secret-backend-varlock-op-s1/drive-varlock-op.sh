#!/usr/bin/env bash
# Drive bin/fm-av-run.sh against REAL varlock 1.21.1 in a disposable FM_HOME.
# Only the macOS keychain read (`security`) is stubbed, so the operator keychain is never touched.
set -u
REPO=$1; W=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); mkdir -p "$LAB/config/varlock" "$LAB/bin"
echo on > "$LAB/config/av-inject"; echo varlock-op > "$LAB/config/secret-backend"
ln -s "$W/node_modules" "$LAB/config/varlock/node_modules"; cp "$W/package.json" "$LAB/config/varlock/"
cat > "$LAB/bin/security" <<SH
#!/bin/sh
printf '%s\n' "\${FAKE_TOKEN-ops_FAKEFAKEFAKE}"
SH
chmod +x "$LAB/bin/security"; ln -s "$W/node_modules/.bin/varlock" "$LAB/bin/varlock"
NOAV=$(mktemp -d); for t in bash env sh grep printenv cat node; do ln -s "$(type -P $t)" "$NOAV/$t"; done
P="$LAB/bin:$NOAV:/usr/bin:/bin"   # /usr/local/bin and homebrew (real av, op) excluded
run() { echo "\$ $*"; env -u FM_SECRET_BACKEND -u FM_AV_INJECT PATH="$P" FM_HOME="$LAB" "$@" 2>&1 | sed 's/ops_[A-Za-z0-9]*/ops_<REDACTED>/g'; echo "[exit ${PIPESTATUS[0]}]"; echo; }
static_schema() { { echo "# @defaultSensitive=true"; echo "# ---"; for k in "$@"; do echo "$k=val-$k"; done; } > "$LAB/config/varlock/.env.schema"; }
ALL="EXA_API_KEY TAVILY_API_KEY BRAVE_SEARCH_API_KEY LINKUP_API_KEY PARALLEL_API_KEY"

echo "=== S1: search-only call, all five keys, no av on PATH; tool sees keys, no bearer token ==="
static_schema $ALL
echo "type -P av -> $(PATH=$P type -P av || echo none)"
run "$REPO/bin/fm-av-run.sh" "EXA_API_KEY,TAVILY_API_KEY,BRAVE_SEARCH_API_KEY,LINKUP_API_KEY,PARALLEL_API_KEY" -- bash -c 'for k in EXA_API_KEY TAVILY_API_KEY BRAVE_SEARCH_API_KEY LINKUP_API_KEY PARALLEL_API_KEY; do echo "$k=${!k:+set(len ${#k})}"; done; env | grep -c "^OP_SERVICE_ACCOUNT_TOKEN=" | sed "s/^/OP_SERVICE_ACCOUNT_TOKEN lines in tool env: /"; env | grep -c "ops_" | sed "s/^/ops_ occurrences in tool env: /"'

echo "=== S2: schema omits TAVILY_API_KEY; tool must NOT run ==="
static_schema EXA_API_KEY BRAVE_SEARCH_API_KEY LINKUP_API_KEY PARALLEL_API_KEY
run "$REPO/bin/fm-av-run.sh" "EXA_API_KEY,TAVILY_API_KEY" -- bash -c 'echo TOOL-RAN'
static_schema $ALL

echo "=== S3: non-allowlisted key alone under varlock-op stays on Automic (av absent -> Automic refusal, varlock never used) ==="
run "$REPO/bin/fm-av-run.sh" DEEPSEEK_API_KEY -- bash -c 'echo TOOL-RAN'
echo "=== S3b: mixed call with av absent refuses on Automic requirement, tool not run ==="
run "$REPO/bin/fm-av-run.sh" "EXA_API_KEY,DEEPSEEK_API_KEY" -- bash -c 'echo TOOL-RAN'

echo "=== S4: missing keychain token / malformed token refuse, tool not run ==="
FAKE_TOKEN="" run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN'
FAKE_TOKEN="not-a-token" run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN'

echo "=== S5: well-formed but bad ops_ token rejected by real varlock + 1Password plugin; tool not run ==="
cat > "$LAB/config/varlock/.env.schema" <<'S'
# @plugin(@varlock/1password-plugin)
# @initOp(token=$OP_SERVICE_ACCOUNT_TOKEN)
# ---
# @type=opServiceAccountToken @sensitive @internal
OP_SERVICE_ACCOUNT_TOKEN=
# @sensitive
EXA_API_KEY=op("op://firstmate-rapid-recon/EXA_API_KEY/credential")
S
run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN'
static_schema $ALL

echo "=== S6: backend selection: typo refuses with diagnostic; absent file = automic (needs av) ==="
echo varlok-op > "$LAB/config/secret-backend"
run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN'
echo VARLOCK-OP > "$LAB/config/secret-backend"
run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN'
rm "$LAB/config/secret-backend"
run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN'
echo varlock-op > "$LAB/config/secret-backend"

echo "=== S7: missing schema / missing varlock refuse ==="
mv "$LAB/config/varlock/.env.schema" "$LAB/s.bak"
run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN' | sed "s#$LAB#<LAB>#g"
mv "$LAB/s.bak" "$LAB/config/varlock/.env.schema"; rm "$LAB/bin/varlock"
run "$REPO/bin/fm-av-run.sh" EXA_API_KEY -- bash -c 'echo TOOL-RAN'

rm -rf "$LAB" "$NOAV"
