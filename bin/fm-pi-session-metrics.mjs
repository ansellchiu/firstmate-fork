#!/usr/bin/env node
// Aggregation core for bin/fm-pi-session-metrics.sh: stream local Pi session
// transcripts and reduce each one to a fixed set of aggregate numbers.
//
// bin/fm-pi-session-metrics.sh is the transport and the authoritative owner of
// the operator-facing contract (flags, environment, exit status, and what the
// report means). This file owns only the reduction, and the two must not
// restate each other.
//
// PRIVACY BOUNDARY. This file is the only thing in firstmate that reads a Pi
// transcript, and it exists to make "measure growth without keeping content" a
// property of the code rather than a promise in prose. Every emitted field is
// listed in EMITTED_FIELDS below and is either a vendor identifier, a count, a
// token total, or a duration. Message text, reasoning, tool names, tool
// arguments, tool results, compaction summaries, file paths, the session
// directory name (which encodes the project path), the working directory, and
// credentials are read past and never retained, never counted into a keyed
// bucket, and never emitted. The session UUID is reduced to a truncated digest
// so repeated runs can line up rows without carrying an identifier that maps
// back to a transcript on disk.
//
// The reduction is deliberately the SAME estimator the live policy uses
// (.pi/extensions/lib/fm-primary-growth.ts): cumulative cache-read tokens
// divided by cumulative assistant messages. A threshold measured on cumulative
// averages is only meaningful when it is applied to cumulative averages, so the
// two sides are kept identical on purpose.

import { createReadStream, readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { join } from "node:path";

// The complete list of keys this file may put in its output. Anything not
// here is content, and content does not leave this process.
const EMITTED_FIELDS = [
  "session",
  "providers",
  "models",
  "inputTokens",
  "outputTokens",
  "cacheReadTokens",
  "cacheWriteTokens",
  "reasoningTokens",
  "turns",
  "assistantMessages",
  "compactions",
  "ageSeconds",
  "events",
  "recordedEvents",
  "eventClasses",
  "cacheReadPerAssistantMessage",
  "eventsPerHour",
];

const DEFAULT_SESSIONS_DIR = join(homedir(), ".pi", "agent", "sessions");

// The coarse classes the live breaker (.pi/extensions/fm-primary-growth.ts)
// actually has an event for: it counts `message_end` by role and
// `session_compact`, and nothing else. The test for membership is whether Pi
// emits `message_end` for the record, not whether the record exists in the
// transcript: a custom message is persisted under its own record type but is
// emitted as `message_end` with role "custom", so the live counter is fed it
// and it belongs here, while a setting change and the session header are not
// emitted as messages at all and do not. `events` counts every transcript
// record, which is a strictly larger quantity, so the event ceiling is derived
// from `recordedEvents` instead - the same estimator the live counter is.
const RECORDED_CLASSES = new Set(["assistant", "user", "toolResult", "otherMessage", "compaction", "custom"]);

// Coarse classes only. A record's own `type`, and for messages the message
// role, are the whole classification: nothing inside the record is inspected.
function eventClass(record) {
  if (record.type === "message") {
    const role = record.message?.role;
    if (role === "assistant") return "assistant";
    if (role === "user") return "user";
    if (role === "toolResult") return "toolResult";
    return "otherMessage";
  }
  if (record.type === "compaction") return "compaction";
  if (record.type === "custom_message") return "custom";
  if (record.type === "model_change" || record.type === "thinking_level_change") return "settingChange";
  if (record.type === "session") return "sessionHeader";
  return "other";
}

function newAccumulator() {
  return {
    sessionId: "",
    providers: new Set(),
    models: new Set(),
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    reasoningTokens: 0,
    turns: 0,
    assistantMessages: 0,
    compactions: 0,
    events: 0,
    recordedEvents: 0,
    eventClasses: {},
    firstTimestamp: null,
    lastTimestamp: null,
  };
}

function nonNegative(value) {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : 0;
}

function absorb(acc, record) {
  acc.events += 1;
  const cls = eventClass(record);
  acc.eventClasses[cls] = (acc.eventClasses[cls] || 0) + 1;
  if (RECORDED_CLASSES.has(cls)) acc.recordedEvents += 1;

  const stamp = typeof record.timestamp === "string" ? Date.parse(record.timestamp) : NaN;
  if (Number.isFinite(stamp)) {
    if (acc.firstTimestamp === null || stamp < acc.firstTimestamp) acc.firstTimestamp = stamp;
    if (acc.lastTimestamp === null || stamp > acc.lastTimestamp) acc.lastTimestamp = stamp;
  }

  if (record.type === "session" && typeof record.id === "string") acc.sessionId = record.id;
  if (record.type === "compaction") acc.compactions += 1;
  if (record.type !== "message") return;

  const message = record.message;
  if (!message || typeof message !== "object") return;
  if (message.role === "user") acc.turns += 1;
  if (message.role !== "assistant") return;

  acc.assistantMessages += 1;
  // Vendor identifiers, not content: they are what makes a per-provider
  // baseline possible at all, and they name a model, never a project.
  if (typeof message.provider === "string") acc.providers.add(message.provider);
  if (typeof message.model === "string") acc.models.add(message.model);

  const usage = message.usage;
  if (!usage || typeof usage !== "object") return;
  acc.inputTokens += nonNegative(usage.input);
  acc.outputTokens += nonNegative(usage.output);
  acc.cacheReadTokens += nonNegative(usage.cacheRead);
  acc.cacheWriteTokens += nonNegative(usage.cacheWrite);
  acc.reasoningTokens += nonNegative(usage.reasoning);
}

function finalize(acc) {
  const ageSeconds =
    acc.firstTimestamp !== null && acc.lastTimestamp !== null
      ? Math.max(0, Math.round((acc.lastTimestamp - acc.firstTimestamp) / 1000))
      : 0;
  // A truncated digest of the session UUID only. The directory name, which
  // encodes the project path, is never hashed and never read into this value.
  const session = acc.sessionId
    ? createHash("sha256").update(acc.sessionId).digest("hex").slice(0, 12)
    : "unknown";
  const row = {
    session,
    providers: [...acc.providers].sort(),
    models: [...acc.models].sort(),
    inputTokens: acc.inputTokens,
    outputTokens: acc.outputTokens,
    cacheReadTokens: acc.cacheReadTokens,
    cacheWriteTokens: acc.cacheWriteTokens,
    reasoningTokens: acc.reasoningTokens,
    turns: acc.turns,
    assistantMessages: acc.assistantMessages,
    compactions: acc.compactions,
    ageSeconds,
    events: acc.events,
    recordedEvents: acc.recordedEvents,
    eventClasses: acc.eventClasses,
    cacheReadPerAssistantMessage: acc.assistantMessages
      ? Math.round(acc.cacheReadTokens / acc.assistantMessages)
      : 0,
    eventsPerHour: ageSeconds >= 60 ? Math.round((acc.events * 3600) / ageSeconds) : 0,
  };
  // Structural enforcement of the privacy boundary: a key that was not
  // declared cannot ship, whatever a later edit adds to the accumulator.
  for (const key of Object.keys(row)) {
    if (!EMITTED_FIELDS.includes(key)) throw new Error(`undeclared output field: ${key}`);
  }
  return row;
}

async function readSession(path) {
  const acc = newAccumulator();
  const stream = createReadStream(path, { encoding: "utf8" });
  const lines = createInterface({ input: stream, crlfDelay: Infinity });
  for await (const line of lines) {
    if (!line) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      // A truncated final line is normal for a live session; a transcript is
      // evidence, not input to validate, so an unparseable line is skipped
      // rather than failing the whole measurement.
      continue;
    }
    if (record && typeof record === "object") absorb(acc, record);
  }
  return finalize(acc);
}

