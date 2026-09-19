# Verification: pi composer shapes while an agent run is under way

Active empirical record of what a REAL pi pane renders while it is generating, and of the two readings Firstmate takes from it: the composer verdict (`bin/fm-composer-lib.sh`) and the delivery busy state (`FM_DELIVERY_PI_BUSY_SHAPES`).
It exists because pi has already moved this rendering once, silently, and both readings broke when it did.

Refresh this record from `tests/fm-pi-working-composer-live-e2e.test.sh` after any pi upgrade.
When that guard fails, re-take the captures in `tests/assets/pi-0.85-composer/` with the procedure below rather than adjusting the classifier to a guessed shape.
`tests/fm-pi-primary-live-e2e.test.sh` (opt-in, credentialed) pins the same border shape from the other side: absent from a generating Calm pane, and present on a stock turn as its positive control, so a third move of pi's indicator fails there too rather than turning that Calm check quietly green.

## Verified version

| date | pi version | presentation | terminal |
|---|---|---|---|
| 2026-09-11 | 0.85.1 | stock | tmux, 120x40 |
| 2026-09-11 | 0.85.1 | Calm on (`config/calm` = `on`) | tmux, 120x40 |

## What pi renders while generating

Pi >= 0.85 does not draw a working row inside its composer separator pair.
It embeds the working indicator in the composer's own TOP border, so the opening rule stops being a solid rule:

```
── ⠸ Working ───────────────────────────────────────────────────────────────
                                                        <- composer region, BLANK
────────────────────────────────────────────────────────────────────────────
```

The vendor composition is `"── " + <status indicator> + " " + "─".repeat(...)`, built by `CustomEditor.renderTopBorder` delegating to `WorkingStatusIndicator.renderInBorder` (pi 0.85.1 bundle).
The status begins with the indicator's spinner cell; `defaultWorkingMessage` is `Working`, with no ellipsis.
A terminal too narrow for the message falls back to `renderSpinnerInBorder`, a spinner with no message at all.

With Calm on, Calm clears that indicator, so the opening rule is solid again and the animated boat is drawn ABOVE the pair:

```
                  <|
-~~~-~~~-~~~-~~~-\__/~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~
────────────────────────────────────────────────────────────────────────────
                                                        <- composer region, BLANK
────────────────────────────────────────────────────────────────────────────
```

**In both presentations the composer region is blank while pi generates.**
A generating pi never holds unsubmitted input, and it is never correct to read one as holding a half-typed message.

## What that broke, measured

Both readings failed on pi 0.85.1 before the fix, and both were measured against the captures and against a live pane:

| reading | before | after |
|---|---|---|
| composer scan, stock generating pane | pair not found at all (the titled rule is not a solid rule), verdict `unknown` | pair found, region proven blank, verdict still `unknown` - a titled opener is refused `empty` (see below) |
| composer scan, Calm-on generating pane | pair found, region blank | unchanged |
| herdr's rendered busy read, either presentation | `idle` (the `Working\.\.\.` token requires an ellipsis pi 0.85 does not render) | `busy` |
| `fm_pane_busy_state <pane> pi` (tmux), either presentation | `idle` | `idle`, unchanged - see the scoping note below |
| `fm_tmux_submit_core` on a steer that really landed, stock | `unknown` (unconfirmed), delivered once | unchanged - the titled opener keeps the composer from reading cleared, and no busy shape is active on this plane |
| `fm_tmux_submit_core` on a steer that really landed, Calm on | `unknown` (unconfirmed) | `empty` (confirmed), delivered once - from the readable composer, not from a busy reading |

The last row is the production symptom: an unconfirmed submit is what makes the away-mode daemon preserve its escalation buffer and re-inject a digest that has already landed (`data/afk-inject-rca-s1/report.md`).

## The busy shapes are scoped to the Herdr adapter

