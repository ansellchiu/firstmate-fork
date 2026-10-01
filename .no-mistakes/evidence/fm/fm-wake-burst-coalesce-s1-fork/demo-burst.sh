#!/usr/bin/env bash
# Demo: ~140 notifications waiting after a 3h monitoring gap, then 20 watcher
# cycles fire while main has not consumed anything. Prints every follow-up
# the captain is sent. Usage: demo-burst.sh <repo-root>
set -u
ROOT=$1; EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"; export NODE_NO_WARNINGS=1
eval "$(awk '/^install_pi_watch_extension_fixture\(\) \{/{p=1} p&&/^[a-z_]+\(\) \{/&&!/^install_pi/{exit} p' "$ROOT/tests/fm-pi-watch-extension.test.sh")"
T=$(mktemp -d); repo=$T/root; home=$T/home
mkdir -p "$repo/bin" "$home/state" "$home/config"; install_pi_watch_extension_fixture "$repo"
: > "$home/state/.wake-queue"
for seq in $(seq 1 140); do task=$(( (seq - 1) % 35 + 1 ))
  printf '1789797077\t%s\tsignal\ttask%s.status\tsignal: %s/task%s.status\n' "$seq" "$task" "$home/state" "$task" >> "$home/state/.wake-queue"; done
cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "$FM_ARM_LOG"; count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -le 20 ]; then printf 'signal: %s/task%s.status\n' "$FM_STATE_DIR" "$count"; exit 0; fi
trap 'exit 0' TERM INT; while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
chmod +x "$repo/bin/fm-watch-arm.sh"
echo "rows in durable queue before: $(wc -l < "$home/state/.wake-queue")"
PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
FM_ARM_LOG="$T/arm.log" FM_STATE_DIR="$home/state" FM_STOP_FILE="$T/stop" node --input-type=module <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let tool; const sent = [];
const pi = { on() {}, registerCommand() {}, registerTool(c) { if (c.name === "fm_watch_arm_pi") tool = c; },
  sendUserMessage: async (content) => { sent.push(content); } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
(await import(pathToFileURL(process.env.PLUGIN).href)).default(pi);
await tool.execute("demo", {}, undefined, undefined, {});
for (let i = 0; i < 1000; i++) {
  const n = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").split("\n").filter(r => r.startsWith("arm=")).length : 0;
  if (n >= 21) break; await new Promise(r => setTimeout(r, 10)); }
await new Promise(r => setTimeout(r, 300));
console.log(`watcher cycles run: 20 actionable; follow-up messages queued to main: ${sent.length}`);
sent.forEach((m, i) => console.log(`\n----- follow-up #${i + 1} -----\n${m}`));
writeFileSync(process.env.FM_STOP_FILE, "stop\n"); process.exit(0);
EOF
echo; echo "rows in durable queue after (nothing silently retired): $(wc -l < "$home/state/.wake-queue")"
rm -rf "$T"
