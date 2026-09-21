#!/usr/bin/env bash
# Captain-facing demo: six actionable watcher cycles fire while a 3-hour
# catch-up burst (8 durable rows, 5 distinct notifications) is waiting.
# Runs the REAL Pi watcher extension twice - once at the base commit, once at
# the change under test - and prints every follow-up message Pi was handed.
set -u
ROOT=${ROOT:?}
EXT_UNDER_TEST=${EXT_UNDER_TEST:?}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-burst-demo.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# reuse the suite's fixture installer verbatim
eval "$(sed -n '27,77p' "$ROOT/tests/fm-pi-watch-extension.test.sh")"

run_case() {  # <label> <extension-file>
  local label=$1 ext=$2
  local repo="$TMP_ROOT/$label-root" home="$TMP_ROOT/$label-home"
  local log="$TMP_ROOT/$label.log" stop="$TMP_ROOT/$label.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  EXT=$ext install_pi_watch_extension_fixture "$repo"

  : > "$home/state/.wake-queue"
  for seq in 1 2 3 4 5; do
    printf '1789797077\t%s\tsignal\tburst%s.status\tsignal: %s/burst%s.status\n' \
      "$seq" "$seq" "$home/state" "$seq" >> "$home/state/.wake-queue"
  done
  for seq in 6 7 8; do
    printf '1789797078\t%s\tsignal\tburst%s.status\tsignal: %s/burst%s.status\n' \
      "$seq" "$((seq - 5))" "$home/state" "$((seq - 5))" >> "$home/state/.wake-queue"
  done

  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ "$count" -le 6 ]; then
  printf 'signal: %s/burst%s.status\n' "${FM_STATE_DIR:?}" "$count"
  exit 0
fi
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STATE_DIR="$home/state" \
    FM_STOP_FILE="$stop" NODE_NO_WARNINGS=1 \
    node --input-type=module <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
let tool = null;
const sent = [];
const pi = {
  on() {}, registerCommand() {},
  registerTool(c) { if (c.name === "fm_watch_arm_pi") tool = c; },
  sendUserMessage: async (content) => { sent.push(content); },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-demo", {}, undefined, undefined, {});
for (let i = 0; i < 400; i += 1) {
  const rows = existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
  if (rows.length >= 7) break;
  await new Promise((r) => setTimeout(r, 10));
}
await new Promise((r) => setTimeout(r, 400));
console.log(`watcher cycles fired: ${readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter((r) => r.startsWith("arm=")).length - 1}`);
console.log(`follow-up messages queued in front of the captain: ${sent.length}`);
sent.forEach((m, i) => {
  console.log(`\n--- message ${i + 1} of ${sent.length} (one firstmate turn to clear) ---`);
  console.log(m);
});
const queue = readFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "utf8")
  .split("\n").filter((l) => l.length > 0);
console.log(`\ndurable rows still queued and individually acknowledgeable: ${queue.length}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
}

echo "############################################################"
echo "# BEFORE (base e03a46e): one queued message per watcher cycle"
echo "############################################################"
git -C "$ROOT" show e03a46e:.pi/extensions/fm-primary-pi-watch.ts > "$TMP_ROOT/base-ext.ts"
run_case before "$TMP_ROOT/base-ext.ts"

echo
echo "############################################################"
echo "# AFTER (3b9d076): one bounded notification naming the burst"
echo "############################################################"
run_case after "$EXT_UNDER_TEST"
