#!/usr/bin/env bash
# Tests for the Pi session measurement tool (bin/fm-pi-session-metrics.sh and
# bin/fm-pi-session-metrics.mjs): the aggregate reduction, the calibration
# summary, the quota snapshot passthrough, and above all the privacy boundary
# that is the reason this tool is allowed to read transcripts at all.
#
# The privacy assertion is deliberately the crude one - build a transcript
# stuffed with content that must never escape, then assert none of it appears
# anywhere in the output. A test that only checked the fields it expected would
# pass while a new field quietly leaked a path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-session-metrics)
METRICS="$ROOT/bin/fm-pi-session-metrics.sh"

# A transcript whose directory name encodes a project path, exactly as Pi
# writes them, carrying content of every kind the tool must not keep.
build_transcript() {
  local dir="$1/--Users-someone-secret-project--"
  mkdir -p "$dir"
  local file="$dir/2026-08-20T12-54-28-831Z_01a01f3c-bade-7801-90e6-708e6fc8e9c8.jsonl"
  {
    printf '{"type":"session","version":3,"id":"01a01f3c-bade-7801-90e6-708e6fc8e9c8","timestamp":"2026-08-20T12:00:00.000Z","cwd":"/Users/someone/secret-project"}\n'
    printf '{"type":"model_change","timestamp":"2026-08-20T12:00:01.000Z","provider":"openai-codex","modelId":"gpt-5.6-sol"}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"deploy the SUPERSECRETPROMPT to /Users/someone/secret-project"}]}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:03.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","content":[{"type":"text","text":"CONFIDENTIALREPLY"}],"usage":{"input":100,"output":10,"cacheRead":300000,"cacheWrite":5,"reasoning":7}}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:04.000Z","message":{"role":"toolResult","toolName":"bash","toolCallId":"x","content":[{"type":"text","text":"TOOLOUTPUTLEAK"}]}}\n'
    printf '{"type":"message","timestamp":"2026-08-20T12:00:05.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","content":[],"usage":{"input":50,"output":20,"cacheRead":100000,"cacheWrite":0}}}\n'
    printf '{"type":"compaction","timestamp":"2026-08-20T13:00:00.000Z","summary":"COMPACTIONSUMMARYLEAK"}\n'
    printf '{"type":"custom_message","timestamp":"2026-08-20T13:00:01.000Z","customType":"firstmate-sessionstart-nudge","content":"CUSTOMLEAK"}\n'
    printf 'this line is not json at all\n'
    printf '{"type":"message","timestamp":"2026-08-20T13:00:02.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-5","usage":{"input":1,"output":1,"cacheRead":2,"cacheWrite":0}},"trunc\n'
  } > "$file"
}

test_reduction_reports_the_expected_aggregates() {
  local dir="$TMP_ROOT/sessions" out
  build_transcript "$dir"
  out=$("$METRICS" --sessions-dir "$dir" --min-assistant-messages 1 2>/dev/null)
  expect_code 0 "$?" "the measurement must succeed on a real transcript shape"

  SESSION_JSON="$out" node --input-type=module <<'EOF' > "$TMP_ROOT/reduction" 2>&1
const report = JSON.parse(process.env.SESSION_JSON);
if (report.schemaVersion !== 1) throw new Error("schemaVersion must be 1");
if (report.sessions.length !== 1) throw new Error(`expected one session: ${report.sessions.length}`);
const row = report.sessions[0];
const expected = {
  inputTokens: 150,
  outputTokens: 30,
  cacheReadTokens: 400000,
  cacheWriteTokens: 5,
  reasoningTokens: 7,
  turns: 1,
  assistantMessages: 2,
  compactions: 1,
  cacheReadPerAssistantMessage: 200000,
  ageSeconds: 3601,
  // Every parsed record, against only the classes the live breaker is fed.
  // The session header and the model change are counted as events but not as
  // recorded events, because Pi emits no message for them; the custom message
  // is recorded, because Pi emits `message_end` for it and the breaker counts
  // it. The event threshold is derived from this second number.
  events: 8,
  recordedEvents: 6,
};
for (const [key, value] of Object.entries(expected)) {
  if (row[key] !== value) throw new Error(`${key} is ${row[key]}, expected ${value}`);
}
if (JSON.stringify(row.providers) !== JSON.stringify(["openai-codex"])) {
  throw new Error(`providers must come from assistant messages: ${JSON.stringify(row.providers)}`);
}
// Coarse classes only, counted, never named after a tool or a command.
const classes = row.eventClasses;
if (classes.assistant !== 2 || classes.user !== 1 || classes.toolResult !== 1 || classes.compaction !== 1) {
  throw new Error(`unexpected event classes: ${JSON.stringify(classes)}`);
}
if (Object.keys(classes).some((key) => /bash|tool_/i.test(key) && key !== "toolResult")) {
  throw new Error(`event classes must never be named after a tool: ${JSON.stringify(classes)}`);
}
// A truncated final line is normal for a live session and must not fail the
// measurement or be counted as a complete message.
if (row.assistantMessages !== 2) throw new Error("a truncated trailing line must be skipped");
EOF
  expect_code 0 "$?" "aggregate reduction must be exact: $(cat "$TMP_ROOT/reduction")"
  pass "the measurement reduces a transcript to exact token, turn, compaction, and event-class totals"
}