`FM_DELIVERY_PI_BUSY_SHAPES` is defined in `bin/fm-composer-lib.sh` but is in no default regex.
A reader opts into it by passing `+pi-shapes` to `fm_busy_lines_match`, and `fm_backend_herdr_rendered_busy_state` is the only reader that does.

The scoping is by BACKEND, not by harness.
`fm_backend_herdr_rendered_busy_state` passes no harness at any of its call sites, so what it actually reads is the harness-less union widened by these shapes, and they are therefore consulted for every Herdr pane regardless of the harness it runs.
Narrowing them to the pi harness is deliberately withheld: no captured non-pi row matches `── <non-alphanumeric> … ────────`, so nothing has demonstrated the need, and this task activates nothing without captured proof.
A captured false match on a non-pi harness is what would justify threading the native agent identity into that read.

Herdr's submit core is the only one with a branch that pairs a busy reading with a pre-Enter composer read proving the composer owned the keyboard - its native idle-to-busy transition proof - which is why its delivery read is the only reader allowed to consult these shapes.
The narrowing is on that branch alone.
The footer-transition branch and the final queued-Enter read consume the same shape-aware busy state with no composer pairing; each is gated instead on a pre-Enter footer baseline, which these shapes make accurate for pi rather than less so.
That baseline answers whether the pane was already mid-turn, which is a different question from whether a still-occupied composer means the Enter was queued - so both branches additionally route their `pending + busy` conversion through `fm_composer_queued_enter_verdict`, which excludes pi for the reason below.
The tmux submit core has no such narrowing: on a stock pi parked on the modal captured below it would read an idle baseline, type into the modal, lose the Enter to it, and then read the turn the answered modal started as proof of a delivery that never happened.
So the tmux pi path is unchanged by this record, and a generating pi still reads `idle` there.

Pi is also excluded from the shared queued-Enter conversion (`fm_composer_queued_enter_verdict`) **on the Herdr adapter only**.
That conversion's premise is OpenCode 1.18.4's: a mid-turn Enter is accepted and QUEUED while the typed text stays visible.
Nothing captured here establishes that for pi; what was observed instead is that pi 0.85.1 renders a `Steering:` row and CLEARS its composer on an accepted mid-turn submit, which is not the retain-and-queue shape at all.
So for pi, a composer that still holds our text after the Enter is evidence AGAINST delivery, not evidence of a queued delivery.
A capture of pi's mid-turn Enter behavior is what would lift that exclusion.

The exclusion applies at **both** sites of that conversion, not only the retries-exhausted one.
The Herdr submit core writes the same `pending + busy -> delivered` rule a second time in its footer-transition branch, where the rendered footer can carry the proof early, and `+pi-shapes` is what makes that branch's busy read reachable for a generating pi at all.
A pi composer holding content classifies `pending` for every `agent_status` - `unknown`, `idle`, `working`, and `blocked` alike - so the branch is reachable from any non-idle pre-Enter baseline.
That branch therefore asks `fm_composer_queued_enter_verdict` rather than converting inline, which keeps one owner for the policy and applies the exclusion in both places.
The cost is a narrowing: a pi submit the footer-transition branch used to confirm now stays unconfirmed, and the durable steering inbox re-rings it.

The exclusion is driven by a harness argument, and Herdr is the only adapter that passes one (from its native agent identity).
The tmux submit core calls the same policy with no harness, so a tmux pi pane still receives the conversion.
It is not reachable through anything in this record - the shapes above are Herdr-scoped, so a generating pi 0.85 reads `idle` on tmux - but one pre-existing path remains: the legacy `Working...` token, which pi 0.84 and earlier rendered and which is still in both the pi regex and the harness-less union, so a pi pane on that older version can read busy there.
Threading a harness through the tmux submit core is deliberately not done here, for the same reason the shapes are not activated there.

