// Scripted stand-in for Pi's TUI, used to show what the captain actually sees
// while the observe-only idle detector runs. Renders every status-bar write and
// notification with the elapsed time at which Pi would have painted it.
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const extension = await import(pathToFileURL(process.env.EXT).href);
const t0 = Date.now();
const at = () => `t+${String((Date.now() - t0) / 1000).padStart(5, " ")}s`;
const say = (line) => console.log(`${at()}  ${line}`);

const handlers = new Map();
let terminalHandler;

const ctx = {
  mode: process.env.MODE || "tui",
  ui: {
    setStatus(_key, text) {
      say(text === undefined ? "status bar  [ empty ]" : `status bar  | ${text} |`);
    },
    notify(message, level) {
      say(`notification (${level})  ${message}`);
    },
    onTerminalInput(handler) {
      say("pi          extension subscribed to raw terminal input");
      terminalHandler = handler;
      return () => {
        say("pi          raw terminal listener removed");
        terminalHandler = undefined;
      };
    },
  },
};

extension.default({ on: (event, handler) => (handlers.set(event, handler), () => {}) });
const fire = (event) => handlers.get(event)?.({ type: event }, ctx);

say(`pi          session_start (mode=${ctx.mode})`);
fire("session_start");

for (const action of (process.env.ACTIONS || "").split(",").filter(Boolean)) {
  const [verb, ...rest] = action.split(":");
  if (verb === "wait") await new Promise((r) => setTimeout(r, Number(rest[0])));
  else if (verb === "raw") {
    say(`captain     types ${JSON.stringify(rest.join(":"))} (raw terminal byte)`);
    const out = terminalHandler?.(rest.join(":"));
    say(`pi          bytes handed back to pi: ${out === undefined ? "unchanged" : JSON.stringify(out)}`);
  } else if (verb === "input") {
    say(`pi          input event, source=${rest[0]}, text=${JSON.stringify(rest.slice(1).join(":"))}`);
    handlers.get("input")?.({ type: "input", source: rest[0], text: rest.slice(1).join(":") }, ctx);
  } else if (verb === "lock") writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
  else if (verb === "shutdown") { say("pi          session_shutdown"); fire("session_shutdown"); }
}
process.exit(0);