test_no_transcript_content_ever_reaches_the_output() {
  local dir="$TMP_ROOT/private" out leak
  build_transcript "$dir"
  out=$("$METRICS" --sessions-dir "$dir" --min-assistant-messages 1 2>/dev/null)
  for leak in \
    SUPERSECRETPROMPT CONFIDENTIALREPLY TOOLOUTPUTLEAK COMPACTIONSUMMARYLEAK CUSTOMLEAK \
    "/Users/someone" "secret-project" "someone" bash toolName firstmate-sessionstart-nudge \
    "01a01f3c" cwd summary content; do
    assert_not_contains "$out" "$leak" "the report must never carry transcript content: $leak"
  done
  pass "prompts, replies, tool output, compaction summaries, paths, project names, and the session id never reach the output"
}

test_undeclared_fields_cannot_ship() {
  local dir="$TMP_ROOT/fields" out
  build_transcript "$dir"
  out=$("$METRICS" --sessions-dir "$dir" --min-assistant-messages 1 2>/dev/null)
  SESSION_JSON="$out" node --input-type=module <<'EOF' > "$TMP_ROOT/fields-out" 2>&1
const report = JSON.parse(process.env.SESSION_JSON);
// The allow-list is the contract. Anything a later edit adds to a session row
// has to be added here too, which is the point: a new field is a decision, not
// an accident.
const allowed = new Set([
  "session", "providers", "models", "inputTokens", "outputTokens", "cacheReadTokens",
  "cacheWriteTokens", "reasoningTokens", "turns", "assistantMessages", "compactions",
  "ageSeconds", "events", "recordedEvents", "eventClasses", "cacheReadPerAssistantMessage",
  "eventsPerHour",
]);
for (const row of report.sessions) {
  for (const key of Object.keys(row)) {
    if (!allowed.has(key)) throw new Error(`undeclared session field reached the output: ${key}`);
  }
}
EOF
  expect_code 0 "$?" "only declared fields may ship: $(cat "$TMP_ROOT/fields-out")"
  pass "a session row can only carry the declared aggregate fields"
}

test_summary_is_the_calibration_evidence() {
  local dir="$TMP_ROOT/summary" out
  build_transcript "$dir"
  out=$("$METRICS" --summary --sessions-dir "$dir" --min-assistant-messages 1 2>/dev/null)
  SESSION_JSON="$out" node --input-type=module <<'EOF' > "$TMP_ROOT/summary-out" 2>&1
const report = JSON.parse(process.env.SESSION_JSON);
if ("sessions" in report) throw new Error("--summary must omit the per-session rows");
const baseline = report.baseline;
if (baseline.sessionsRead !== 1 || baseline.sessionsMeasured !== 1) {
  throw new Error(`unexpected counts: ${JSON.stringify(baseline)}`);
}
// The four things the thresholds were derived from must all be reported, or
// re-deriving them later is guesswork again.
for (const key of ["cacheReadPerAssistantMessage", "eventsPerHour", "events", "recordedEvents", "byCompaction"]) {
  if (!(key in baseline)) throw new Error(`the calibration summary must report ${key}`);
}
if (baseline.cacheReadPerAssistantMessage.p90 !== 200000) {
  throw new Error(`percentiles must come from the measured rows: ${JSON.stringify(baseline.cacheReadPerAssistantMessage)}`);
}
if (baseline.byCompaction["1"].sessions !== 1) {
  throw new Error(`compaction buckets must be reported: ${JSON.stringify(baseline.byCompaction)}`);
}
// The event ceiling is derived from the per-bucket maxima, so the summary has
// to emit them or the threshold cannot be re-derived from this command alone.
if (baseline.byCompaction["1"].maxRecordedEvents !== 6 || baseline.byCompaction["1"].maxEvents !== 8) {
  throw new Error(`bucket event maxima must be reported: ${JSON.stringify(baseline.byCompaction["1"])}`);
}
if (baseline.recordedEvents.max !== 6) {
  throw new Error(`the recorded-event axis must be summarized: ${JSON.stringify(baseline.recordedEvents)}`);
}
EOF
  expect_code 0 "$?" "the summary must carry the calibration evidence: $(cat "$TMP_ROOT/summary-out")"

  # Short sessions cannot show growth, so they are excluded from the
  # percentiles by default and would otherwise drag every threshold down.
  out=$("$METRICS" --summary --sessions-dir "$dir" 2>/dev/null)
  assert_contains "$out" '"sessionsMeasured": 0' "the default floor must exclude a session too short to show growth"
  pass "--summary reports the calibration evidence and excludes sessions too short to measure"
}