function transcriptPaths(root) {
  const paths = [];
  let entries;
  try {
    entries = readdirSync(root, { withFileTypes: true });
  } catch {
    return paths;
  }
  for (const entry of entries) {
    const child = join(root, entry.name);
    if (entry.isDirectory()) {
      paths.push(...transcriptPaths(child));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".jsonl")) paths.push(child);
  }
  return paths;
}

function percentile(values, fraction) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.floor(fraction * sorted.length));
  return sorted[index];
}

// The calibration summary. Sessions below `floor` assistant messages are
// excluded because a handful of messages cannot show growth, and including
// them would drag every percentile toward zero and make the thresholds
// derived from this report too loose to fire.
function summarize(rows, floor) {
  const measured = rows.filter((row) => row.assistantMessages >= floor);
  const ratios = measured.map((row) => row.cacheReadPerAssistantMessage);
  const rates = measured.map((row) => row.eventsPerHour);
  const events = measured.map((row) => row.events);
  const recorded = measured.map((row) => row.recordedEvents);
  const buckets = {};
  for (const row of measured) {
    const key = row.compactions >= 2 ? "2+" : String(row.compactions);
    const bucket = (buckets[key] ||= { sessions: 0, cacheRead: [], ratio: [], events: [], recorded: [] });
    bucket.sessions += 1;
    bucket.cacheRead.push(row.cacheReadTokens);
    bucket.ratio.push(row.cacheReadPerAssistantMessage);
    bucket.events.push(row.events);
    bucket.recorded.push(row.recordedEvents);
  }
  const byCompaction = {};
  for (const [key, bucket] of Object.entries(buckets)) {
    byCompaction[key] = {
      sessions: bucket.sessions,
      medianCacheReadTokens: percentile(bucket.cacheRead, 0.5),
      medianCacheReadPerAssistantMessage: percentile(bucket.ratio, 0.5),
      maxEvents: bucket.events.length ? Math.max(...bucket.events) : 0,
      maxRecordedEvents: bucket.recorded.length ? Math.max(...bucket.recorded) : 0,
    };
  }
  return {
    sessionsRead: rows.length,
    sessionsMeasured: measured.length,
    assistantMessageFloor: floor,
    cacheReadPerAssistantMessage: {
      p50: percentile(ratios, 0.5),
      p75: percentile(ratios, 0.75),
      p90: percentile(ratios, 0.9),
      p95: percentile(ratios, 0.95),
      max: ratios.length ? Math.max(...ratios) : 0,
    },
    eventsPerHour: {
      p50: percentile(rates, 0.5),
      p90: percentile(rates, 0.9),
      max: rates.length ? Math.max(...rates) : 0,
    },
    events: {
      p50: percentile(events, 0.5),
      p90: percentile(events, 0.9),
      p99: percentile(events, 0.99),
      max: events.length ? Math.max(...events) : 0,
    },
    // The event axis the live breaker is calibrated on. Reported alongside the
    // per-bucket maxima below so the ceiling can be re-derived from this
    // summary alone rather than from a full per-session run.
    recordedEvents: {
      p50: percentile(recorded, 0.5),
      p90: percentile(recorded, 0.9),
      p99: percentile(recorded, 0.99),
      max: recorded.length ? Math.max(...recorded) : 0,
    },
    byCompaction,
  };
}