**Follow-up work, all of which needs tmux captures of its own:** activating these shapes for the tmux submit cores, narrowing `fm_tmux_submit_enter_core`'s baseline-gated conversion the way the Herdr core is narrowed, plumbing the harness through that core so the queued-Enter exclusion covers tmux too, and with the first of those, confirming a stock pi submit on the tmux plane at all (it is unconfirmed today - see the section below).

## A titled opener is refused `empty`, on every backend

Making a stock generating pi's composer readable had a consequence that had to be closed in the same change.
`empty` is the one verdict that authorizes the away-mode injector to type into a pane, and `_fm_composer_pi_verdict` yields it only for an `idle` or `done` agent_status precisely so a generating pi's blank region cannot be read as injectable.
On the tmux plane that status is derived from `fm_pane_busy_state <pane> pi`, which does not carry these shapes - so a generating pi 0.85 arrives at the classifier as `pi<TAB>idle`, and a newly-found blank pair would have classified `empty` for a pane that is mid-turn.
Before this change the stock pane was saved only by being unreadable.

The refusal is taken from the captured STRUCTURE instead of from that status: pi draws its composer's top border titled only while a status indicator is set (`CustomEditor.renderTopBorder` delegating to `WorkingStatusIndicator.renderInBorder`), so a pair opened by a titled border cannot belong to a settled pane.
`_fm_composer_scan_screen` records whether the selected pair's opener was titled, and `_fm_composer_pi_verdict` refuses `empty` for such a pair whatever agent_status it is handed.
That is backend-agnostic and needs no busy shape activated anywhere.
A settled pi, whose opener is a solid rule, still reads `empty`, so the injector is not blinded.
Pinned on the plane where the wrong status is produced, in `tests/fm-tmux-submit-busy.test.sh`, and against the captures in `tests/fm-composer-lib.test.sh`.

The cost is the stock submit confirmation: a composer that refuses `empty` cannot confirm a submit either, so on tmux a landed stock steer stays `unknown` exactly as it did before this change, and the durable steering inbox re-rings it.
Confirming it needs the tmux busy captures named in the follow-up list above.

**Still reachable, and NOT introduced here:** with Calm on, the boat is drawn above the pair and the opener is a solid rule, so a generating Calm pi's blank composer does read `empty` on the tmux plane.
The titled-opener refusal cannot reach it: Calm clears pi's indicator, so there is no titled opener and no structural proof of generating available in the composer at all - the only evidence is the boat row above the pair, which is a busy SHAPE and therefore not consulted on this plane.
That predates this change - it is why the RCA's Fix 2 was scoped as it was - and closing it needs the tmux busy captures too.
It is asserted as-is in `tests/fm-composer-lib.test.sh` and in the live guard, so the gap is visible in the suite rather than latent; those assertions record it, they do not endorse it.

## The two busy shapes, and what each refuses

`FM_DELIVERY_PI_BUSY_SHAPES` reads two independent signals, either one sufficient, so no single vendor string is load-bearing:

- pi's own titled composer border, matched by its composition rather than its message, so `Working`, the narrow spinner-only fallback, and a retry countdown all read busy while a WORD-titled rule from another harness (muse's `── Voice input (⌥ + v to start) ─────`) does not.
  It anchors the literal `── ` opener and the literal 8-column closing run, the same composition the composer scan's `_fm_composer_pi_titled_open_row` predicate accepts, and matches the status MESSAGE between them without a negated class - so a message carrying non-ASCII bytes (`Working…`, `Thinking → tool`, `retry in 3s • attempt 2`) reads the same under a UTF-8 locale and under `LC_ALL=C`, which is the locale the daemons that consume this verdict run in. A negated class holding the rule glyph excludes that glyph's bytes, which are also continuation bytes of those characters, and read `idle` for every one of them in the C locale.
- Calm's working ship, Firstmate's own rendering (`.pi/extensions/lib/fm-calm-working-ship.ts`), matched as a run of water carrying the hull, with water on either side sufficient. That renderer's track span is `width - HULL_WIDTH`, so at the right edge of each traverse the hull ends at the last column with no water after it; requiring trailing water read that one frame as `idle`.

