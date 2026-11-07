# Batch-dispatch live transcripts (pi --skill .agents/skills, openai-codex/gpt-5.6-sol, fake quota-axi)
Common prompt suffix: You are firstmate at dispatch intake in this home. Load the quota-array-dispatch skill and follow it exactly, including its Batch dispatch section. The home config is config/crew-dispatch.json; local data, if any, is under data/. The authoritative catalogs already prove every configured profile supported in its stated provider family, every selected authentication surface is usable, and all profiles have the same strongest reasoning class and comparable fit. Do not spawn anything, do not modify files, and do not run vendor or model commands other than quota-axi. End your answer with: one ESTIMATE=<lane>|<workers>x<hours>x<rate>=<points>|<measured|guess> line per lane you would load, one line SPLIT=<lane>:<count>,<lane>:<count>, and an exact final line DECISION=<stop-and-ask|proceed>.

## Case A
### quota-axi calls (one line per call; blank line = bare default TOON call)
[]
### TOON fixture
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  gemini,gemini-4-argon,99,0.4,through_reset,established,weekly,2030-01-06T00:00:00Z
  codex,all_models,62,0.2,projected_exhaustion,established,weekly,2030-01-04T00:00:00Z
exhaustion[1]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  codex,all_models,250000,2030-01-03T22:00:00Z,weekly
attention[0]:
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
### home files
-- ./config/crew-dispatch.json
{"rules":[{"match":"ship","profiles":["agy:gemini-4-argon-medium","codex:gpt-5.6-sol"]}],"default":"codex:gpt-5.6-sol"}
### agent output
No tasks relaunched.

- `agy:gemini-4-argon-medium`: supported and authenticated per authoritative evidence; Gemini quota 99%, `spendPriority=0.4`, `through_reset`; reasoning and runway pass.
- `codex:gpt-5.6-sol`: supported and authenticated; Codex quota 62%, `spendPriority=0.2`, 250,000s runway; reasoning and runway pass.
- No burn-rate data exists, so the required guess is 25 points/worker-hour. The requested 300 points exceeds both Gemini’s 49.5-point admission ceiling and 69.3-point stop threshold. No compliant redistribution exists because even one ship projects 50 points, exceeding Codex’s 31-point admission ceiling.

ESTIMATE=agy|6x2x25=300|guess
SPLIT=agy:6,codex:0
DECISION=stop-and-ask
rc=0

## Case B
### quota-axi calls (one line per call; blank line = bare default TOON call)
[]
### TOON fixture
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,90,0.5,projected_exhaustion,established,weekly,2030-01-06T00:00:00Z
  codex,all_models,85,0.4,projected_exhaustion,established,weekly,2030-01-05T00:00:00Z
exhaustion[2]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  claude,all_models,400000,2030-01-05T15:00:00Z,weekly
  codex,all_models,380000,2030-01-05T10:00:00Z,weekly
attention[0]:
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
### home files
-- ./config/crew-dispatch.json
{"rules":[{"match":"scout","profiles":["claude:sonnet","codex:gpt-5.6-sol"]}],"default":"codex:gpt-5.6-sol"}
-- ./data/lane-burn-rates.md
# Lane burn rates (percentage points of limiting window per worker-hour)
- claude:sonnet (claude all_models weekly): 2
- codex:gpt-5.6-sol (codex all_models weekly): 2
### agent output
Matched scout rule: `claude:sonnet`, `codex:gpt-5.6-sol`.

- `claude:sonnet`: supported/authenticated per authoritative evidence; strongest reasoning fit; 90% remaining, `spendPriority=0.5`; 400,000s runway exceeds 1-hour horizon.
- `codex:gpt-5.6-sol`: supported/authenticated per authoritative evidence; strongest reasoning fit; 85% remaining, `spendPriority=0.4`; 380,000s runway exceeds 1-hour horizon.
- No preferred provider. Claude ranks first, but the three-worker concentration cap limits it to two. No stop-and-ask trigger applies. Nothing was spawned.

