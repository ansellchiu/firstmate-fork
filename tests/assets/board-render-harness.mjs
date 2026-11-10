// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [--viewport <px>]
// Without --viewport, prints one JSON document:
//   { stats:[{n,label}], captains_call:[text], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], decisions:[{context,tag,open}], empty, more, error }
// With --viewport, loads the built page in headless Chrome at that width and
// prints { viewport, scrollWidth, clientWidth, signs:[{text,left,right,width,height}] }.
// When no Chrome binary or no global WebSocket is available that mode prints { skip } instead.
import { spawn, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const html = readFileSync(process.argv[2], "utf8");

function findChrome() {
  const fromEnv = process.env.FM_CHROME_BIN;
  if (fromEnv && existsSync(fromEnv)) return fromEnv;
  const bundled = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
  ];
  for (const bin of bundled) {
    if (existsSync(bin)) return bin;
  }
  for (const name of ["google-chrome-stable", "google-chrome", "chromium", "chromium-browser"]) {
    try {
      const found = execFileSync("which", [name], { encoding: "utf8" }).trim();
      if (found) return found;
    } catch {
      // try the next name
    }
  }
  return "";
}

async function measureViewport(htmlPath, viewport) {
  if (typeof globalThis.WebSocket !== "function") return { skip: "node has no global WebSocket" };
  const bin = findChrome();
  if (!bin) return { skip: "chrome not found" };
  const dir = mkdtempSync(join(tmpdir(), "board-layout-"));
  const chrome = spawn(bin, [
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-dev-shm-usage",
    "--window-size=" + viewport + ",900",
    "--user-data-dir=" + join(dir, "profile"),
    "--remote-debugging-port=0",
    "about:blank",
  ], { stdio: ["ignore", "pipe", "pipe"] });
  const stop = async () => {
    if (chrome.exitCode === null && chrome.signalCode === null) chrome.kill("SIGKILL");
    await new Promise((resolve) => {
      if (chrome.exitCode !== null || chrome.signalCode !== null) resolve();
      else chrome.once("exit", () => resolve());
    });
    rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 50 });
  };
  const deadline = setTimeout(() => { chrome.kill("SIGKILL"); }, 20000);
  try {
    let log = "";
    const wsUrl = await new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        reject(new Error("chrome did not open a devtools port"));
      }, 10000);
      const onData = (buf) => {
        log += buf.toString();
        const match = log.match(/ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[^\s]+/);
        if (match && !settled) {
          settled = true;
          clearTimeout(timer);
          resolve(match[0]);
        }
      };
      chrome.stderr.on("data", onData);
      chrome.stdout.on("data", onData);
      chrome.on("exit", (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(new Error("chrome exited " + code));
      });
    });
    const browser = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      browser.addEventListener("open", resolve, { once: true });
      browser.addEventListener("error", () => reject(new Error("devtools socket failed")), { once: true });
    });
    let nextId = 0;
    const pending = new Map();
    const waiters = [];
    browser.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && pending.has(msg.id)) {
        const { resolve, reject } = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
        return;
      }
      for (let i = 0; i < waiters.length; i++) {
        if (waiters[i].match(msg)) {
          const waiter = waiters.splice(i, 1)[0];
          waiter.resolve(msg);
          break;
        }
      }
    });
    const send = (method, params, sessionId) => {
      const id = ++nextId;
      const payload = { id, method, params: params || {} };
      if (sessionId) payload.sessionId = sessionId;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        browser.send(JSON.stringify(payload));
      });
    };
    const waitFor = (match) => new Promise((resolve) => waiters.push({ match, resolve }));
    try {
      const targets = await send("Target.getTargets");
      const page = targets.targetInfos.find((t) => t.type === "page");
      if (!page) throw new Error("chrome opened no page");
      const attached = await send("Target.attachToTarget", { targetId: page.targetId, flatten: true });
      const sessionId = attached.sessionId;
      await send("Emulation.setDeviceMetricsOverride", {
        width: viewport,
        height: 900,
        deviceScaleFactor: 1,
        mobile: true,
      }, sessionId);
      await send("Page.enable", {}, sessionId);
      const loaded = waitFor((msg) => msg.sessionId === sessionId && msg.method === "Page.loadEventFired");
      await send("Page.navigate", { url: pathToFileURL(htmlPath).href }, sessionId);
      await Promise.race([
        loaded,
        new Promise((_, reject) => setTimeout(() => reject(new Error("board page did not load")), 8000)),
      ]);
      const evaluated = await send("Runtime.evaluate", {
        expression: `(() => new Promise((resolve) => {
          const finish = () => {
            const signs = [...document.querySelectorAll(".bb-section__head .fm-sign")].map((el) => {
              const r = el.getBoundingClientRect();
              return {
                text: (el.textContent || "").trim(),
                left: Math.round(r.left),
                right: Math.round(r.right),
                width: Math.round(r.width),
                height: Math.round(r.height)
              };
            });
            resolve({
              scrollWidth: document.documentElement.scrollWidth,
              clientWidth: document.documentElement.clientWidth,
              signs
            });
          };
          const fonts = document.fonts && document.fonts.ready;
          if (!fonts) { finish(); return; }
          Promise.race([fonts, new Promise((r) => setTimeout(r, 2000))]).then(finish, finish);
        }))()`,
        awaitPromise: true,
        returnByValue: true,
      }, sessionId);
      if (evaluated.exceptionDetails) {
        throw new Error(evaluated.exceptionDetails.text || "layout evaluation failed");
      }
      return { viewport, ...evaluated.result.value };
    } finally {
      browser.close();
    }
  } finally {
    clearTimeout(deadline);
    await stop();
  }
}

const viewportFlag = process.argv.indexOf("--viewport");
if (viewportFlag !== -1) {
  const viewport = Number(process.argv[viewportFlag + 1]);
  if (!Number.isInteger(viewport) || viewport < 1) {
    process.stderr.write("viewport must be a positive integer\n");
    process.exit(1);
  }
  try {
    const measured = await measureViewport(process.argv[2], viewport);
    process.stdout.write(JSON.stringify(measured) + "\n");
  } catch (err) {
    process.stderr.write(String(err && err.message ? err.message : err) + "\n");
    process.exit(1);
  }
  process.exit(0);
}

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, force) => {
        const classes = new Set(this.className.split(/\s+/).filter(Boolean));
        const enabled = force ?? !classes.has(c);
        if (enabled) classes.add(c); else classes.delete(c);
        this.className = [...classes].join(" ");
        return enabled;
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener() {}
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);
const captains_call = (byId.get("bb-call") || new Node("div")).children
  .filter((n) => n.className.split(/\s+/).includes("bb-decision"))
  .map((n) => n.textContent);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

// Decision cards: the progressive-disclosure block each one rendered, if any.
const cardsRoot = [...byId.values()].find((n) => n.querySelectorAll(".bb-decision").length) || new Node("div");
const decisions = cardsRoot.querySelectorAll(".bb-decision").map((card) => {
  const more = card.querySelectorAll("bb-more")[0];
  return {
    context: more ? more.children.find((c) => c.className.includes("bb-more__body"))?.textContent ?? null : null,
    tag: more?.tagName ?? null,
    open: more ? more.attributes.open !== undefined : null,
  };
});

process.stdout.write(
  JSON.stringify({ stats, captains_call, underway, charted, decisions, empty, more, error: errorText }) + "\n");
