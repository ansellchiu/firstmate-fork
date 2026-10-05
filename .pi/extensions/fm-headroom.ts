// Pi-local Headroom arm.
//
// The extension is inert unless one Pi process explicitly starts with
// `--headroom baseline` or `--headroom transform`.
// Baseline measures without changing tool results.
// Transform only folds consecutive identical text lines from fold-eligible
// tool classes when the replacement is smaller, preserves their exact
// multiplicity in the marker, and keeps the original content in memory for
// retrieval during the current Pi session.
//
// Folding eligibility is decided by tool class, never by inspecting content.
// Pi's `read` returns raw file bytes addressed by `offset`/`limit`, and `grep`,
// `find`, `ls`, `edit`, and `write` results carry line numbers, paths, or diffs
// the model addresses as evidence. Folding repeated lines in any of them would
// shift later line numbers or silently drop lines, so they never fold.
// Only log-shaped tool output folds today; `bash` and `powershell` are the
// eligible producers, and every unrecognized tool is treated as exact by
// default. See docs/pi-headroom.md.
//
// Metrics contain measurements and digests, never tool arguments or result
// content. They are written as one session-scoped JSON document under
// state/extensions/pi-headroom. A result's model latency is the full model
// response immediately after that result, from Pi's turn start through the
// finalized assistant message.
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  estimateTokens,
  type ExtensionAPI,
  type ExtensionContext,
  type ToolResultEvent,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type HeadroomMode = "off" | "baseline" | "transform";
type ToolContent = ToolResultEvent["content"];
type ToolClass = "log" | "exact";
type FoldDecision =
  | "applied"
  | "mode-baseline"
  | "tool-class-excluded"
  | "no-repetition"
  | "not-smaller";

type OriginalResult = {
  content: ToolContent;
  isError: boolean;
  toolName: string;
};

type Measurement = {
  resultId: string;
  pairingKey: string;
  sequence: number;
  toolName: string;
  mode: Exclude<HeadroomMode, "off">;
  toolClass: ToolClass;
  foldEligible: boolean;
  foldDecision: FoldDecision;
  transformed: boolean;
  rawBytes: number;
  rawTokens: number;
  transformedBytes: number;
  transformedTokens: number;
  compressionRatio: number;
  toolLatencyMs: number | null;
  modelLatencyMs: number | null;
  truncations: number;
  sourceOmissions: number;
  foldedLines: number;
};

type SessionRecord = {
  schemaVersion: 1;
  session: string;
  mode: Exclude<HeadroomMode, "off">;
  tokenEstimator: "pi-estimateTokens";
  byteEncoding: "utf8-json";
  createdAt: string;
  results: Measurement[];
};

type Compression = {
  content: ToolContent;
  omissions: number;
  decision: Extract<FoldDecision, "applied" | "no-repetition" | "not-smaller">;
};

// Folding thresholds. A line must be at least this long and repeat at least
// this many times before Headroom considers replacing the run.
const MIN_FOLDABLE_LINE_CHARS = 16;
const MIN_FOLDABLE_REPEATS = 3;

// The only tools whose results are log- or prose-shaped enough that collapsing
// an identical run does not change what the tool reported. Byte-exact and
// line-addressed tools are deliberately absent, and unknown tools stay exact.
const FOLD_ELIGIBLE_TOOLS = new Set(["bash", "powershell"]);

function toolClassOf(toolName: string): ToolClass {
  return FOLD_ELIGIBLE_TOOLS.has(toolName) ? "log" : "exact";
}

type RetrievalDetails = {
  found: boolean;
  resultId: string;
  sourceTool: string | null;
  sourceWasError: boolean | null;
};

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const metricsDir = `${state}/extensions/pi-headroom`;

function elapsedMs(startedAt: number | undefined): number | null {
  if (startedAt === undefined) return null;
  return Math.max(0, Math.round((performance.now() - startedAt) * 1000) / 1000);
}

function serialized(value: unknown): string {
  return JSON.stringify(value);
}

function payloadBytes(content: ToolContent): number {
  return Buffer.byteLength(serialized(content), "utf8");
}

function payloadTokens(content: ToolContent): number {
  return estimateTokens({
    role: "toolResult",
    toolCallId: "headroom-measurement",
    toolName: "headroom-measurement",
    content,
    isError: false,
    timestamp: 0,
  });
}

function cloneContent(content: ToolContent): ToolContent {
  return structuredClone(content);
}

function compressText(
  text: string,
  resultId: string,
): { text: string; omissions: number; repeats: boolean } {
  const lines = text.split("\n");
  const output: string[] = [];
  let omissions = 0;
  let repeats = false;
  for (let index = 0; index < lines.length;) {
    const line = lines[index];
    let end = index + 1;
    while (end < lines.length && lines[end] === line) end += 1;
    const count = end - index;
    if (line.length >= MIN_FOLDABLE_LINE_CHARS && count >= MIN_FOLDABLE_REPEATS) {
      repeats = true;
      const marker =
        `[Headroom: preceding line repeated ${count - 1} additional times; ` +
        `exact original available from fm_headroom_original with id "${resultId}"]`;
      const original = Array(count).fill(line).join("\n");
      const folded = `${line}\n${marker}`;
      if (Buffer.byteLength(folded, "utf8") < Buffer.byteLength(original, "utf8")) {
        output.push(line, marker);
        omissions += count - 1;
        index = end;
        continue;
      }
    }
    output.push(...lines.slice(index, end));
    index = end;
  }
  return { text: output.join("\n"), omissions, repeats };
}

