#!/usr/bin/env node
// Reporting core for bin/fm-quota-unmetered.sh: read the credential, make one
// hard-bounded call per provider, and normalize the answer into quota-axi's
// schema version 3 provider record.
//
// bin/fm-quota-unmetered.sh is the transport and the authoritative owner of the
// operator-facing contract (flags, environment, exit status, and what each
// provider can and cannot report). This file owns only the wire mapping, and
// the two must not restate each other.
//
// The credential is read here and stays here. It is never written to disk,
// never placed in an argv, and never included in output; raw provider responses
// are classified here and never printed. That is why the fetch lives in this
// process rather than in a `curl` invocation, whose argv or config file would
// expose the key to any other local process.
//
// The single rule this file exists to enforce: a provider that does not publish
// usage is reported as unknown, never inferred. Nothing below synthesizes a
// window, a percentage, a reset, or a plan. Every field is either copied from
// the provider's own response or arithmetic over fields it returned, and any
// unrecognized shape degrades to an explicit unknown rather than a guess.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const SCHEMA_VERSION = 3;
const KNOWN_PROVIDERS = ["zai", "deepseek", "gemini"];

const DEFAULT_AUTH_FILE = join(homedir(), ".pi", "agent", "auth.json");

// Verified 2026-08-19 against the live endpoints; see
// docs/verification/dispatch-auth.md.
const ENDPOINTS = {
  zai:
    process.env.FM_QUOTA_UNMETERED_ZAI_URL ||
    "https://api.z.ai/api/monitor/usage/quota/limit",
  deepseek:
    process.env.FM_QUOTA_UNMETERED_DEEPSEEK_URL ||
    "https://api.deepseek.com/user/balance",
};

const ENV_KEYS = {
  zai: ["ZAI_API_KEY", "Z_AI_API_KEY"],
  deepseek: ["DEEPSEEK_API_KEY"],
};

const LABELS = { zai: "Z.ai GLM", deepseek: "DeepSeek", gemini: "Gemini (agy)" };

const timeoutSeconds = Number.parseInt(
  process.env.FM_QUOTA_UNMETERED_TIMEOUT || "20",
  10,
);
const TIMEOUT_MS =
  Number.isInteger(timeoutSeconds) && timeoutSeconds > 0
    ? timeoutSeconds * 1000
    : 20000;

// --- credential resolution --------------------------------------------------

function readAuthStore() {
  const path = process.env.FM_QUOTA_UNMETERED_AUTH_FILE || DEFAULT_AUTH_FILE;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return parsed && typeof parsed === "object" ? parsed : null;
  } catch {
    // An absent or unreadable store is not an error: the environment may carry
    // the key, and a provider with no key anywhere is reported as auth_required.
    return null;
  }
}

function resolveKey(provider, store) {
  for (const name of ENV_KEYS[provider]) {
    const value = process.env[name];
    if (typeof value === "string" && value.trim() !== "") {
      return { key: value.trim(), source: `env:${name}` };
    }
  }
  const entry = store && store[provider];
  if (entry && typeof entry.key === "string" && entry.key.trim() !== "") {
    return { key: entry.key.trim(), source: "pi-auth-json" };
  }
  return null;
}

// --- bounded transport ------------------------------------------------------