Measured refusals, on the same reader the submit cores use, and identical under `LC_ALL=C`:

| input | verdict |
|---|---|
| `Working on the auth refactor` typed by a user | `idle` |
| `still Working` | `idle` |
| a bare `\__/`, or the sprite glyphs inside a sentence | `idle` |
| muse's word-titled rule | `idle` |
| a settled pi pane | `idle` |

Matching pi's WORD rather than its border would make ordinary prose a busy signal, and a busy signal is what converts a still-pending composer into "delivered".

### Residual limitations

A terminal too narrow for Calm's hull, or for an 8-column closing rule run, carries neither shape and reads `idle`.
That is an unconfirmed submit, never a falsely confirmed one, and the durable steering inbox re-rings an unacknowledged message.

**A solid rule above the titled border hides it.**
`_fm_composer_scan_screen` accepts pi's titled composer border as an opener only when no composer pair is already open.
So any solid `─`-only rule at least as wide as the 8-column floor appearing ABOVE that border inside the capture window - ordinary tool output, a markdown rule, a pasted table line - opens the pair itself, the titled row falls inside it as CONTENT, and a GENERATING pi classifies `pending`: misread as holding unsubmitted input, which is the invariant this record exists to establish.
Measured: taking the committed generating capture `tests/assets/pi-0.85-composer/stock-working.ansi` and replacing one blank transcript row with a solid rule changes the verdict from `unknown` to `pending`.

It is accepted rather than fixed because the two readings cannot be told apart at that point in the scan.
The competing hazard is a `── <glyph> … ────────` row pasted INSIDE an open composer: preferring the lower opener there re-opens the pair below the operator's unsent text, the classifier scans the blank remainder, and the verdict is `empty` - the away-mode injector's permission to type over that text.
Both screens have non-blank rows between the first rule and the titled row and blank rows after it.
So the guard stays, and the cost lands here: `pending` is not `empty`, so the injector still refuses the pane and nothing is overwritten; the submit simply stays unconfirmed and the escalation is re-rung, which is the wedge direction and recoverable, where the alternative costs the operator's message and is not.
The competing hazard is pinned by `test_pi_085_titled_row_pasted_into_an_open_composer_stays_pending`; a future change must not silently trade one for the other.

One locale divergence remains, in the titled alternative's leading `[^[:alnum:][:space:]]`: a multibyte LETTER is alphanumeric under a UTF-8 locale and a non-alnum byte under `LC_ALL=C`, so a non-ASCII-WORD-titled rule would be refused in one locale and read busy in the other, and the C-locale accept would be a false busy.
No harness renders one, so it is unreachable today; `_fm_composer_pi_titled_open_row` carries the same divergence, in the safe direction.

## A prompt in front of the composer

Captured live on pi 0.85.1 (`tests/assets/pi-0.85-composer/modal-eats-enter.ansi`): with a modal open, typed text lands in the modal's own row rather than the composer, the composer verdict is `unknown`, and Enter acts inside the modal while the message is never delivered.

That is why the herdr composer fallback's native idle-to-busy submit proof also requires the pre-Enter composer to read exactly `pending` (`bin/backends/herdr.sh`).
An `unknown` composer is refused, being the prompt-parked reading itself - and so is `pending-unproven`, for the reason the boxed-modal evidence below records.
The transition alone proves the agent started generating; it does not prove it started because of our text.
A pane parked on a prompt takes our keystrokes and our Enter into that prompt, answers it, and starts a turn, which on a harness whose footer carries no busy token is indistinguishable from a delivered submission.

### A BOXED prompt, and why `pending-unproven` is refused