// Verbatim projection of a quota-axi schema-5 report down to the fields this
// report is allowed to keep: provider, window identity, reset, remaining
// percentage, and projected runway. Nothing here ranks, compares, or decides.
// quota-axi owns these numbers and
// .pi/extensions/lib/fm-primary-growth.ts owns what they mean for a session;
// this function only carries them into the record so a baseline row can be read
// next to the quota state it was measured under.
function projectQuota(raw) {
  if (!raw || !raw.trim()) return { status: "unavailable", reason: "no quota-axi report" };
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { status: "unavailable", reason: "unparseable quota-axi report" };
  }
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.providers)) {
    return { status: "unavailable", reason: "unrecognized quota-axi report" };
  }
  const providers = [];
  for (const provider of parsed.providers) {
    if (!provider || typeof provider !== "object") continue;
    providers.push({
      provider: typeof provider.provider === "string" ? provider.provider : "unknown",
      windows: (Array.isArray(provider.windows) ? provider.windows : []).map((window) => ({
        id: window?.id ?? null,
        kind: window?.kind ?? null,
        resetsAt: window?.resetsAt ?? null,
        percentRemaining: typeof window?.percentRemaining === "number" ? window.percentRemaining : null,
      })),
      effectiveAvailability: (provider.quotaSemantics?.effectiveAvailability ?? []).map((entry) => ({
        scope: entry?.scope ?? null,
        effectivePercentRemaining:
          typeof entry?.effectivePercentRemaining === "number" ? entry.effectivePercentRemaining : null,
        limitingWindowIds: Array.isArray(entry?.limitingWindowIds) ? entry.limitingWindowIds : [],
        runway: {
          status: entry?.runway?.status ?? null,
          usableRunwaySeconds:
            typeof entry?.runway?.usableRunwaySeconds === "number" ? entry.runway.usableRunwaySeconds : null,
          projectedExhaustedAt: entry?.runway?.projectedExhaustedAt ?? null,
          projectionConfidence: entry?.runway?.projectionConfidence ?? null,
        },
      })),
    });
  }
  return { status: "read", schemaVersion: parsed.schemaVersion ?? null, providers };
}

function parseArgs(argv) {
  const options = {
    dir: process.env.FM_PI_SESSIONS_DIR || DEFAULT_SESSIONS_DIR,
    floor: 20,
    summaryOnly: false,
    quotaJson: "",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--sessions-dir") options.dir = argv[++i] ?? options.dir;
    else if (arg === "--min-assistant-messages") {
      const value = Number(argv[++i]);
      if (!Number.isSafeInteger(value) || value < 0) {
        throw new Error("--min-assistant-messages needs a non-negative integer");
      }
      options.floor = value;
    } else if (arg === "--quota-json") options.quotaJson = argv[++i] ?? "";
    else if (arg === "--summary") options.summaryOnly = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return options;
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`fm-pi-session-metrics: ${error.message}\n`);
    process.exit(2);
  }
  const paths = transcriptPaths(options.dir);
  const rows = [];
  for (const path of paths) {
    try {
      rows.push(await readSession(path));
    } catch (error) {
      // An unreadable transcript is reported as one skipped session rather
      // than aborting: a partial baseline is still evidence, and the count of
      // what was skipped is what tells the reader how partial it is.
      process.stderr.write(`fm-pi-session-metrics: skipped one unreadable transcript (${error.code || "error"})\n`);
    }
  }
  rows.sort((a, b) => b.cacheReadTokens - a.cacheReadTokens);
  const report = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    baseline: summarize(rows, options.floor),
  };
  if (options.quotaJson) {
    let raw = "";
    try {
      raw = readFileSync(options.quotaJson, "utf8");
    } catch {
      raw = "";
    }
    report.quota = projectQuota(raw);
  }
  if (!options.summaryOnly) report.sessions = rows;
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

await main();