ESTIMATE=claude:sonnet|2x1x2=4|measured
ESTIMATE=codex:gpt-5.6-sol|1x1x2=2|measured
SPLIT=claude:sonnet:2,codex:gpt-5.6-sol:1
DECISION=proceed
rc=0

## Case C
### quota-axi calls (one line per call; blank line = bare default TOON call)
[]
[--provider gemini --full --json]
### TOON fixture
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  gemini,gemini-4-argon,99,0.6,through_reset,established,five_hour,2030-01-01T05:00:00Z
  codex,all_models,70,0.2,projected_exhaustion,established,weekly,2030-01-04T00:00:00Z
exhaustion[1]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  codex,all_models,300000,2030-01-04T11:00:00Z,weekly
attention[1]{provider,scope,kind,detail,remedy}:
  gemini,gemini-4-argon,unresolved_windows,weekly window not resolved,none
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
### home files
-- ./config/crew-dispatch.json
{"rules":[{"match":"ship","profiles":["agy:gemini-4-argon-medium","codex:gpt-5.6-sol"]}],"default":"codex:gpt-5.6-sol"}
### agent output
Matched ship candidates:

- `agy:gemini-4-argon-medium`: catalog/auth/reasoning eligible; `spendPriority=0.6`. Its weekly window remains unresolved, so only `s7` may serve as the required probe before further admission.
- `codex:gpt-5.6-sol`: catalog/auth/reasoning eligible; 70% remaining, `spendPriority=0.2`, and 83.3-hour runway exceeds the 2-hour horizon. However, two ships project 100 points—over both half-window capacity (35) and the stop threshold (49).

Proposed split: `s7` to Gemini; `s8` and `s9` to Codex. Nothing was spawned or modified.

ESTIMATE=agy:gemini-4-argon-medium|1x2x25=50|guess
ESTIMATE=codex:gpt-5.6-sol|2x2x25=100|guess
SPLIT=agy:gemini-4-argon-medium:1,codex:gpt-5.6-sol:2
DECISION=stop-and-ask
rc=0

## Case D
### quota-axi calls (one line per call; blank line = bare default TOON call)
### TOON fixture
bin: quota-axi
generatedAt: "2030-01-01T00:00:00Z"
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,90,0.5,projected_exhaustion,established,weekly,2030-01-06T00:00:00Z
  codex,all_models,85,0.4,projected_exhaustion,established,weekly,2030-01-05T00:00:00Z
exhaustion[2]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  claude,all_models,400000,2030-01-05T15:00:00Z,weekly
  codex,all_models,380000,2030-01-05T10:00:00Z,weekly
attention[0]:
help[1]:
  Run `quota-axi --full` for windows, pace, reserve, and account evidence
### home files
-- ./config/crew-dispatch.json
{"shared_quota": true, "rules":[{"match":"ship","profiles":["claude:sonnet","codex:gpt-5.6-sol"]}],"default":"codex:gpt-5.6-sol"}
### agent output
Shared quota disables quota snapshots, runway gates, and `spendPriority` ranking.

Candidate accounting:
- `claude:sonnet`: catalog-supported Anthropic profile; authentication usable; strongest reasoning fit; quota ranking off. First declared candidate.
- `codex:gpt-5.6-sol`: catalog-supported OpenAI profile; authentication usable; strongest reasoning fit; quota ranking off. Used for overflow under the two-worker concentration cap.
- No preferred provider or Claude account list is configured.
- Proposed assignment: `s10,s11` → Claude; `s12,s13` → Codex. No tasks spawned.

ESTIMATE=claude:sonnet|2x2x25=100|guess
ESTIMATE=codex:gpt-5.6-sol|2x2x25=100|guess
SPLIT=claude:sonnet:2,codex:gpt-5.6-sol:2
DECISION=proceed
rc=0