async function getJson(url, headers) {
  let response;
  try {
    response = await fetch(url, {
      method: "GET",
      headers,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (error) {
    const timedOut = error && (error.name === "TimeoutError" || error.name === "AbortError");
    return {
      ok: false,
      status: "error",
      error: timedOut
        ? `request exceeded the ${TIMEOUT_MS / 1000}s bound`
        : "request failed",
    };
  }
  const text = await response.text().catch(() => "");
  if (!response.ok) {
    // The status code is the fact; the body may carry account detail and is
    // never echoed.
    return {
      ok: false,
      status: response.status === 401 || response.status === 403 ? "auth_required" : "error",
      error: `provider returned HTTP ${response.status}`,
    };
  }
  try {
    return { ok: true, body: JSON.parse(text) };
  } catch {
    return { ok: false, status: "error", error: "provider returned an unparseable body" };
  }
}

// --- shared record builders -------------------------------------------------

function unavailable(provider, { status, error, sourcesTried }) {
  return {
    provider,
    label: LABELS[provider],
    source: "unavailable",
    windows: [],
    state: { status, stale: false, error, sourcesTried },
    quotaSemantics: {
      status: "unknown",
      description:
        "No quota windows are available, so no effective remaining percentage can be computed.",
      effectiveAvailability: [],
    },
  };
}

// --- zai --------------------------------------------------------------------

// Seconds per Z.ai `unit` code. Only codes observed and confirmed against the
// live endpoint are listed; an unlisted code yields a window with no
// windowSeconds and kind `unknown`, because guessing the period would silently
// misreport how much runway is left.
const ZAI_UNIT_SECONDS = { 3: 3600, 6: 604800 };

function zaiWindowShape(unit, number) {
  const unitSeconds = ZAI_UNIT_SECONDS[unit];
  if (!unitSeconds || !Number.isFinite(number) || number <= 0) {
    return { id: `window:u${unit}n${number}`, label: "window", kind: "unknown" };
  }
  const windowSeconds = unitSeconds * number;
  // Ids and labels follow quota-axi's own naming for the same durations, so a
  // consumer reads a 5-hour cycle the same way whichever report it came from.
  if (windowSeconds === 18000) {
    return { id: "five_hour", label: "session", kind: "session", windowSeconds };
  }
  if (windowSeconds === 604800) {
    return { id: "seven_day", label: "week", kind: "weekly", windowSeconds };
  }
  if (windowSeconds <= 86400) {
    return { id: `window:u${unit}n${number}`, label: "session", kind: "session", windowSeconds };
  }
  if (windowSeconds === 2592000 || windowSeconds === 2678400) {
    return { id: "monthly", label: "month", kind: "monthly", windowSeconds };
  }
  return { id: `window:u${unit}n${number}`, label: "window", kind: "unknown", windowSeconds };
}

function buildZaiWindows(limits) {
  const windows = [];
  const seen = new Map();
  for (const limit of limits) {
    if (!limit || typeof limit !== "object") continue;
    const shape = zaiWindowShape(limit.unit, limit.number);
    // Two limits of the same period must not collide onto one id.
    const count = (seen.get(shape.id) || 0) + 1;
    seen.set(shape.id, count);
    const id = count === 1 ? shape.id : `${shape.id}:${count}`;

    const window = { id, label: shape.label, kind: shape.kind };
    if (typeof limit.percentage === "number" && Number.isFinite(limit.percentage)) {
      window.percentUsed = limit.percentage;
      window.percentRemaining = 100 - limit.percentage;
    }
    if (typeof limit.nextResetTime === "number" && Number.isFinite(limit.nextResetTime)) {
      window.resetsAt = new Date(limit.nextResetTime).toISOString();
    }
    if (shape.windowSeconds) window.windowSeconds = shape.windowSeconds;
    // `type` decides whether this window bounds model availability at all.
    window.__type = typeof limit.type === "string" ? limit.type : "";
    windows.push(window);
  }
  return windows;
}

function buildZai(body, credentialSource) {
  const data = body && typeof body === "object" ? body.data : null;
  const limits = data && Array.isArray(data.limits) ? data.limits : null;
  const sourcesTried = [credentialSource, "api"];

  if (!limits) {
    return unavailable("zai", {
      status: "error",
      error: "provider response carried no usage limits",
      sourcesTried,
    });
  }

  const annotated = buildZaiWindows(limits);
  const windows = annotated.map(({ __type, ...window }) => window);

  // Only a CREDIT_LIMIT window with a usable percentage bounds every model. Any
  // other window is reported but left out of the bound and named as unresolved,
  // so a future non-model limit cannot quietly shrink the headroom figure.
  const bounding = annotated.filter(
    (window) => window.__type === "CREDIT_LIMIT" && typeof window.percentRemaining === "number",
  );
  const unresolvedWindowIds = annotated
    .filter((window) => !bounding.includes(window))
    .map((window) => window.id);

  let quotaSemantics;
  if (bounding.length === 0) {
    quotaSemantics = {
      status: "unknown",
      description:
        "No usable quota window was reported, so no effective remaining percentage can be computed.",
      effectiveAvailability: [],
    };
    if (unresolvedWindowIds.length > 0) quotaSemantics.unresolvedWindowIds = unresolvedWindowIds;
  } else {
    const effectivePercentRemaining = Math.min(...bounding.map((w) => w.percentRemaining));
    quotaSemantics = {
      status: unresolvedWindowIds.length > 0 ? "partial" : "known",
      description:
        "Z.ai GLM coding-plan credit windows bound every model on the plan, so the effective remaining percentage is the minimum across them. Pace and runway are not computed here.",
      effectiveAvailability: [
        {
          scope: "all_models",
          status: "known",
          effectivePercentRemaining,
          boundedBy: bounding.map((w) => w.id),
          limitingWindowIds: bounding
            .filter((w) => w.percentRemaining === effectivePercentRemaining)
            .map((w) => w.id),
        },
      ],
    };
    if (unresolvedWindowIds.length > 0) quotaSemantics.unresolvedWindowIds = unresolvedWindowIds;
  }

  const record = {
    provider: "zai",
    label: LABELS.zai,
    source: "api",
    windows,
    quotaSemantics,
    state: {
      status: "fresh",
      stale: false,
      refreshedAt: new Date().toISOString(),
      authStatus: "usable",
      sourcesTried,
    },
  };
  // The plan level is reported only when the provider names it.
  if (data && typeof data.level === "string" && data.level !== "") record.plan = data.level;
  return record;
}

// --- deepseek ---------------------------------------------------------------

// DeepSeek's balance response is the ONLY usage-adjacent surface it publishes.
// It carries no window, no cycle, and no consumed/limit counter, and DeepSeek
// documents its limits as per-account concurrency ceilings that surface only as
// an HTTP 429 at request time. Balance is therefore reported as `credits` and
// quota stays `unknown`; deriving a percentage from money would be an invented
// number that a dispatch decision could act on.
const DEEPSEEK_DESCRIPTION =
  "DeepSeek publishes account balance only. It exposes no usage window, quota cycle, or queryable rate-limit state, so no effective remaining percentage can be computed; its concurrency limits are observable only as an HTTP 429 at request time. Balance is reported as credits and is not a quota measurement.";

function buildDeepseek(body, credentialSource) {
  const sourcesTried = [credentialSource, "api"];
  const infos =
    body && typeof body === "object" && Array.isArray(body.balance_infos)
      ? body.balance_infos
      : null;
  if (!infos) {
    return unavailable("deepseek", {
      status: "error",
      error: "provider response carried no balance information",
      sourcesTried,
    });
  }

  const record = {
    provider: "deepseek",
    label: LABELS.deepseek,
    source: "api",
    windows: [],
    quotaSemantics: {
      status: "unknown",
      description: DEEPSEEK_DESCRIPTION,
      effectiveAvailability: [],
    },
    state: {
      status: "fresh",
      stale: false,
      refreshedAt: new Date().toISOString(),
      authStatus: "usable",
      sourcesTried,
    },
  };

  // quota-axi's credits unit is `usd` or `credits`, so only a USD balance can be
  // reported without relabelling the currency the provider actually returned.
  const usd = infos.find((info) => info && info.currency === "USD");
  const remaining = usd ? Number.parseFloat(usd.total_balance) : Number.NaN;
  if (Number.isFinite(remaining)) {
    record.credits = { remaining, unlimited: false, unit: "usd" };
  }

  // The provider's own verdict that the account can no longer call the API is
  // operationally decisive, so it is surfaced as an unavailable state rather
  // than left for a caller to infer from a balance figure.
  if (body.is_available === false) {
    record.state.status = "unavailable";
    record.state.error = "provider reports the balance is insufficient for API calls";
  }
  return record;
}

// --- gemini -------------------------------------------------------------

// agy (Google's Gemini CLI, branded Antigravity CLI in its own banner)
// authenticates through a local OAuth session, not an API key, and it
// publishes no usage-quota or billing-query endpoint this script can call:
// no Cloud Billing export is wired yet. There is nothing to fetch and no
// credential to resolve, so - unlike zai and deepseek - this provider makes
// no network call at all and is reported entirely from record. It is the
// same honest-unknown shape DeepSeek uses for its balance-only state, one
// step further: DeepSeek can still confirm live auth state from its call,
// this provider cannot, so `authStatus` reflects the captain's confirmed
// OAuth login rather than a live read and says so explicitly.
const GEMINI_DESCRIPTION =
  "agy (Gemini CLI, Antigravity CLI) authenticates via OAuth and publishes no usage-quota or billing-query endpoint this script can call. No Cloud Billing export is wired yet, so no effective remaining percentage can be computed.";

function buildGemini() {
  return {
    provider: "gemini",
    label: LABELS.gemini,
    source: "unmetered",
    windows: [],
    quotaSemantics: {
      status: "unknown",
      description: GEMINI_DESCRIPTION,
      effectiveAvailability: [],
    },
    state: {
      status: "unknown",
      stale: false,
      authStatus: "usable",
      error:
        "agy has no queryable auth or usage endpoint; authStatus reflects the captain's confirmed OAuth login (2026-08-19) rather than a live read",
      sourcesTried: ["captain-confirmed:2026-08-19"],
    },
  };
}

// --- main -------------------------------------------------------------------

async function reportProvider(provider, store) {
  // gemini has no credential to resolve and no endpoint to call.
  if (provider === "gemini") return buildGemini();

  const resolved = resolveKey(provider, store);
  if (!resolved) {
    return unavailable(provider, {
      status: "auth_required",
      error: `no ${provider} API key found in the environment or the Pi agent credential store`,
      sourcesTried: ["env", "pi-auth-json"],
    });
  }

  // Z.ai accepts the raw key in Authorization; DeepSeek requires the Bearer
  // form. Both were confirmed against the live endpoints.
  const headers =
    provider === "zai"
      ? {
          Authorization: resolved.key,
          "Accept-Language": "en-US,en",
          Accept: "application/json",
        }
      : { Authorization: `Bearer ${resolved.key}`, Accept: "application/json" };

  const result = await getJson(ENDPOINTS[provider], headers);
  if (!result.ok) {
    return unavailable(provider, {
      status: result.status,
      error: result.error,
      sourcesTried: [resolved.source, "api"],
    });
  }
  return provider === "zai"
    ? buildZai(result.body, resolved.source)
    : buildDeepseek(result.body, resolved.source);
}

async function main() {
  const requested = process.argv.slice(2);
  const providers = requested.length > 0 ? requested : KNOWN_PROVIDERS;
  const store = readAuthStore();

  // One provider's outage must not hide another's usage, so every requested
  // provider is reported independently.
  const records = await Promise.all(
    providers.map((provider) =>
      reportProvider(provider, store).catch(() =>
        unavailable(provider, {
          status: "error",
          error: "the provider report failed",
          sourcesTried: ["api"],
        }),
      ),
    ),
  );

  process.stdout.write(
    `${JSON.stringify(
      { generatedAt: new Date().toISOString(), schemaVersion: SCHEMA_VERSION, providers: records },
      null,
      2,
    )}\n`,
  );
}

await main();
