#!/usr/bin/env bash
# Tests the Pi-local Headroom extension through its extension API and through
# the installed Pi version's real extension runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-headroom-extension)
EXT="$ROOT/.pi/extensions/fm-headroom.ts"
export NODE_NO_WARNINGS=1

install_headroom_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-headroom.ts"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function estimateTokens(message) {
  let chars = 0;
  for (const part of message.content) {
    chars += part.type === "text" ? part.text.length : 4800;
  }
  return Math.ceil(chars / 4);
}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
  String(options = {}) {
    return { type: "string", ...options };
  },
};
JS
}

test_default_off_is_a_true_passthrough() {
  local repo home out status
  repo="$TMP_ROOT/default-off-root"
  home="$TMP_ROOT/default-off-home"
  install_headroom_fixture "$repo"
  mkdir -p "$home"
  cat > "$TMP_ROOT/default-off-probe.mjs" <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const tools = [];
const flags = new Map();
const pi = {
  registerFlag(name, options) { flags.set(name, options.default); },
  getFlag(name) { return flags.get(name); },
  registerTool(tool) { tools.push(tool); },
  on(name, handler) {
    const list = handlers.get(name) ?? [];
    list.push(handler);
    handlers.set(name, list);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const ctx = {
  sessionManager: { getSessionId: () => "disabled-session" },
  ui: { notify() {}, setStatus() {} },
};
await handlers.get("session_start")[0]({ type: "session_start", reason: "startup" }, ctx);
const original = {
  type: "tool_result",
  toolCallId: "off-1",
  toolName: "bash",
  input: { command: "printf test" },
  content: [{ type: "text", text: "unchanged\nunchanged\nunchanged" }],
  details: { exact: true },
  isError: false,
};
const before = JSON.stringify(original);
const patch = await handlers.get("tool_result")[0](original, ctx);
if (patch !== undefined) throw new Error(`disabled extension returned a patch: ${JSON.stringify(patch)}`);
if (JSON.stringify(original) !== before) throw new Error("disabled extension mutated the event");
if (tools.length !== 0) throw new Error("disabled extension registered a model-visible retrieval tool");
if (existsSync(`${process.env.FM_STATE_OVERRIDE}/extensions/pi-headroom`)) {
  throw new Error("disabled extension wrote session state");
}
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$home/state" node "$TMP_ROOT/default-off-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "Headroom must be a byte-for-byte passthrough when no session opts in"
  [ -z "$out" ] || fail "Headroom default-off test printed output: $out"
  pass "Headroom is inert by default"
}

test_transform_preserves_semantics_retrieval_and_metrics() {
  local repo home out status
  repo="$TMP_ROOT/transform-root"
  home="$TMP_ROOT/transform-home"
  install_headroom_fixture "$repo"
  mkdir -p "$home"
  cat > "$TMP_ROOT/transform-probe.mjs" <<'EOF'
import { readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const tools = [];
const flags = new Map();
const pi = {
  registerFlag(name, options) { flags.set(name, options.default); },
  getFlag(name) { return flags.get(name); },
  registerTool(tool) { tools.push(tool); },
  on(name, handler) {
    const list = handlers.get(name) ?? [];
    list.push(handler);
    handlers.set(name, list);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
flags.set("headroom", "transform");
const notices = [];
const ctx = {
  sessionManager: { getSessionId: () => "transform-session" },
  ui: {
    notify(message) { notices.push(message); },
    setStatus() {},
  },
};
await handlers.get("session_start")[0]({ type: "session_start", reason: "startup" }, ctx);
const retrieval = tools.find((tool) => tool.name === "fm_headroom_original");
if (!retrieval) throw new Error("opted-in session did not register the retrieval tool");

const line = "the exact same reported record remains semantically present";
const text = Array(10).fill(line).join("\n");
const originalContent = [
  { type: "text", text },
  { type: "image", data: "YWJj", mimeType: "image/png" },
];
await handlers.get("tool_execution_start")[0]({
  type: "tool_execution_start",
  toolCallId: "call-1",
  toolName: "bash",
  args: {},
});
await new Promise((resolve) => setTimeout(resolve, 5));
const event = {
  type: "tool_result",
  toolCallId: "call-1",
  toolName: "bash",
  input: { command: "fixture" },
  content: structuredClone(originalContent),
  details: {
    truncation: { truncated: true },
    matchLimitReached: 100,
    linesTruncated: true,
  },
  isError: false,
};
const before = JSON.stringify(event);
const patch = await handlers.get("tool_result")[0](event, ctx);
if (!patch || !Array.isArray(patch.content)) throw new Error("transform mode did not patch a compressible result");
if (Object.keys(patch).join(",") !== "content") {
  throw new Error(`Headroom changed result semantics outside content: ${JSON.stringify(patch)}`);
}
if (JSON.stringify(event) !== before) throw new Error("Headroom mutated Pi's original event");
if (patch.content[1].data !== originalContent[1].data) throw new Error("non-text result content changed");
const transformedText = patch.content[0].text;
const match = /exact original available from fm_headroom_original with id "(hr-[0-9a-f]+-[0-9]+)"/.exec(transformedText);
if (!match) throw new Error(`transformed result has no retrieval id: ${transformedText}`);
if (!transformedText.includes("repeated 9 additional times")) {
  throw new Error(`transformed result lost exact multiplicity: ${transformedText}`);
}
const restored = await retrieval.execute("retrieve-1", { id: match[1] });
if (JSON.stringify(restored.content) !== JSON.stringify(originalContent)) {
  throw new Error("retrieval did not return the exact original content");
}
if (restored.isError !== false || restored.details.sourceTool !== "bash") {
  throw new Error(`retrieval did not preserve result semantics: ${JSON.stringify(restored)}`);
}

await handlers.get("turn_start")[0]({ type: "turn_start", turnIndex: 2, timestamp: Date.now() }, ctx);
await new Promise((resolve) => setTimeout(resolve, 5));
await handlers.get("message_end")[0]({
  type: "message_end",
  message: { role: "assistant", content: [], timestamp: Date.now() },
}, ctx);

const dir = `${process.env.FM_STATE_OVERRIDE}/extensions/pi-headroom`;
const files = readdirSync(dir);
if (files.length !== 1 || !files[0].endsWith(".json")) {
  throw new Error(`expected one durable session record: ${files.join(",")}`);
}
const report = JSON.parse(readFileSync(`${dir}/${files[0]}`, "utf8"));
if (report.schemaVersion !== 1 || report.mode !== "transform") throw new Error("wrong session record header");
if (report.tokenEstimator !== "pi-estimateTokens" || report.byteEncoding !== "utf8-json") {
  throw new Error("measurement units are not explicit");
}
const serializedReport = JSON.stringify(report);
for (const privateValue of [line, text, "fixture", "command"]) {
  if (serializedReport.includes(privateValue)) {
    throw new Error(`measurement record retained tool content or input: ${privateValue}`);
  }
}
if (report.results.length !== 1) throw new Error(`expected one measured result: ${report.results.length}`);
const row = report.results[0];
for (const field of [
  "rawBytes", "rawTokens", "transformedBytes", "transformedTokens", "compressionRatio",
  "toolLatencyMs", "modelLatencyMs", "truncations", "sourceOmissions", "foldedLines", "pairingKey",
  "toolClass", "foldEligible", "foldDecision",
]) {
  if (!(field in row)) throw new Error(`measurement is missing ${field}`);
}
if (row.toolClass !== "log" || row.foldEligible !== true || row.foldDecision !== "applied") {
  throw new Error(`a folded log-class result was not recorded as such: ${JSON.stringify(row)}`);
}
if (!row.transformed || row.rawBytes <= row.transformedBytes || row.rawTokens <= row.transformedTokens) {
  throw new Error(`compression measurements do not describe the delivered result: ${JSON.stringify(row)}`);
}
if (row.toolLatencyMs === null || row.modelLatencyMs === null) {
  throw new Error(`latencies were not paired to the result: ${JSON.stringify(row)}`);
}
if (row.truncations !== 2 || row.sourceOmissions !== 1 || row.foldedLines !== 9) {
  throw new Error(`loss accounting is wrong: ${JSON.stringify(row)}`);
}
if (notices.length !== 0) throw new Error(`unexpected Headroom warning: ${notices.join("; ")}`);
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$home/state" node "$TMP_ROOT/transform-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "Headroom must transform before delivery, preserve semantics, retrieve originals, and persist paired metrics"
  [ -z "$out" ] || fail "Headroom transform test printed output: $out"
  pass "Headroom transforms safely, retrieves originals, and records paired measurements"
}

test_baseline_and_failure_paths_deliver_original_exactly() {
  local repo baseline bad_state out status
  repo="$TMP_ROOT/fallback-root"
  baseline="$TMP_ROOT/baseline-home"
  bad_state="$TMP_ROOT/not-a-directory"
  install_headroom_fixture "$repo"
  mkdir -p "$baseline"
  cat > "$TMP_ROOT/baseline-probe.mjs" <<'EOF'
import { readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const flags = new Map();
const pi = {
  registerFlag(name, options) { flags.set(name, options.default); },
  getFlag(name) { return flags.get(name); },
  registerTool() {},
  on(name, handler) { handlers.set(name, handler); },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
flags.set("headroom", "baseline");
const ctx = {
  sessionManager: { getSessionId: () => "baseline-session" },
  ui: { notify() {}, setStatus() {} },
};
await handlers.get("session_start")({}, ctx);
const event = {
  toolCallId: "baseline-1",
  toolName: "read",
  input: { path: "fixture" },
  content: [{ type: "text", text: Array(8).fill("a long repeated baseline line").join("\n") }],
  details: { unchanged: true },
  isError: true,
};
const before = JSON.stringify(event);
const patch = await handlers.get("tool_result")(event, ctx);
if (patch !== undefined || JSON.stringify(event) !== before) {
  throw new Error("baseline mode changed the tool result");
}
const dir = `${process.env.FM_STATE_OVERRIDE}/extensions/pi-headroom`;
const report = JSON.parse(readFileSync(`${dir}/${readdirSync(dir)[0]}`, "utf8"));
const row = report.results[0];
if (row.mode !== "baseline" || row.transformed || row.rawBytes !== row.transformedBytes ||
    row.rawTokens !== row.transformedTokens || row.compressionRatio !== 1 ||
    row.truncations !== 0 || row.sourceOmissions !== 0 || row.foldedLines !== 0 ||
    row.foldDecision !== "mode-baseline") {
  throw new Error(`baseline measurement changed semantics: ${JSON.stringify(row)}`);
}
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$baseline/state" node "$TMP_ROOT/baseline-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "baseline mode must measure while returning Pi's exact original result"
  [ -z "$out" ] || fail "Headroom baseline test printed output: $out"

  printf 'not a directory\n' > "$bad_state"
  cat > "$TMP_ROOT/bad-state-probe.mjs" <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const flags = new Map();
const notices = [];
const pi = {
  registerFlag(name, options) { flags.set(name, options.default); },
  getFlag(name) { return flags.get(name); },
  registerTool() {},
  on(name, handler) { handlers.set(name, handler); },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
flags.set("headroom", "transform");
const ctx = {
  sessionManager: { getSessionId: () => "failure-session" },
  ui: {
    notify(message) { notices.push(message); },
    setStatus() {},
  },
};
await handlers.get("session_start")({}, ctx);
const event = {
  toolCallId: "failure-1",
  toolName: "bash",
  input: {},
  content: [{ type: "text", text: Array(8).fill("a long repeated failure line").join("\n") }],
  details: { exact: true },
  isError: false,
};
const before = JSON.stringify(event);
const patch = await handlers.get("tool_result")(event, ctx);
if (patch !== undefined || JSON.stringify(event) !== before) {
  throw new Error("failed extension changed the tool result");
}
if (!notices.some((message) => message.includes("disabled after an instrumentation failure"))) {
  throw new Error(`failure was silent: ${notices.join("; ")}`);
}
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$bad_state" node "$TMP_ROOT/bad-state-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "an initialization or instrumentation failure must disable Headroom and preserve the original"
  [ -z "$out" ] || fail "Headroom failure test printed output: $out"

  cat > "$TMP_ROOT/handler-error-probe.mjs" <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const flags = new Map();
const notices = [];
const pi = {
  registerFlag(name, options) { flags.set(name, options.default); },
  getFlag(name) { return flags.get(name); },
  registerTool() {},
  on(name, handler) { handlers.set(name, handler); },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
flags.set("headroom", "transform");
const ctx = {
  sessionManager: { getSessionId: () => "handler-error-session" },
  ui: {
    notify(message) { notices.push(message); },
    setStatus() {},
  },
};
await handlers.get("session_start")({}, ctx);
const circular = {};
circular.self = circular;
const event = {
  toolCallId: "error-1",
  toolName: "bash",
  input: circular,
  content: [{ type: "text", text: Array(8).fill("a long repeated handler error line").join("\n") }],
  details: { exact: true },
  isError: false,
};
const beforeContent = JSON.stringify(event.content);
const patch = await handlers.get("tool_result")(event, ctx);
if (patch !== undefined || JSON.stringify(event.content) !== beforeContent) {
  throw new Error("an internal handler error changed the tool result");
}
if (!notices.some((message) => message.includes("disabled after an instrumentation failure"))) {
  throw new Error(`handler error was silent: ${notices.join("; ")}`);
}
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$TMP_ROOT/handler-error-state" node "$TMP_ROOT/handler-error-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "an internal Headroom handler error must return no patch and preserve the original"
  [ -z "$out" ] || fail "Headroom handler-error test printed output: $out"
  pass "Headroom baseline and failure paths preserve Pi's exact original result"
}

test_only_foldable_tool_classes_fold() {
  local repo home out status
  repo="$TMP_ROOT/tool-class-root"
  home="$TMP_ROOT/tool-class-home"
  install_headroom_fixture "$repo"
  mkdir -p "$home"
  cat > "$TMP_ROOT/fold-class-probe.mjs" <<'EOF'
import { readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const flags = new Map();
const pi = {
  registerFlag(name, options) { flags.set(name, options.default); },
  getFlag(name) { return flags.get(name); },
  registerTool() {},
  on(name, handler) {
    const list = handlers.get(name) ?? [];
    list.push(handler);
    handlers.set(name, list);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
flags.set("headroom", "transform");
const ctx = {
  sessionManager: { getSessionId: () => "tool-class-session" },
  ui: { notify() {}, setStatus() {} },
};
await handlers.get("session_start")[0]({ type: "session_start", reason: "startup" }, ctx);
const result = handlers.get("tool_result")[0];

// A payload every excluded class must leave byte-for-byte intact.
const foldableLine = "this exact log-shaped record repeats many times";
const foldableText = Array(6).fill(foldableLine).join("\n");

// read is byte-exact and line-addressed; the rest carry paths, line numbers,
// or diffs. fm_headroom_original must return an untouched original.
const exactTools = [
  "read", "grep", "find", "ls", "edit", "write", "fm_headroom_original",
  "mcp__some_server__some_tool", "agent",
];
for (const [index, toolName] of exactTools.entries()) {
  const event = {
    type: "tool_result",
    toolCallId: `exact-${index}`,
    toolName,
    input: { fixture: true },
    content: [{ type: "text", text: foldableText }],
    details: { exact: true },
    isError: false,
  };
  const before = JSON.stringify(event);
  const patch = await result(event, ctx);
  if (patch !== undefined) {
    throw new Error(`${toolName} results must never be folded: ${JSON.stringify(patch)}`);
  }
  if (JSON.stringify(event) !== before) throw new Error(`${toolName} event was mutated`);
}

// The identical payload still folds for a fold-eligible class.
const bashEvent = {
  type: "tool_result",
  toolCallId: "log-1",
  toolName: "bash",
  input: { command: "fixture" },
  content: [{ type: "text", text: foldableText }],
  details: { exact: true },
  isError: false,
};
const bashPatch = await result(bashEvent, ctx);
if (!bashPatch?.content) throw new Error("a fold-eligible class was not folded");

// A run that meets neither threshold, and a run whose fold is not smaller,
// are both recorded by reason rather than by outcome alone.
const shortRun = {
  type: "tool_result",
  toolCallId: "log-2",
  toolName: "powershell",
  input: { command: "fixture" },
  content: [{ type: "text", text: ["ok", "ok", "ok", "ok"].join("\n") }],
  details: { exact: true },
  isError: false,
};
if (await result(shortRun, ctx) !== undefined) throw new Error("a below-threshold run was folded");
const distinctRun = {
  type: "tool_result",
  toolCallId: "log-3",
  toolName: "bash",
  input: { command: "fixture" },
  content: [{ type: "text", text: ["first distinct long line", "second distinct long line", "third distinct line"].join("\n") }],
  details: { exact: true },
  isError: false,
};
if (await result(distinctRun, ctx) !== undefined) throw new Error("a payload with no repeated run was folded");
const tightRun = {
  type: "tool_result",
  toolCallId: "log-4",
  toolName: "bash",
  input: { command: "fixture" },
  content: [{ type: "text", text: Array(3).fill("twenty-char line ab").join("\n") }],
  details: { exact: true },
  isError: false,
};
if (await result(tightRun, ctx) !== undefined) {
  throw new Error("a fold that does not shrink the payload was applied");
}

const dir = `${process.env.FM_STATE_OVERRIDE}/extensions/pi-headroom`;
const report = JSON.parse(readFileSync(`${dir}/${readdirSync(dir)[0]}`, "utf8"));
if (report.results.length !== exactTools.length + 4) {
  throw new Error(`expected one row per result: ${report.results.length}`);
}
const rowsByTool = new Map(report.results.map((row) => [`${row.toolName}:${row.sequence}`, row]));
for (const [index, toolName] of exactTools.entries()) {
  const row = rowsByTool.get(`${toolName}:${index + 1}`);
  if (!row) throw new Error(`no measurement row for ${toolName}`);
  if (row.toolClass !== "exact" || row.foldEligible !== false ||
      row.foldDecision !== "tool-class-excluded" || row.transformed !== false) {
    throw new Error(`${toolName} was not recorded as excluded by class: ${JSON.stringify(row)}`);
  }
  if (row.rawBytes !== row.transformedBytes || row.rawTokens !== row.transformedTokens ||
      row.compressionRatio !== 1) {
    throw new Error(`${toolName} measurements claim a change that did not happen: ${JSON.stringify(row)}`);
  }
}
const logRows = report.results.filter((row) => row.toolClass === "log");
if (logRows.length !== 4 || !logRows.every((row) => row.foldEligible === true)) {
  throw new Error(`fold-eligible results were not grouped as log: ${JSON.stringify(logRows)}`);
}
const decisions = logRows.map((row) => `${row.toolName}:${row.foldDecision}`).sort();
const expected = ["bash:applied", "bash:no-repetition", "bash:not-smaller", "powershell:no-repetition"];
if (decisions.join(",") !== expected.join(",")) {
  throw new Error(`log-class decisions are wrong: ${decisions.join(",")}`);
}
if (logRows.filter((row) => row.transformed).length !== 1) {
  throw new Error("only the applied log row may report a transformed payload");
}
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$home/state" node "$TMP_ROOT/fold-class-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "only fold-eligible tool classes may fold, and every result must record its class and fold decision"
  [ -z "$out" ] || fail "Headroom tool-class test printed output: $out"
  pass "Headroom folds only fold-eligible tool classes and records the decision by class"
}

test_installed_pi_runner_patches_before_downstream_delivery() {
  local package_dir observer state out status
  package_dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
  if [ ! -f "$package_dir/package.json" ]; then
    skip "installed Pi package is required for the live tool-result ordering proof"
    return
  fi
  observer="$TMP_ROOT/pi-runner-observer.ts"
  state="$TMP_ROOT/pi-runner-state"
  cat > "$observer" <<'TS'
import { writeFileSync } from "node:fs";
export default function (pi: any) {
  pi.on("tool_result", (event: any) => {
    writeFileSync(process.env.FM_HEADROOM_OBSERVED!, JSON.stringify(event.content));
  });
}
TS
  cat > "$TMP_ROOT/pi-runner-probe.mjs" <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const pi = await import(pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/index.js`).href);
const loader = await import(
  pathToFileURL(`${process.env.PI_PACKAGE_DIR}/dist/core/extensions/loader.js`).href
);
const loaded = await loader.loadExtensions(
  [process.env.PLUGIN, process.env.OBSERVER],
  process.cwd(),
);
if (loaded.errors.length) throw new Error(JSON.stringify(loaded.errors));
const sessionManager = pi.SessionManager.inMemory(process.cwd());
const runner = new pi.ExtensionRunner(
  loaded.extensions,
  loaded.runtime,
  process.cwd(),
  sessionManager,
  {},
);
runner.bindCore({
  sendMessage() {},
  sendUserMessage() {},
  appendEntry() {},
  setSessionName() {},
  getSessionName() { return undefined; },
  setLabel() {},
  getActiveTools() { return []; },
  getAllTools() { return []; },
  setActiveTools() {},
  refreshTools() {},
  getCommands() { return []; },
  async setModel() { return false; },
  getThinkingLevel() { return "off"; },
  setThinkingLevel() {},
}, {
  getModel() { return undefined; },
  getScopedModels() { return []; },
  isIdle() { return false; },
  isProjectTrusted() { return true; },
  getSignal() { return undefined; },
  abort() {},
  hasPendingMessages() { return false; },
  shutdown() {},
  getContextUsage() { return undefined; },
  compact() {},
  getSystemPrompt() { return ""; },
});
runner.setFlagValue("headroom", "transform");
await runner.emit({ type: "session_start", reason: "startup" });
const line = "installed Pi runner receives this exact repeated record";
const raw = [{ type: "text", text: Array(10).fill(line).join("\n") }];
const patch = await runner.emitToolResult({
  type: "tool_result",
  toolCallId: "pi-version-proof",
  toolName: "bash",
  input: { command: "fixture" },
  content: raw,
  details: { semantic: "unchanged" },
  isError: false,
});
if (!patch?.content) throw new Error("installed Pi runner did not return the Headroom patch");
const observed = JSON.parse(readFileSync(process.env.FM_HEADROOM_OBSERVED, "utf8"));
if (JSON.stringify(observed) !== JSON.stringify(patch.content)) {
  throw new Error("a downstream Pi tool_result handler did not receive the patched content");
}
if (JSON.stringify(observed) === JSON.stringify(raw)) {
  throw new Error("installed Pi runner delivered the untransformed result downstream");
}
const version = JSON.parse(readFileSync(`${process.env.PI_PACKAGE_DIR}/package.json`, "utf8")).version;
if (typeof version !== "string" || !version) throw new Error("could not identify the tested Pi version");
EOF
  out=$(PI_PACKAGE_DIR="$package_dir" PLUGIN="$EXT" OBSERVER="$observer" \
    FM_STATE_OVERRIDE="$state" FM_HEADROOM_OBSERVED="$TMP_ROOT/observed.json" \
    node "$TMP_ROOT/pi-runner-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "the installed Pi extension runner must expose Headroom's patch to the next delivery stage"
  [ -z "$out" ] || fail "installed Pi runner Headroom proof printed output: $out"
  pass "installed Pi applies Headroom's tool_result patch before downstream delivery"
}

test_retrieval_ids_do_not_survive_a_reload() {
  local repo home out status
  repo="$TMP_ROOT/reload-root"
  home="$TMP_ROOT/reload-home"
  install_headroom_fixture "$repo"
  mkdir -p "$home"
  cat > "$TMP_ROOT/reload-probe.mjs" <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const tools = [];
const flags = new Map();
const pi = {
  registerFlag(name, options) { flags.set(name, options.default); },
  getFlag(name) { return flags.get(name); },
  registerTool(tool) { tools.push(tool); },
  on(name, handler) {
    const list = handlers.get(name) ?? [];
    list.push(handler);
    handlers.set(name, list);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
flags.set("headroom", "transform");
const ctx = {
  sessionManager: { getSessionId: () => "reload-session" },
  ui: { notify() {}, setStatus() {} },
};

const idOf = (text) => {
  const match = /fm_headroom_original with id "([^"]+)"/.exec(text);
  if (!match) throw new Error(`transformed result has no retrieval id: ${text}`);
  return match[1];
};
const fold = async (line) => {
  const content = [{ type: "text", text: Array(10).fill(line).join("\n") }];
  const patch = await handlers.get("tool_result")[0]({
    type: "tool_result",
    toolCallId: "reload-call",
    toolName: "bash",
    input: { command: "fixture" },
    content: structuredClone(content),
    details: {},
    isError: false,
  }, ctx);
  if (!patch?.content) throw new Error(`a compressible bash result was not folded: ${line}`);
  return { id: idOf(patch.content[0].text), content };
};

// Pi preserves the message history across /reload, so the pre-reload marker and
// its id are still in the model's context when the rebuilt extension starts.
await handlers.get("session_start")[0]({ type: "session_start", reason: "startup" }, ctx);
const before = await fold("the pre-reload bash record repeated many times");
await handlers.get("session_start")[0]({ type: "session_start", reason: "reload" }, ctx);
const after = await fold("a completely different post-reload bash record");

if (before.id === after.id) {
  throw new Error(`a reload reissued a retrieval id already in the model's context: ${before.id}`);
}
const retrieval = tools.find((tool) => tool.name === "fm_headroom_original");
const stale = await retrieval.execute("retrieve-stale", { id: before.id });
if (stale.isError !== true || stale.details.found !== false || stale.details.sourceTool !== null) {
  throw new Error(`a pre-reload id resolved after a reload: ${JSON.stringify(stale)}`);
}
if (JSON.stringify(stale.content) === JSON.stringify(after.content)) {
  throw new Error("retrieval returned a different tool result as the exact original");
}
const current = await retrieval.execute("retrieve-current", { id: after.id });
if (JSON.stringify(current.content) !== JSON.stringify(after.content)) {
  throw new Error("retrieval did not return the post-reload original exactly");
}
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$home/state" node "$TMP_ROOT/reload-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "a retrieval id from before a reload must never resolve to another result's content"
  [ -z "$out" ] || fail "Headroom reload test printed output: $out"
  pass "Headroom retrieval ids are scoped to one session generation"
}

test_unrecognized_mode_warns_and_pending_latency_ends_with_the_run() {
  local repo home out status
  repo="$TMP_ROOT/contract-root"
  home="$TMP_ROOT/contract-home"
  install_headroom_fixture "$repo"
  mkdir -p "$home"
  cat > "$TMP_ROOT/flag-latency-probe.mjs" <<'EOF'
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const load = () => {
  const handlers = new Map();
  const tools = [];
  const flags = new Map();
  const notices = [];
  const pi = {
    registerFlag(name, options) { flags.set(name, options.default); },
    getFlag(name) { return flags.get(name); },
    registerTool(tool) { tools.push(tool); },
    on(name, handler) {
      const list = handlers.get(name) ?? [];
      list.push(handler);
      handlers.set(name, list);
    },
  };
  mod.default(pi);
  return { handlers, tools, flags, notices, ctx: {
    sessionManager: { getSessionId: () => "contract-session" },
    ui: { notify(message) { notices.push(message); }, setStatus() {} },
  } };
};

// A supplied-but-unrecognized value must not start a silently uninstrumented run.
for (const value of [true, "tranform"]) {
  const run = load();
  run.flags.set("headroom", value);
  await run.handlers.get("session_start")[0]({ type: "session_start", reason: "startup" }, run.ctx);
  if (!run.notices.some((message) => message.includes("unrecognized --headroom value"))) {
    throw new Error(`an unrecognized --headroom value was accepted silently: ${JSON.stringify(value)}`);
  }
  const patch = await run.handlers.get("tool_result")[0]({
    type: "tool_result",
    toolCallId: "invalid-1",
    toolName: "bash",
    input: {},
    content: [{ type: "text", text: Array(8).fill("a long repeated rejected-flag line").join("\n") }],
    details: {},
    isError: false,
  }, run.ctx);
  if (patch !== undefined) throw new Error("a rejected --headroom value still transformed a result");
  if (existsSync(`${process.env.FM_STATE_OVERRIDE}/extensions/pi-headroom`)) {
    throw new Error("a rejected --headroom value wrote session state");
  }
}

// The default stays off, and stays silent.
const off = load();
await off.handlers.get("session_start")[0]({ type: "session_start", reason: "startup" }, off.ctx);
if (off.notices.length !== 0) throw new Error(`the default-off launch warned: ${off.notices.join("; ")}`);

// A run that ends before its model response must not take a later run's latency,
// whether the result was still awaiting a turn or already inside one when the
// run terminated. Pi emits turn_start before the response and can end the run
// with no assistant message_end at all when the response stream fails.
const run = load();
run.flags.set("headroom", "baseline");
await run.handlers.get("session_start")[0]({ type: "session_start", reason: "startup" }, run.ctx);
const measure = async (toolCallId) => {
  await run.handlers.get("tool_result")[0]({
    type: "tool_result",
    toolCallId,
    toolName: "bash",
    input: { command: toolCallId },
    content: [{ type: "text", text: `a terminating tool result for ${toolCallId}` }],
    details: {},
    isError: false,
  }, run.ctx);
};
const turnStart = (turnIndex) =>
  run.handlers.get("turn_start")[0]({ type: "turn_start", turnIndex, timestamp: Date.now() }, run.ctx);
const assistantMessageEnd = () =>
  run.handlers.get("message_end")[0]({
    type: "message_end",
    message: { role: "assistant", content: [], timestamp: Date.now() },
  }, run.ctx);

await measure("ended-before-turn");
await run.handlers.get("agent_end")[0]({ type: "agent_end", messages: [] }, run.ctx);

await measure("ended-inside-turn");
await turnStart(0);
await run.handlers.get("agent_end")[0]({ type: "agent_end", messages: [] }, run.ctx);

await turnStart(0);
await new Promise((resolve) => setTimeout(resolve, 5));
await assistantMessageEnd();

const dir = `${process.env.FM_STATE_OVERRIDE}/extensions/pi-headroom`;
const report = JSON.parse(readFileSync(`${dir}/${readdirSync(dir)[0]}`, "utf8"));
if (report.results.length !== 2) throw new Error(`expected two measured results: ${report.results.length}`);
for (const row of report.results) {
  if (row.modelLatencyMs !== null) {
    throw new Error(`a result pending at agent_end took a later run's latency: ${JSON.stringify(row)}`);
  }
}
EOF
  out=$(PLUGIN="$repo/.pi/extensions/fm-headroom.ts" FM_STATE_OVERRIDE="$home/state" node "$TMP_ROOT/flag-latency-probe.mjs" 2>&1)
  status=$?
  expect_code 0 "$status" "an unrecognized mode must warn, and a result pending when the run ends must keep a null model latency"
  [ -z "$out" ] || fail "Headroom flag and latency contract test printed output: $out"
  pass "Headroom rejects unrecognized modes loudly and ends pending latency with the run"
}

test_default_off_is_a_true_passthrough
test_retrieval_ids_do_not_survive_a_reload
test_unrecognized_mode_warns_and_pending_latency_ends_with_the_run
test_transform_preserves_semantics_retrieval_and_metrics
test_baseline_and_failure_paths_deliver_original_exactly
test_only_foldable_tool_classes_fold
test_installed_pi_runner_patches_before_downstream_delivery