test_missing_or_empty_input_is_reported_not_guessed() {
  local out
  out=$("$METRICS" --summary --sessions-dir "$TMP_ROOT/does-not-exist" 2>/dev/null)
  expect_code 0 "$?" "an absent sessions directory must still produce a report"
  assert_contains "$out" '"sessionsRead": 0' "an absent sessions directory must report zero sessions, not fail"

  "$METRICS" --nonsense >/dev/null 2>&1
  expect_code 2 "$?" "an unknown flag must be a usage error"
  "$METRICS" --sessions-dir >/dev/null 2>&1
  expect_code 2 "$?" "a flag missing its value must be a usage error"
  pass "an absent corpus reports zero rather than guessing, and misuse is a usage error"
}

test_quota_snapshot_is_carried_through_without_a_verdict() {
  local dir="$TMP_ROOT/quota" out fakebin
  build_transcript "$dir"
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'FAKE'
#!/usr/bin/env bash
cat <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"codex","windows":[{"id":"five_hour","kind":"session","resetsAt":"2026-09-01T16:00:00.000Z","percentRemaining":40}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":40,"limitingWindowIds":["five_hour"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":6994,"projectedExhaustedAt":"2026-09-01T15:51:24.166Z","projectionConfidence":"established"}}]}}]}
JSON
FAKE
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$PATH" "$METRICS" --summary --quota --sessions-dir "$dir" 2>/dev/null)
  SESSION_JSON="$out" node --input-type=module <<'EOF' > "$TMP_ROOT/quota-out" 2>&1
const report = JSON.parse(process.env.SESSION_JSON);
if (report.quota.status !== "read") throw new Error(`quota must be read: ${JSON.stringify(report.quota)}`);
const codex = report.quota.providers.find((entry) => entry.provider === "codex");
if (codex.windows[0].percentRemaining !== 40 || codex.windows[0].resetsAt !== "2026-09-01T16:00:00.000Z") {
  throw new Error(`the window must be carried through verbatim: ${JSON.stringify(codex.windows)}`);
}
const runway = codex.effectiveAvailability[0].runway;
if (runway.status !== "projected_exhaustion" || runway.usableRunwaySeconds !== 6994) {
  throw new Error(`the runway must be carried through verbatim: ${JSON.stringify(runway)}`);
}
// A snapshot, not a judgment: this tool renders no verdict about the numbers.
for (const key of ["verdict", "level", "action", "recommendation", "spendPriority"]) {
  if (JSON.stringify(report.quota).includes(`"${key}"`)) throw new Error(`the snapshot must carry no verdict: ${key}`);
}
EOF
  expect_code 0 "$?" "the quota snapshot must be a verbatim passthrough: $(cat "$TMP_ROOT/quota-out")"

  # A missing quota-axi must not fail a session measurement that does not
  # depend on it. node stays reachable and quota-axi does not.
  local nodeonly="$TMP_ROOT/node-only"
  mkdir -p "$nodeonly"
  ln -sf "$(command -v node)" "$nodeonly/node"
  out=$(PATH="$nodeonly:/usr/bin:/bin" "$METRICS" --summary --quota --sessions-dir "$dir" 2>/dev/null)
  assert_contains "$out" '"status": "unavailable"' "absent quota-axi must report an unavailable snapshot"
  assert_contains "$out" '"sessionsRead": 1' "absent quota-axi must not fail the session measurement"
  pass "the quota snapshot is carried through verbatim, and its absence never fails the measurement"
}

test_reduction_reports_the_expected_aggregates
test_no_transcript_content_ever_reaches_the_output
test_undeclared_fields_cannot_ship
test_summary_is_the_calibration_evidence
test_missing_or_empty_input_is_reported_not_guessed
test_quota_snapshot_is_carried_through_without_a_verdict