The capture above is the evidence that a prompt in front of the composer must not confirm a submit, but it covers only pi's own modal, which is UNBOXED.
That gap is why admitting an ambiguous-but-occupied composer at the gate looked safe for one round; it is not.
`pending-unproven` is what the shared classifier returns for any container it marks geometrically AMBIGUOUS while holding content, and it marks a container ambiguous when its top border carries a TITLE as well as when its borders and content do not line up.
A titled border is the shape of a modal.

Executed against `fm_composer_classify_screen` with `styled=1 cursor=0 identity=1`, the descriptor `fm_backend_herdr_composer_read` uses:

| screen | verdict |
|---|---|
| `╭─ Select a model ─────╮` / `│ hello captain │` / `╰──────╯` | `pending-unproven` |
| the same box with an untitled top border | `pending` |
| `tests/assets/pi-0.85-composer/modal-eats-enter.ansi` | `unknown` |

So a boxed select-modal holding our typed filter text lands on `pending-unproven`.
Admitting that token would let the modal satisfy the gate, consume the Enter, and have the turn started by answering it read as our delivery - the exact failure the gate exists to refuse.
The gate therefore admits exactly `pending`.

The cost is recorded rather than hidden: a composer whose geometry is genuinely ambiguous loses the native idle-to-busy proof entirely, so its submit cannot be confirmed on this path at all.
That is the unconfirmed-and-re-rung direction, which the durable steering inbox recovers; the alternative is a message reported delivered that never was, which nothing recovers.
Both the admitted and the refused readings are pinned together in `tests/fm-backend-herdr.test.sh`, so neither can go quietly vacuous.

### Where that requirement is waived, and what stays reachable

The requirement holds only when the pre-Enter composer was read at full fidelity.
When `pane read --format ansi` fails on an older herdr, the composer is classified from the plain capture instead, and a `styled=0` descriptor cannot distinguish typed input from ghost text: the same bytes that read `pending` styled read `unknown` plain.
An exact-`pending` check there would not narrow the proof, it would remove the only confirmation route that pane has and leave every submit unconfirmed - the re-injection wedge this whole record exists to close.
So the check is skipped whenever the baseline came from a plain capture, and the native transition alone confirms, exactly as it did before the narrowing.

That is an accepted tradeoff, not an oversight, and it leaves the hazard above reachable on that one path: a pane parked on the modal captured here, read through a plain capture, skips the check, and the turn started by answering the modal is reported as delivery of a message that was never delivered.
It is pinned as intended behavior in `tests/fm-backend-herdr.test.sh`.
Closing it needs a composer read at full fidelity on that herdr, not a different verdict.

## How the captures were taken

Disposable throughout: a private tmux server, a throwaway project, and a throwaway `FM_HOME` carrying the Calm preference for the Calm-on captures.
No live session and no operator configuration is touched, and no model tokens are spent: the turn is driven by a faux provider registered through pi's own extension API (`@earendil-works/pi-ai` `createFauxCore`), so the agent state, the rendering, and the submit path are all real while the model is not.

`tests/fm-pi-working-composer-live-e2e.test.sh` is that procedure as an executable guard, and is the command that refreshes this record:

```sh
tests/fm-pi-working-composer-live-e2e.test.sh
```

Output on the verified version:

```
# pi version under test: 0.85.1
ok - pi (0.85.1) calm=off: the steer landed exactly once, submit read unknown, the generating composer read unknown, and a draft on it stays pending
ok - pi (0.85.1) calm=on: the steer landed exactly once, submit read empty, the generating composer read empty, and a draft on it stays pending
ok - pi (0.85.1): the working-composer guard verified both presentations
```

Those are the guard's own lines, captured from a real 0.85.1 run, and the two presentations differ exactly as the sections above describe: stock is unconfirmed because a titled opener is refused `empty`, Calm confirms from its cleared composer.

The captures themselves are the tails of those panes, kept with the cursor row tmux reported for each, and every one of them reproduces the verdict its full-screen original produced.
Portable regression coverage reads them in `tests/fm-composer-lib.test.sh` and `tests/fm-backend-herdr.test.sh`.