function compressContent(content: ToolContent, resultId: string): Compression {
  let omissions = 0;
  let repeats = false;
  const candidate = content.map((part) => {
    if (part.type !== "text") return structuredClone(part);
    const compressed = compressText(part.text, resultId);
    omissions += compressed.omissions;
    if (compressed.repeats) repeats = true;
    return { ...part, text: compressed.text };
  });
  if (omissions === 0) {
    return {
      content: cloneContent(content),
      omissions: 0,
      decision: repeats ? "not-smaller" : "no-repetition",
    };
  }
  if (payloadBytes(candidate) >= payloadBytes(content)) {
    return { content: cloneContent(content), omissions: 0, decision: "not-smaller" };
  }
  return { content: candidate, omissions, decision: "applied" };
}

function requestedMode(value: boolean | string | undefined): HeadroomMode | null {
  if (value === undefined || value === "off") return "off";
  if (value === "baseline" || value === "transform") return value;
  return null;
}

function sourceLossCounts(details: unknown): { truncations: number; omissions: number } {
  if (!details || typeof details !== "object") return { truncations: 0, omissions: 0 };
  const value = details as Record<string, unknown>;
  const truncation = value.truncation;
  let truncations =
    truncation && typeof truncation === "object" &&
      (truncation as Record<string, unknown>).truncated === true
      ? 1
      : 0;
  if (value.linesTruncated === true) truncations += 1;
  const omissions = ["entryLimitReached", "matchLimitReached", "resultLimitReached"]
    .filter((key) => typeof value[key] === "number").length;
  return { truncations, omissions };
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag("headroom", {
    description: "Pi-local tool-result measurement: baseline or transform (default: off)",
    type: "string",
    default: "off",
  });

  let mode: HeadroomMode = "off";
  let record: SessionRecord | null = null;
  let recordPath = "";
  let sequence = 0;
  let sessionNonce = "";
  let retrievalRegistered = false;
  let modelStartedAt: number | undefined;
  let resultsAwaitingModel: string[] = [];
  let resultsInModelTurn: string[] = [];
  const toolStartedAt = new Map<string, number>();
  const originals = new Map<string, OriginalResult>();

  function persist(): void {
    if (!record || !recordPath) throw new Error("Headroom session record is not initialized");
    mkdirSync(metricsDir, { recursive: true, mode: 0o700 });
    const temporary = `${recordPath}.tmp-${process.pid}`;
    writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporary, recordPath);
  }

  function disableAfterFailure(ctx: ExtensionContext, error: unknown): void {
    mode = "off";
    const detail = error instanceof Error ? error.message : String(error);
    ctx.ui.notify(
      `Headroom disabled after an instrumentation failure; subsequent tool results are unchanged: ${detail}`,
      "warning",
    );
  }

  function ensureRetrievalTool(): void {
    if (retrievalRegistered) return;
    retrievalRegistered = true;
    const parameters = Type.Object({
      id: Type.String({ description: "Headroom result id shown in a transformed tool result." }),
    });
    pi.registerTool<typeof parameters, RetrievalDetails>({
      name: "fm_headroom_original",
      label: "Retrieve original tool result",
      description:
        "Retrieve the exact original content for a tool result transformed by the Pi-local Headroom arm in this session.",
      parameters,
      execute: async (_toolCallId, params) => {
        const original = originals.get(params.id);
        if (!original) {
          return {
            content: [{
              type: "text",
              text: `Headroom original "${params.id}" is not available in this session.`,
            }],
            details: {
              found: false,
              resultId: params.id,
              sourceTool: null,
              sourceWasError: null,
            },
            isError: true,
          };
        }
        return {
          content: cloneContent(original.content),
          details: {
            found: true,
            resultId: params.id,
            sourceTool: original.toolName,
            sourceWasError: original.isError,
          },
          isError: false,
        };
      },
    });
  }

  pi.on("session_start", (_event, ctx) => {
    const flagValue = pi.getFlag("headroom");
    const requested = requestedMode(flagValue);
    mode = requested ?? "off";
    record = null;
    recordPath = "";
    sequence = 0;
    sessionNonce = randomBytes(4).toString("hex");
    modelStartedAt = undefined;
    resultsAwaitingModel = [];
    resultsInModelTurn = [];
    toolStartedAt.clear();
    originals.clear();
    if (requested === null) {
      ctx.ui.notify(
        `Headroom ignored an unrecognized --headroom value ${JSON.stringify(flagValue)}; ` +
          "use off, baseline, or transform. This session is not instrumented.",
        "warning",
      );
    }
    if (mode === "off") return;

    const sessionId = ctx.sessionManager.getSessionId();
    const session = createHash("sha256").update(sessionId).digest("hex").slice(0, 16);
    const startedAt = new Date();
    record = {
      schemaVersion: 1,
      session,
      mode,
      tokenEstimator: "pi-estimateTokens",
      byteEncoding: "utf8-json",
      createdAt: startedAt.toISOString(),
      results: [],
    };
    recordPath = `${metricsDir}/${session}-${startedAt.getTime()}-${process.pid}.json`;
    try {
      persist();
      ensureRetrievalTool();
      ctx.ui.setStatus("headroom", `headroom: ${mode}`);
    } catch (error) {
      disableAfterFailure(ctx, error);
    }
  });

  pi.on("agent_end", () => {
    if (mode === "off") return;
    resultsAwaitingModel = [];
    resultsInModelTurn = [];
    modelStartedAt = undefined;
  });

  pi.on("tool_execution_start", (event) => {
    if (mode === "off") return;
    toolStartedAt.set(event.toolCallId, performance.now());
  });

  pi.on("turn_start", () => {
    if (mode === "off") return;
    modelStartedAt = performance.now();
    if (resultsAwaitingModel.length > 0) {
      resultsInModelTurn = resultsAwaitingModel;
      resultsAwaitingModel = [];
    }
  });

  pi.on("message_end", (event, ctx) => {
    if (mode === "off" || event.message.role !== "assistant" || !record) return;
    const modelLatencyMs = elapsedMs(modelStartedAt);
    modelStartedAt = undefined;
    if (resultsInModelTurn.length === 0) return;
    const resultIds = new Set(resultsInModelTurn);
    resultsInModelTurn = [];
    for (const measurement of record.results) {
      if (resultIds.has(measurement.resultId)) measurement.modelLatencyMs = modelLatencyMs;
    }
    try {
      persist();
    } catch (error) {
      disableAfterFailure(ctx, error);
    }
  });

  pi.on("tool_result", (event, ctx) => {
    if (mode === "off" || !record) return undefined;

    const resultId = `hr-${sessionNonce}-${++sequence}`;
    let transformedContent: ToolContent;
    let foldedLines = 0;
    let transformed = false;
    let foldDecision: FoldDecision;
    let rawContent: ToolContent;
    const toolClass = toolClassOf(event.toolName);
    try {
      rawContent = cloneContent(event.content);
      const rawJson = serialized(rawContent);
      const rawBytes = Buffer.byteLength(rawJson, "utf8");
      const rawTokens = payloadTokens(rawContent);
      let transformedBytes = rawBytes;
      let transformedTokens = rawTokens;
      if (mode !== "transform") {
        transformedContent = rawContent;
        foldDecision = "mode-baseline";
      } else if (toolClass !== "log") {
        // Byte-exact, line-addressed, and unrecognized tools keep their result.
        transformedContent = rawContent;
        foldDecision = "tool-class-excluded";
      } else {
        const compressed = compressContent(rawContent, resultId);
        transformedContent = compressed.content;
        foldedLines = compressed.omissions;
        transformed = compressed.decision === "applied";
        foldDecision = compressed.decision;
        transformedBytes = payloadBytes(transformedContent);
        transformedTokens = payloadTokens(transformedContent);
      }

      const sourceLoss = sourceLossCounts(event.details);
      const measurement: Measurement = {
        resultId,
        pairingKey: createHash("sha256")
          .update(event.toolName)
          .update("\0")
          .update(serialized(event.input))
          .update("\0")
          .update(rawJson)
          .digest("hex"),
        sequence,
        toolName: event.toolName,
        mode,
        toolClass,
        foldEligible: toolClass === "log",
        foldDecision,
        transformed,
        rawBytes,
        rawTokens,
        transformedBytes,
        transformedTokens,
        compressionRatio: rawBytes === 0
          ? 1
          : Math.round((transformedBytes / rawBytes) * 1_000_000) / 1_000_000,
        toolLatencyMs: elapsedMs(toolStartedAt.get(event.toolCallId)),
        modelLatencyMs: null,
        truncations: sourceLoss.truncations,
        sourceOmissions: sourceLoss.omissions,
        foldedLines,
      };
      toolStartedAt.delete(event.toolCallId);
      record.results.push(measurement);
      resultsAwaitingModel.push(resultId);
      persist();
      if (transformed) {
        originals.set(resultId, {
          content: rawContent,
          isError: event.isError,
          toolName: event.toolName,
        });
        return { content: transformedContent };
      }
      return undefined;
    } catch (error) {
      toolStartedAt.delete(event.toolCallId);
      record.results = record.results.filter((item) => item.resultId !== resultId);
      resultsAwaitingModel = resultsAwaitingModel.filter((id) => id !== resultId);
      originals.delete(resultId);
      disableAfterFailure(ctx, error);
      return undefined;
    }
  });
}
