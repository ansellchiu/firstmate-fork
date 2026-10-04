# Pi Headroom tool-result arm

Audience: operator current.

Headroom is a Pi-local extension that measures tool-result payloads and can conservatively reduce repeated output before Pi sends the result to the model.
It runs inside Pi through the `tool_result` event.
It does not proxy provider traffic, inspect credentials, alter authentication, route another agent through a wrapper, or enable MCP.

## Enable one run

Headroom is off by default.
An ordinary `pi` launch does not register the retrieval tool, write measurements, or modify a tool result.

Use one of these explicit modes for a Pi process:

```sh
pi --headroom baseline
pi --headroom transform
```

`baseline` measures each result and returns it unchanged.
`transform` measures each result and folds only consecutive identical non-empty text lines from a fold-eligible tool class, when the replacement is smaller.
The marker preserves the repeated line, its exact multiplicity, and the result id needed to retrieve the original.
All non-text content, the result error state, result details, and tool usage remain unchanged.
Results that cannot be reduced safely remain unchanged.

### Folding thresholds

Headroom folds a run of identical lines only when both thresholds hold:

- the repeated line is at least **16 characters** long, and
- that exact line repeats at least **3 times** consecutively.

A shorter line or a run of two is left untouched, because the multiplicity marker costs more than the run it would replace.
Headroom also checks the byte cost of the whole replacement and returns the original result whenever the folded form is not smaller.

### Which tools fold

Folding eligibility is decided by tool class, not by inspecting the content.

Only log- and prose-shaped output is eligible to fold, because collapsing an identical run of log lines does not change what the tool reported.
`bash` and `powershell` are the only producers currently in that class, so they are the only tools that fold today.

These tools never fold, and the reason is the same for all of them: their results carry byte-exact bytes or line-addressed evidence that the model acts on directly.

- `read` returns raw file bytes that the model addresses with `offset` and `limit`, so folding repeated lines would shift every later line number and a whole-file read could silently lose lines.
- `grep` returns matching lines with file paths and line numbers, `find` returns file paths, and `ls` returns directory entries, so each line is a distinct addressable result.
- `edit` and `write` report the change they made.
- `fm_headroom_original` must return an untouched original.

Every unrecognized tool, including MCP and extension tools, is treated as exact and never folds.
Adding a tool to the folding class is a code change to the allowlist in the extension, never a runtime setting.

Disable Headroom by omitting `--headroom` or by passing `--headroom off`.
No user-scope or project-scope setting enables it.
Any other `--headroom` value is rejected: Headroom warns that the session is not instrumented and stays off.

## Original-result retrieval

An opted-in session registers `fm_headroom_original`.
When a transformed result carries an id such as `hr-9f3c2a10-1`, the model can call that tool with the id to receive the exact original content.
The id carries a nonce minted at each session start, so an id issued before a `/reload` never resolves against the reloaded session's originals; retrieval reports it as unavailable instead of returning a different result.
Original content stays only in process memory and is cleared at the next Pi session start.
It is never written to the Headroom measurement record.

Retrieval is exact only for results the current session still holds.
Every other id, including one issued before a `/reload` or by an earlier Pi process, is reported as unavailable; there is no history beyond the running session.

Retention has a cost the operator should plan for.
A transform session keeps the raw content of every folded result in Pi's process memory for the whole session, with no eviction, and releases it only when that session ends or the next one starts.
A long always-on transform session therefore grows its memory footprint with every fold.
Run the arm for bounded comparisons instead.

## Measurement record

Each opted-in run writes one mode-`0600` JSON document under `FM_STATE_OVERRIDE/extensions/pi-headroom/`.
Without that override it writes under `state/extensions/pi-headroom/` in the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path.
The document records no tool arguments or tool-result content.
Its session identifier, pairing key, and filenames are digests or generated identifiers.

Every result row contains:

- `rawBytes` and `transformedBytes`, measured from the UTF-8 JSON serialization of the content array.
- `rawTokens` and `transformedTokens`, measured with Pi's exported `estimateTokens` function.
- `compressionRatio`, calculated as transformed bytes divided by raw bytes.
- `toolLatencyMs`, measured from Pi's `tool_execution_start` event to its `tool_result` event.
- `modelLatencyMs`, measured from the next Pi `turn_start` event through that response's finalized assistant message.
- `truncations`, counting Pi's explicit truncation indicators on the source result.
- `sourceOmissions`, counting how many of Pi's result-limit indicators (`entryLimitReached`, `matchLimitReached`, `resultLimitReached`) the source result carried, so `0`-`3` per row. It counts indicators, not omitted items, because Pi does not report how many items each limit dropped.
- `foldedLines`, counting the identical repeated lines Headroom itself replaced with a multiplicity marker, so it is `0` on every row whose `foldDecision` is not `applied`. Only this field is attributable to Headroom; never add it to `sourceOmissions`, which is measured in a different unit.
- `toolClass`, either `log` for a fold-eligible producer or `exact` for a byte-exact, line-addressed, or unrecognized tool.
- `foldEligible`, true only for the `log` class.
- `foldDecision`, one of `applied` (a smaller folded result was delivered), `mode-baseline` (baseline mode never folds), `tool-class-excluded` (this tool's class never folds), `no-repetition` (no run met both thresholds), or `not-smaller` (a candidate run existed but folding did not shrink the payload).
- `pairingKey`, a digest of the tool name, tool input, and original result that lets a comparison pair equivalent baseline and transformed rows without retaining their content.

`modelLatencyMs` remains `null` when the run ends before a following model response completes.
A result still awaiting a model response when the agent run ends is released at `agent_end`, so it never takes its latency from a later run.
The extension writes a provisional row before returning any transformed result and atomically updates it when the following model response finishes.
If initialization or provisional measurement fails, Headroom disables itself, warns the operator, and returns no patch, so Pi delivers the original result.

## Interpretation

The record is ready for a bounded paired baseline-versus-transformed comparison.
Compare baseline and transformed rows through `pairingKey`, and separate folded from unfolded payloads through `toolClass` and `foldDecision` so a `log`-class row that was excluded or not smaller is never counted as a failed fold.
Attribute reduction to Headroom through `foldedLines` alone; `truncations` and `sourceOmissions` describe loss Pi had already applied to both arms of a pair.
No compression figure has been measured yet.
A byte or token ratio by itself is not evidence that model behavior, latency, or cost improved.
