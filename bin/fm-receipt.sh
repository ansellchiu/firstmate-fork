#!/usr/bin/env bash
# fm-receipt.sh - the typed receipt record for one completed captain-facing
# outcome (schema fm-receipt.v1), per the multi-plane control-surface
# specification slice B1 (data/control-surface-model-r1/report.md §8).
#
# CONTRACT (this header is the one owner of the receipt format and stores).
#   - Receipt: one single-line JSON object:
#     {"schema":"fm-receipt.v1","id":"<task>#<seq>","task":"...","project":"...",
#      "created_at":"<RFC3339 UTC>","kind":"landing"|"report"|"failure"|"answer",
#      "intent":"...","action":"...","tier1":[...],"tier2":[...],"digest":"...",
#      "verification":"verified"|"unverified"|"verification-failed",
#      "published":{}}. tier1 anchors are REQUIRED and non-empty; every anchor
#     carries kind, an exact machine value, and a mandatory source naming the
#     exact command or API field it was read from (never prose, and never a
#     firstmate script or shell function name). `id` is the
#     stable dedupe key every later plane shares; one landing event keeps its
#     id through upgrade, and a new landing event for the same task takes the
#     next seq - counted from the per-task record AND the index, so a task id
#     reused after teardown discarded the record cannot re-mint an id the
#     append-only store already holds. `published` stays empty until a plane emitter exists (B2); it
#     is part of the record, not of any adapter's memory.
#   - Tier-1 anchor kinds: pr_url, pr_head, commit_sha, ci_check, diff_stat,
#     file_line, test_result, report_path. ONE KIND NEVER CARRIES TWO
#     MEANINGS. In particular the two commit shas a landing sees are
#     different answers and take different kinds: `pr_head` is the head the
#     forge reported for the PR branch BEFORE the merge (registration time,
#     and GitLab's --sha-bound head at merge time, which is the source branch
#     head and not necessarily the commit on the target branch), while
#     `commit_sha` is reserved for the commit that actually LANDED on the
#     target branch (the forge's merge commit, or a local fast-forward head).
#     So "which commit landed" is answered by kind alone - the newest
#     commit_sha anchor - with zero parsing of the free-text source.
#   - Tier-2 anchor kinds: screenshot, log_excerpt, report_link.
#   - Per-task record: $STATE/<id>.receipt, mode 0600, atomically replaced.
#     It holds the task's CURRENT receipt only (latest landing wins; the
#     durable history is the index), so a record about to be replaced by a
#     DIFFERENT receipt id is archived into the index first, whatever its
#     verification state: the replacement fails rather than let a superseded
#     outcome vanish unrecorded.
#   - Durable index: $STATE/receipts.jsonl, strictly APPEND-ONLY and
#     gap-free-sequence-validated on every read and append, copying
#     bin/fm-branch-outcome.sh's proven store mechanics: one JSON object per
#     line (the receipt plus its index "seq"), malformed or reordered rows
#     fail closed, existing lines are never rewritten, and truncation would
#     be a captain-approved manual act. A receipt is validated against the
#     schema BEFORE it is appended, so one bad receipt can never brick the
#     shared store; an append that fails part-way is truncated back to the
#     byte offset it started from and surfaced as a normal typed failure, so
#     a partial row never poisons the store for every later reader.
#     Append-once is keyed on the receipt id and its verification state: an
#     id already indexed is not written again, EXCEPT
#     when the receipt has since become verified and the newest indexed row
#     for that id is not - then a superseding row is appended, so the index
#     never answers "what landed" with a state the record has outgrown. The
#     newest row for an id wins. The index survives teardown and
#     answers "what landed, with evidence" with no network call. Do not
#     overload state/branch-outcomes.jsonl for this: that store is
#     Pi-supervision-branch state; this one is harness-independent.
#   - Writers are STRUCTURAL, never model-composed (the parent-channel
#     lesson: a receipt composed by a model at report time is missing exactly
#     when it matters): bin/fm-pr-check.sh writes the landing receipt at PR
#     registration (verification unverified until merged); the proved-merge
#     path (fm_merge_outcome_report in bin/fm-merge-outcome-lib.sh, both the
#     self merge and the merge poll) upgrades that receipt to verified;
#     bin/fm-merge-local.sh writes the verified local landing; and
#     bin/fm-teardown.sh writes a scout's report receipt at completion,
#     archives the task's receipt into the index, and then discards the
#     per-task file. Teardown's sequence is: gate (a ship task with no
#     receipt refuses teardown, mirroring the landed-work refusals; --force
#     lifts the refusal exactly as it lifts those and never fabricates a
#     receipt), scout write-report, archive (append-once, idempotent), the
#     backlog-close marker, a second archive, discard - so an interrupted
#     cleanup always retries safely, and a merge proved during the cleanup
#     itself still reaches the index before the record is dropped. `kind: "failure"` and `kind: "answer"` are schema-
#     valid; their structural writers land when a producer exists.
#   - intent and action are the one model-supplied part, and they are not
#     recomposed: intent is read from the task brief's "## Captain's intent"
#     section and action from the worker's last done: status line. When that
#     material is absent (a legacy task), the receipt records an explicit
#     unavailable marker instead of invented prose.
#   - project is the registry-facing clone name: the basename of the task
#     record's project= path. A writer may pass --project to override, or
#     --project-fallback with a machine-derived name (the forge repo path
#     parsed from a canonical PR URL) used only when the record names no
#     project; with neither derivable, the write refuses rather than guess.
#   - Every mutation runs under $STATE/.receipts.lock, and every read of a
#     record that a concurrent writer may replace happens inside it. Receipts
#     start from the first task after these writers land; nothing is
#     backfilled (a synthesized historical receipt has no honest source).
#   - jq is REQUIRED: every receipt is typed JSON. A host without jq cannot
#     read or write receipts at all, and every subcommand exits 3 with a
#     message naming jq so a caller can tell "this task has no receipt" (the
#     repair is re-running the writer) from "receipts are unavailable here"
#     (the repair is installing jq) and never prints the impossible one.
#
# Usage:
#   fm-receipt.sh write-landing --task <id> [--pr-url <url>]
#       [--pr-url-source <s>] [--head-sha <sha>] [--head-sha-source <s>]
#       [--commit-sha <sha>] [--sha-source <s>]
#       [--verification <v>] [--project <name>] [--project-fallback <name>]
#       [--intent <s>] [--action <s>] [--digest <s>]
#     Write or replace the task's landing receipt. Requires at least one
#     anchor: --pr-url (plus optional --head-sha, recorded as pr_head) or
#     --commit-sha with --sha-source. Re-writing the SAME landing (a receipt
#     whose pr_url anchor equals --pr-url, or any existing landing when
#     --pr-url is absent) updates it in place, keeping its id and MERGING the
#     anchors into the ones already recorded: re-registration is a repair, so
#     it never drops a landed commit a later proof added, and it keeps the
#     recorded verification and digest unless --verification or --digest state
#     otherwise. Verification defaults to unverified on a NEW landing only.
#     Prints the receipt id.
#   fm-receipt.sh upgrade-landing --task <id> [--pr-url <url>]
#       [--pr-url-source <s>] [--commit-sha <sha>] [--sha-source <s>]
#       [--head-sha <sha>] [--head-sha-source <s>] [--digest <s>]
#     Upgrade the task's existing landing receipt to verification=verified,
#     merging anchors (exact kind+value pairs dedupe) and keeping its id,
#     intent, and action. The digest becomes the merged wording ("Merged: <pr
#     url>", or "Landed: <sha>" without one) unless --digest states otherwise,
#     so a proved landing never keeps the registration's "PR ready" line. --commit-sha is the commit that LANDED; a merge
#     that can only prove the source-branch head passes --head-sha instead,
#     so the landed-commit answer is never a head sha wearing its kind. When
#     no receipt exists, one landing receipt is created at the next seq, so
#     every proved merge still ends with one. Prints the receipt id.
#   fm-receipt.sh write-report --task <id> --report-path <path>
#       [--intent <s>] [--action <s>] [--digest <s>]
#     Write the task's report receipt (kind report, verification verified,
#     one report_path anchor sourced from the exact existence check). Refuses
#     when the report file is missing or empty. Re-writing the SAME report (a
#     report receipt anchoring the same --report-path) replaces it in place,
#     keeping its id, so a retried teardown never indexes one report twice.
#     Prints the receipt id.
#   fm-receipt.sh archive --task <id>
#     Append the task's current receipt to the durable index (append-once on
#     the receipt id, except for the one superseding row a newly verified
#     receipt earns), keeping the per-task file. Idempotent. Prints the index
#     seq, or already-indexed.
#   fm-receipt.sh discard --task <id>
#     Remove the per-task receipt file after it has been archived. Idempotent.
#   fm-receipt.sh get <task-id>
#     Print the task's validated receipt, or exit non-zero when absent or
#     invalid.
#   fm-receipt.sh list [--recent <n>]
#     Print the last n indexed receipts (default 20).
#   fm-receipt.sh validate
#     Read one receipt JSON object on stdin, validate it against the schema,
#     and print its canonical single-line form.
set -eu

# Exit 3, distinct from every refusal, so a caller can say "receipts are
# unavailable on this host" instead of offering a repair that cannot succeed.
command -v jq >/dev/null 2>&1 || {
  echo "error: fm-receipt.sh requires jq to read or write typed receipts; install jq" >&2
  exit 3
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

RECEIPT_INDEX="$STATE/receipts.jsonl"
RECEIPT_LOCK="$STATE/.receipts.lock"
RECEIPT_SCHEMA=fm-receipt.v1
INTENT_MAX_CHARS=280
# Anchors merge in append order, keeping the LAST occurrence of an exact
# kind+value, so the newest commit_sha anchor stays the newest one. jq's
# unique_by would sort the array and bury a later-recorded landed commit.
# shellcheck disable=SC2016  # a jq program: $add is jq's variable, not the shell's.
TIER1_MERGE_JQ='.tier1 = ((.tier1 + $add)
  | reverse
  | reduce .[] as $a ([];
      if any(.[]; .kind == $a.kind and .value == $a.value) then . else . + [$a] end)
  | reverse)'

RECEIPT_KEYS='["action", "created_at", "digest", "id", "intent", "kind", "project", "published", "schema", "task", "tier1", "tier2", "verification"]'
INDEX_KEYS='["action", "created_at", "digest", "id", "intent", "kind", "project", "published", "schema", "seq", "task", "tier1", "tier2", "verification"]'

usage() {
  echo "usage: fm-receipt.sh write-landing --task <id> [--pr-url <url>] [--pr-url-source <s>] [--head-sha <sha>] [--head-sha-source <s>] [--commit-sha <sha>] [--sha-source <s>] [--verification <v>] [--project <name>] [--intent <s>] [--action <s>] [--digest <s>] | upgrade-landing --task <id> [--pr-url <url>] [--pr-url-source <s>] [--commit-sha <sha>] [--sha-source <s>] [--head-sha <sha>] [--head-sha-source <s>] [--digest <s>] | write-report --task <id> --report-path <path> [--intent <s>] [--action <s>] [--digest <s>] | archive --task <id> | discard --task <id> | get <task-id> | list [--recent <n>] | validate" >&2
  exit 2
}

fm_receipt_task_id_valid() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

truncate_line() { # <text> <max-chars>
  local text=$1 max=$2
  if [ "${#text}" -gt "$max" ]; then
    # ASCII ellipsis only: a byte-cut multibyte character would corrupt the line.
    text="${text:0:$((max - 3))}..."
  fi
  printf '%s' "$text"
}

# The first non-empty line of the brief's "## Captain's intent" section.
# bin/fm-dod-lib.sh is the one owner of that parse and of the captain-intent
# contract, so its reader is used rather than a second, narrower one here.
read_brief_intent() { # <task>
  local brief="$DATA/$1/brief.md" body line
  [ -f "$brief" ] && [ -r "$brief" ] || return 1
  fm_brief_task_heading_present "$brief" "## Captain's intent" || return 1
  body=$(fm_brief_task_heading_body "$brief" "## Captain's intent") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
    truncate_line "$line" "$INTENT_MAX_CHARS"
    return 0
  done <<EOF
$body
EOF
  return 1
}

# The note text of the worker's last done: status line.
read_done_note() { # <task>
  local status="$STATE/$1.status" line note='' found=''
  [ -f "$status" ] && [ -r "$status" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      done*:*)
        note=${line#done}
        note=${note#*:}
        # One leading space is the writer's separator; the rest is the note.
        case "$note" in
          ' '*) note=${note# } ;;
        esac
        found=1
        ;;
    esac
  done < "$status"
  [ -n "$found" ] && [ -n "$note" ] || return 1
  truncate_line "$note" "$INTENT_MAX_CHARS"
}

read_project_name() { # <task>
  local meta="$STATE/$1.meta" project
  [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || return 1
  project=$(grep '^project=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ -n "$project" ] || return 1
  basename "$project"
}

receipt_path() { # <task>
  fm_receipt_task_id_valid "$1" || return 1
  printf '%s/%s.receipt' "$STATE" "$1"
}

sha_valid() { # <sha>
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -ge 7 ] && [ "${#1}" -le 64 ]
}

# The one fm-receipt.v1 schema program, shared verbatim by the per-task record
# and the durable index so the two stores can never disagree about what is
# valid: a new anchor kind or field is added here once. The caller supplies
# $keys (the record's keys, or the index's keys plus seq) and the index adds
# only its own seq clause on top of `base_valid`.
# shellcheck disable=SC2016  # a jq program: $keys is jq's variable, not the shell's.
RECEIPT_SCHEMA_JQ='
  def rfc3339: type == "string"
    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def anchor:
    type == "object" and keys == ["kind", "source", "value"]
    and ((.kind == "pr_url") or (.kind == "pr_head") or (.kind == "commit_sha")
      or (.kind == "ci_check")
      or (.kind == "diff_stat") or (.kind == "file_line") or (.kind == "test_result")
      or (.kind == "report_path"))
    and (.value | type == "string" and length > 0)
    and (.source | type == "string" and length > 0);
  def anchor2:
    type == "object" and keys == ["kind", "value"]
    and ((.kind == "screenshot") or (.kind == "log_excerpt") or (.kind == "report_link"))
    and (.value | type == "string" and length > 0);
  def nonempty: type == "string" and length > 0;
  def base_valid:
    type == "object"
    and keys == $keys
    and (.schema == "fm-receipt.v1")
    and (.task | nonempty)
    and (.task as $t
      | .id as $i
      | ($i | type == "string")
      and ($i | startswith($t + "#"))
      and (($i | ltrimstr($t + "#")) | test("^[1-9][0-9]*$") // false))
    and (.project | nonempty)
    and (.created_at | rfc3339)
    and ((.kind == "landing") or (.kind == "report") or (.kind == "failure")
      or (.kind == "answer"))
    and (.intent | nonempty)
    and (.action | nonempty)
    and (.digest | nonempty)
    and (.tier1 | type == "array")
    and (.tier1 | length > 0)
    and all(.tier1[]; anchor)
    and (.tier2 | type == "array")
    and all(.tier2[]; anchor2)
    and ((.verification == "verified") or (.verification == "unverified")
      or (.verification == "verification-failed"))
    and (.published | type == "object")
    and all(.published[]; rfc3339);
'

# The schema validator, shared by every write and read. Input: one JSON
# object on stdin; exit 0 iff it is a valid fm-receipt.v1 receipt without
# the index seq field.
receipt_valid_stdin() {
  jq -e --argjson keys "$RECEIPT_KEYS" "$RECEIPT_SCHEMA_JQ"'
    base_valid
  ' >/dev/null
}

# Highest valid index seq, validating the whole store as a gap-free sequence
# of receipts plus their index seq (the branch-outcome store mechanics).
last_index_seq() {
  [ -s "$RECEIPT_INDEX" ] || { printf '0\n'; return 0; }
  jq -Rse --argjson keys "$INDEX_KEYS" "$RECEIPT_SCHEMA_JQ"'
    def valid:
      base_valid
      and ((.seq | type) == "number" and .seq >= 1
        and .seq <= 9007199254740991 and .seq == (.seq | floor));
    if endswith("\n") then split("\n")[:-1]
    else error("unterminated receipt index")
    end
    | map(fromjson)
    | . as $rows
    | if reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid and .seq == ($i + 1)))
      then .[-1].seq
      else error("malformed or non-sequential receipt index")
      end
  ' "$RECEIPT_INDEX" 2>/dev/null
}

anchor_json() { # <kind> <value> <source>
  jq -cn --arg kind "$1" --arg value "$2" --arg source "$3" \
    '{kind: $kind, value: $value, source: $source}'
}

# Assemble a compact tier1 JSON array from "<kind><TAB><value><TAB><source>"
# fields; a missing third field falls back to <default-source>.
assemble_anchors() { # <default-source> <field>...
  local default_source=$1 field kind value source first=1
  shift
  {
    printf '['
    for field in "$@"; do
      kind=${field%%$'\t'*}
      field=${field#*$'\t'}
      case "$field" in
        *$'\t'*)
          value=${field%%$'\t'*}
          source=${field#*$'\t'}
          ;;
        *)
          value=$field
          source=$default_source
          ;;
      esac
      [ "$first" = 1 ] || printf ','
      first=0
      anchor_json "$kind" "$value" "$source"
    done
    printf ']'
  } | jq -c .
}

build_receipt_json() { # <id> <task> <project> <kind> <intent> <action> <digest> <verification> <tier1-json>
  jq -cn \
    --arg schema "$RECEIPT_SCHEMA" \
    --arg id "$1" --arg task "$2" --arg project "$3" --arg kind "$4" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg intent "$5" --arg action "$6" --arg digest "$7" \
    --arg verification "$8" --argjson tier1 "$9" \
    '{schema: $schema, id: $id, task: $task, project: $project,
      created_at: $created_at, kind: $kind, intent: $intent, action: $action,
      tier1: $tier1, tier2: [], digest: $digest,
      verification: $verification, published: {}}'
}

# Print the receipt id recorded in an existing per-task record, or fail.
existing_receipt_id() { # <task>
  local path
  path=$(receipt_path "$1") || return 1
  [ -s "$path" ] || return 1
  jq -er '.id' "$path" 2>/dev/null
}

existing_receipt_seq() { # <task>
  local id
  id=$(existing_receipt_id "$1") || { printf '0\n'; return 0; }
  id=${id##*#}
  case "$id" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$id" ;;
  esac
}

# Highest seq the durable index already holds for this task. The per-task
# record is discarded at teardown, so it alone cannot say which ids the
# append-only store has seen; a task id reused after cleanup would otherwise
# restart at #1 and its genuinely different outcome would be swallowed by the
# archive's append-once rule.
index_last_task_seq() { # <task>
  [ -s "$RECEIPT_INDEX" ] || { printf '0\n'; return 0; }
  jq -rs --arg task "$1" '
    [.[] | select(.task == $task)
      | (.id | ltrimstr($task + "#") | tonumber? // 0)]
    | max // 0
  ' "$RECEIPT_INDEX" 2>/dev/null || printf '0\n'
}

# The seq a new receipt for this task must exceed: the record's own seq or the
# highest one already indexed, whichever is larger. Callers hold the receipt
# lock, which is also what guards the index read.
next_receipt_seq() { # <task>
  local own indexed
  own=$(existing_receipt_seq "$1")
  indexed=$(index_last_task_seq "$1")
  case "$indexed" in ''|*[!0-9]*) indexed=0 ;; esac
  if [ "$own" -ge "$indexed" ]; then
    printf '%s\n' "$own"
  else
    printf '%s\n' "$indexed"
  fi
}

# True when an existing landing receipt anchors exactly this pr_url.
existing_receipt_has_pr_url() { # <task> <url>
  local path
  path=$(receipt_path "$1") || return 1
  [ -s "$path" ] || return 1
  jq -e --arg url "$2" '
    (.kind == "landing")
    and any(.tier1[]; .kind == "pr_url" and .value == $url)
  ' "$path" >/dev/null 2>&1
}

# True when an existing report receipt anchors exactly this report path.
existing_receipt_has_report_path() { # <task> <path>
  local path
  path=$(receipt_path "$1") || return 1
  [ -s "$path" ] || return 1
  jq -e --arg report "$2" '
    (.kind == "report")
    and any(.tier1[]; .kind == "report_path" and .value == $report)
  ' "$path" >/dev/null 2>&1
}

# The verification state of the NEWEST indexed row for this receipt id, or
# empty when the id is not indexed at all. The store is append-only, so a
# later row supersedes an earlier one for the same id.
index_receipt_verification() { # <id>
  [ -s "$RECEIPT_INDEX" ] || return 0
  jq -rs --arg id "$1" '
    [.[] | select(.id == $id)] | last | if . == null then "" else .verification end
  ' "$RECEIPT_INDEX" 2>/dev/null || printf '\n'
}

# Shrink the index back to a byte offset a failed append was started from.
# The store's one repair path: an append that dies mid-line would otherwise
# leave an unterminated row that fails every later read and append.
index_truncate_to() { # <bytes>
  local bytes=$1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$bytes" -eq 0 ]; then
    : > "$RECEIPT_INDEX" || return 1
    return 0
  fi
  perl -e '
    open(my $fh, "+<", $ARGV[0]) or exit 1;
    truncate($fh, $ARGV[1]) or exit 1;
    close($fh) or exit 1;
  ' "$RECEIPT_INDEX" "$bytes" 2>/dev/null
}

# Roll a failed append back to the byte offset it started from. An append that
# never reached the file leaves nothing to undo.
index_rollback_to() { # <bytes>
  local bytes=$1 now=0
  if [ -s "$RECEIPT_INDEX" ]; then
    now=$(wc -c < "$RECEIPT_INDEX" | tr -d '[:space:]')
  fi
  [ "$now" = "$bytes" ] && return 0
  index_truncate_to "$bytes"
}

# The one appender for the durable index, shared by the archive subcommand and
# the supersede path below. Prints the new seq, or "already-indexed" when the
# append-once rule covers this receipt. Callers hold $RECEIPT_LOCK. A failure
# leaves the store exactly as it was.
index_append_receipt() { # <receipt-json>
  local json=$1 id verification last indexed seq row offset
  printf '%s\n' "$json" | receipt_valid_stdin || {
    echo "error: a receipt that fails the fm-receipt.v1 schema is never appended to the durable index" >&2
    return 1
  }
  id=$(printf '%s' "$json" | jq -er '.id' 2>/dev/null) || return 1
  verification=$(printf '%s' "$json" | jq -er '.verification' 2>/dev/null) || return 1
  last=$(last_index_seq) || {
    echo "error: refusing to append because the receipt index is malformed or non-sequential" >&2
    return 1
  }
  indexed=$(index_receipt_verification "$id")
  # Append-once on the id, except for the one state change the index must not
  # miss: a row archived while the merge was still unproved, whose receipt has
  # since become verified, earns a superseding row.
  if [ -n "$indexed" ] \
    && { [ "$verification" != verified ] || [ "$indexed" = verified ]; }; then
    printf '%s\n' "already-indexed"
    return 0
  fi
  seq=$(( last + 1 ))
  row=$(printf '%s' "$json" | jq -c --argjson seq "$seq" '. + {seq: $seq}') || return 1
  offset=0
  if [ -s "$RECEIPT_INDEX" ]; then
    offset=$(wc -c < "$RECEIPT_INDEX" | tr -d '[:space:]')
    case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  fi
  # One single-line JSON object per append; existing lines are never rewritten.
  if ! printf '%s\n' "$row" >> "$RECEIPT_INDEX"; then
    index_rollback_to "$offset" \
      || echo "error: the receipt index kept a partial row that could not be rolled back" >&2
    return 1
  fi
  if ! last_index_seq >/dev/null; then
    index_rollback_to "$offset" \
      || echo "error: the receipt index kept a partial row that could not be rolled back" >&2
    echo "error: receipt index did not validate after append; the append was rolled back" >&2
    return 1
  fi
  printf '%s\n' "$seq"
}

# Replace or create the per-task record atomically (mode 0600), validating
# the bytes before they become the record.
publish_per_task_receipt() { # <task> <receipt-json>
  local task=$1 json=$2 path tmp outgoing outgoing_id new_id
  path=$(receipt_path "$task") || return 1
  printf '%s\n' "$json" | receipt_valid_stdin || {
    echo "error: refusing to store a receipt that fails the fm-receipt.v1 schema" >&2
    return 1
  }
  # The record holds the task's CURRENT receipt only, so a record about to be
  # replaced by a DIFFERENT outcome is the last moment its evidence can reach
  # the durable index. A record that no longer reads as a receipt carries no
  # history to keep and is replaced as before.
  if [ -s "$path" ]; then
    outgoing=$(cat "$path")
    new_id=$(printf '%s' "$json" | jq -er '.id' 2>/dev/null) || return 1
    outgoing_id=$(printf '%s' "$outgoing" | jq -er '.id' 2>/dev/null) || outgoing_id=
    if [ -n "$outgoing_id" ] && [ "$outgoing_id" != "$new_id" ] \
      && printf '%s\n' "$outgoing" | receipt_valid_stdin; then
      index_append_receipt "$outgoing" >/dev/null || {
        echo "error: refusing to replace task $task's receipt $outgoing_id: it could not be archived into the durable index first" >&2
        return 1
      }
    fi
  fi
  tmp=$(mktemp "$STATE/.fm-receipt.XXXXXX") || return 1
  printf '%s\n' "$json" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# Shared writer flag parsing. Sets TASK, PR_URL, HEAD_SHA, HEAD_SHA_SOURCE,
# COMMIT_SHA, SHA_SOURCE, VERIFICATION, INTENT, ARG_ACTION, ARG_DIGEST,
# ARG_PROJECT, REPORT_PATH.
parse_writer_flags() { # <subcommand> <args...>
  local sub=$1
  shift
  TASK=
  PR_URL=
  PR_URL_SOURCE=
  HEAD_SHA=
  HEAD_SHA_SOURCE=
  COMMIT_SHA=
  SHA_SOURCE=
  VERIFICATION=
  INTENT=
  ARG_ACTION=
  ARG_DIGEST=
  ARG_PROJECT=
  ARG_PROJECT_FALLBACK=
  REPORT_PATH=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) TASK=${2:-}; shift 2 || usage ;;
      --pr-url) PR_URL=${2:-}; shift 2 || usage ;;
      --pr-url-source) PR_URL_SOURCE=${2:-}; shift 2 || usage ;;
      --head-sha) HEAD_SHA=${2:-}; shift 2 || usage ;;
      --head-sha-source) HEAD_SHA_SOURCE=${2:-}; shift 2 || usage ;;
      --commit-sha) COMMIT_SHA=${2:-}; shift 2 || usage ;;
      --sha-source) SHA_SOURCE=${2:-}; shift 2 || usage ;;
      --verification) VERIFICATION=${2:-}; shift 2 || usage ;;
      --project) ARG_PROJECT=${2:-}; shift 2 || usage ;;
      --project-fallback) ARG_PROJECT_FALLBACK=${2:-}; shift 2 || usage ;;
      --intent) INTENT=${2:-}; shift 2 || usage ;;
      --action) ARG_ACTION=${2:-}; shift 2 || usage ;;
      --digest) ARG_DIGEST=${2:-}; shift 2 || usage ;;
      --report-path) REPORT_PATH=${2:-}; shift 2 || usage ;;
      *) echo "error: unknown flag for $sub: $1" >&2; usage ;;
    esac
  done
  fm_receipt_task_id_valid "$TASK" || usage
}

# Derived shared fields, each from material that already exists (the brief's
# captain-intent block, the worker's done: line, the record's project=).
derive_intent() {
  if [ -n "$INTENT" ]; then
    INTENT_TEXT=$INTENT
  elif INTENT_TEXT=$(read_brief_intent "$TASK"); then
    :
  else
    INTENT_TEXT="(intent unavailable: task $TASK's brief did not record a captain intent)"
  fi
}

derive_action() {
  if [ -n "$ARG_ACTION" ]; then
    ACTION_TEXT=$ARG_ACTION
  elif ACTION_TEXT=$(read_done_note "$TASK"); then
    :
  else
    ACTION_TEXT="(action unavailable: task $TASK recorded no done line)"
  fi
}

derive_project() {
  if [ -n "$ARG_PROJECT" ]; then
    PROJECT_NAME=$ARG_PROJECT
  elif PROJECT_NAME=$(read_project_name "$TASK"); then
    :
  elif [ -n "$ARG_PROJECT_FALLBACK" ]; then
    PROJECT_NAME=$ARG_PROJECT_FALLBACK
  else
    echo "error: task $TASK's record does not name a project; refusing to guess" >&2
    return 1
  fi
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  write-landing|upgrade-landing)
    SUB=$CMD
    parse_writer_flags "$SUB" "$@"
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
    # The canonical PR URL is the identity the registration recorded and every
    # later path re-reads, so its default source is that exact read command.
    DEFAULT_PR_URL_SOURCE="grep '^pr=' $STATE/$TASK.meta"
    TIER1_FIELDS=()
    if [ "$SUB" = write-landing ]; then
      if [ -z "$PR_URL" ] && [ -z "$COMMIT_SHA" ] && [ -z "$HEAD_SHA" ]; then
        echo "error: write-landing requires --pr-url or --commit-sha/--head-sha" >&2
        exit 2
      fi
      if [ -n "$HEAD_SHA" ]; then
        [ -n "$HEAD_SHA_SOURCE" ] || { echo "error: --head-sha requires --head-sha-source" >&2; exit 2; }
        sha_valid "$HEAD_SHA" || { echo "error: --head-sha is not a commit sha" >&2; exit 2; }
        TIER1_FIELDS+=("pr_head"$'\t'"$HEAD_SHA"$'\t'"$HEAD_SHA_SOURCE")
      fi
      if [ -n "$PR_URL" ]; then
        TIER1_FIELDS+=("pr_url"$'\t'"$PR_URL"$'\t'"${PR_URL_SOURCE:-$DEFAULT_PR_URL_SOURCE}")
      fi
      if [ -n "$COMMIT_SHA" ]; then
        [ -n "$SHA_SOURCE" ] || { echo "error: --commit-sha requires --sha-source" >&2; exit 2; }
        sha_valid "$COMMIT_SHA" || { echo "error: --commit-sha is not a commit sha" >&2; exit 2; }
        TIER1_FIELDS+=("commit_sha"$'\t'"$COMMIT_SHA"$'\t'"$SHA_SOURCE")
      fi
      VERIFICATION_ARG=$VERIFICATION
      [ -z "$VERIFICATION" ] && VERIFICATION=unverified
    else
      if [ -z "$PR_URL" ] && [ -z "$COMMIT_SHA" ]; then
        echo "error: upgrade-landing requires --pr-url or --commit-sha" >&2
        exit 2
      fi
      if [ -n "$COMMIT_SHA" ]; then
        [ -n "$SHA_SOURCE" ] || { echo "error: --commit-sha requires --sha-source" >&2; exit 2; }
        sha_valid "$COMMIT_SHA" || { echo "error: --commit-sha is not a commit sha" >&2; exit 2; }
        TIER1_FIELDS+=("commit_sha"$'\t'"$COMMIT_SHA"$'\t'"$SHA_SOURCE")
      fi
      if [ -n "$HEAD_SHA" ]; then
        [ -n "$HEAD_SHA_SOURCE" ] || { echo "error: --head-sha requires --head-sha-source" >&2; exit 2; }
        sha_valid "$HEAD_SHA" || { echo "error: --head-sha is not a commit sha" >&2; exit 2; }
        TIER1_FIELDS+=("pr_head"$'\t'"$HEAD_SHA"$'\t'"$HEAD_SHA_SOURCE")
      fi
      if [ -n "$PR_URL" ]; then
        TIER1_FIELDS+=("pr_url"$'\t'"$PR_URL"$'\t'"${PR_URL_SOURCE:-$DEFAULT_PR_URL_SOURCE}")
      fi
      VERIFICATION_ARG=$VERIFICATION
      VERIFICATION=verified
    fi
    case "$VERIFICATION" in verified|unverified|verification-failed) ;; *) usage ;; esac

    fm_lock_acquire_wait "$RECEIPT_LOCK"
    RC=0
    NEW_JSON=
    if ! derive_project; then
      fm_lock_release "$RECEIPT_LOCK"
      exit 1
    fi
    derive_intent
    derive_action
    EXISTING_PATH=$(receipt_path "$TASK")
    EXISTING_JSON=
    [ ! -s "$EXISTING_PATH" ] || EXISTING_JSON=$(cat "$EXISTING_PATH")
    if [ "$SUB" = upgrade-landing ]; then
      if [ -n "$EXISTING_JSON" ]; then
        KIND=$(printf '%s' "$EXISTING_JSON" | jq -er '.kind' 2>/dev/null) || KIND=
        if [ "$KIND" != landing ]; then
          echo "error: task $TASK's existing receipt is not a landing; refusing to upgrade it" >&2
          fm_lock_release "$RECEIPT_LOCK"
          exit 1
        fi
        # Keep id/created_at/task/project/kind/intent/action; verify to
        # verified; merge anchors deduped on exact kind+value.
        if [ -n "$ARG_DIGEST" ]; then
          NEW_DIGEST=$ARG_DIGEST
        elif [ -n "$PR_URL" ]; then
          NEW_DIGEST="Merged: $PR_URL"
        else
          NEW_DIGEST="Landed: $COMMIT_SHA"
        fi
        NEW_JSON=$(printf '%s' "$EXISTING_JSON" | jq -c \
          --argjson add "$(assemble_anchors '' "${TIER1_FIELDS[@]+"${TIER1_FIELDS[@]}"}")" \
          --arg digest "$NEW_DIGEST" \
          ".verification = \"verified\" | .digest = \$digest | $TIER1_MERGE_JQ")
      else
        # No registration receipt (a PR recorded before the writer landed, or
        # a poll-detected merge of one): create the landing here so a proved
        # merge still ends with exactly one durable receipt.
        if [ -n "$PR_URL" ]; then
          NEW_DIGEST=${ARG_DIGEST:-"Merged: $PR_URL"}
        else
          NEW_DIGEST=${ARG_DIGEST:-"Landed: $COMMIT_SHA"}
        fi
        SEQ=$(( $(next_receipt_seq "$TASK") + 1 ))
        NEW_JSON=$(build_receipt_json \
          "$TASK#$SEQ" "$TASK" "$PROJECT_NAME" landing \
          "$INTENT_TEXT" "$ACTION_TEXT" "$NEW_DIGEST" verified \
          "$(assemble_anchors '' "${TIER1_FIELDS[@]+"${TIER1_FIELDS[@]}"}")")
      fi
    else
      # write-landing: the same landing replaces in place (same id); a
      # different landing event takes the next seq.
      SAME=0
      if [ -n "$EXISTING_JSON" ]; then
        if [ -n "$PR_URL" ]; then
          existing_receipt_has_pr_url "$TASK" "$PR_URL" && SAME=1
        else
          KIND=$(printf '%s' "$EXISTING_JSON" | jq -er '.kind' 2>/dev/null) || KIND=
          [ "$KIND" = landing ] && SAME=1
        fi
      fi
      if [ "$SAME" = 1 ]; then
        # Re-registering the SAME landing is a repair, never a rewind: a later
        # proof may already have made this receipt verified and added the
        # landed commit, and rebuilding from the registration's anchors alone
        # would drop both with no error into an index that cannot be corrected
        # downward. So keep the recorded verification unless the caller states
        # one, keep the recorded digest unless the caller states one, and merge
        # the anchors on exact kind+value the way the upgrade path does.
        if [ -n "$VERIFICATION_ARG" ]; then
          NEW_VERIFICATION=$VERIFICATION
        else
          NEW_VERIFICATION=$(printf '%s' "$EXISTING_JSON" | jq -er '.verification' 2>/dev/null) \
            || NEW_VERIFICATION=
        fi
        if [ -n "$ARG_DIGEST" ]; then
          NEW_DIGEST=$ARG_DIGEST
        else
          NEW_DIGEST=$(printf '%s' "$EXISTING_JSON" | jq -er '.digest' 2>/dev/null) \
            || NEW_DIGEST=
        fi
      fi
      # A record that cannot supply the fields a repair must preserve is not a
      # landing this write can merge into; it takes the fresh-receipt path.
      if [ "$SAME" = 1 ] && { [ -z "$NEW_VERIFICATION" ] || [ -z "$NEW_DIGEST" ]; }; then
        SAME=0
      fi
      if [ "$SAME" = 1 ]; then
        NEW_JSON=$(printf '%s' "$EXISTING_JSON" | jq -c \
          --argjson add "$(assemble_anchors '' "${TIER1_FIELDS[@]+"${TIER1_FIELDS[@]}"}")" \
          --arg digest "$NEW_DIGEST" --arg verification "$NEW_VERIFICATION" \
          ".verification = \$verification | .digest = \$digest | $TIER1_MERGE_JQ")
      else
        NEW_ID="$TASK#$(( $(next_receipt_seq "$TASK") + 1 ))"
        if [ -n "$ARG_DIGEST" ]; then
          NEW_DIGEST=$ARG_DIGEST
        elif [ -n "$PR_URL" ]; then
          NEW_DIGEST="PR ready: $PR_URL"
        elif [ -n "$COMMIT_SHA" ]; then
          NEW_DIGEST="Landed: $COMMIT_SHA"
        else
          NEW_DIGEST="PR ready: $HEAD_SHA"
        fi
        NEW_JSON=$(build_receipt_json \
          "$NEW_ID" "$TASK" "$PROJECT_NAME" landing \
          "$INTENT_TEXT" "$ACTION_TEXT" "$NEW_DIGEST" "$VERIFICATION" \
          "$(assemble_anchors '' "${TIER1_FIELDS[@]+"${TIER1_FIELDS[@]}"}")")
      fi
    fi
    if [ -z "$NEW_JSON" ] || ! publish_per_task_receipt "$TASK" "$NEW_JSON"; then
      RC=1
    else
      existing_receipt_id "$TASK"
    fi
    fm_lock_release "$RECEIPT_LOCK"
    exit "$RC"
    ;;
  write-report)
    parse_writer_flags "$CMD" "$@"
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
    [ -n "$REPORT_PATH" ] || usage
    [ -f "$REPORT_PATH" ] && [ -s "$REPORT_PATH" ] || {
      echo "error: refusing to write a report receipt for a missing or empty report: $REPORT_PATH" >&2
      exit 1
    }
    fm_lock_acquire_wait "$RECEIPT_LOCK"
    RC=0
    if ! derive_project; then
      fm_lock_release "$RECEIPT_LOCK"
      exit 1
    fi
    derive_intent
    derive_action
    if [ -n "$ARG_DIGEST" ]; then
      NEW_DIGEST=$ARG_DIGEST
    else
      NEW_DIGEST="Report ready: $REPORT_PATH"
    fi
    # The SAME report replaces its receipt in place, keeping its id: a
    # teardown that refuses after writing the report receipt retries this
    # writer, and a fresh id there would index one completed outcome twice.
    if existing_receipt_has_report_path "$TASK" "$REPORT_PATH"; then
      REPORT_ID=$(existing_receipt_id "$TASK")
    else
      REPORT_ID="$TASK#$(( $(next_receipt_seq "$TASK") + 1 ))"
    fi
    NEW_JSON=$(build_receipt_json \
      "$REPORT_ID" "$TASK" "$PROJECT_NAME" report \
      "$INTENT_TEXT" "$ACTION_TEXT" "$NEW_DIGEST" verified \
      "$(assemble_anchors "test -s $REPORT_PATH" "report_path"$'\t'"$REPORT_PATH")")
    if [ -z "$NEW_JSON" ] || ! publish_per_task_receipt "$TASK" "$NEW_JSON"; then
      RC=1
    else
      existing_receipt_id "$TASK"
    fi
    fm_lock_release "$RECEIPT_LOCK"
    exit "$RC"
    ;;
  archive)
    parse_writer_flags "$CMD" "$@"
    ARCHIVE_PATH=$(receipt_path "$TASK") || usage
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
    # The record is read INSIDE the lock: a concurrent upgrade-landing may be
    # replacing it, and archiving a superseded receipt would be silent.
    fm_lock_acquire_wait "$RECEIPT_LOCK"
    RC=0
    if [ ! -s "$ARCHIVE_PATH" ]; then
      echo "error: task $TASK has no receipt to archive" >&2
      fm_lock_release "$RECEIPT_LOCK"
      exit 1
    fi
    RECEIPT_JSON=$(cat "$ARCHIVE_PATH")
    # The store is shared by every task, so a receipt is proved against the
    # schema BEFORE it is appended: one invalid row would fail every later
    # read and append, and the index is never rewritten to repair it.
    if ! printf '%s\n' "$RECEIPT_JSON" | receipt_valid_stdin; then
      echo "error: task $TASK's receipt fails the fm-receipt.v1 schema; refusing to append it to the durable index" >&2
      fm_lock_release "$RECEIPT_LOCK"
      exit 1
    fi
    if ! index_append_receipt "$RECEIPT_JSON"; then
      RC=1
    fi
    fm_lock_release "$RECEIPT_LOCK"
    exit "$RC"
    ;;
  discard)
    parse_writer_flags "$CMD" "$@"
    DISCARD_PATH=$(receipt_path "$TASK") || usage
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
    # Under the lock like every other mutation: a concurrent writer must not
    # have the record removed out from under the write it just published.
    fm_lock_acquire_wait "$RECEIPT_LOCK"
    RC=0
    if { [ -e "$DISCARD_PATH" ] || [ -L "$DISCARD_PATH" ]; }; then
      if { [ -f "$DISCARD_PATH" ] && [ ! -L "$DISCARD_PATH" ]; }; then
        rm -f -- "$DISCARD_PATH" || RC=1
      else
        echo "error: task $TASK's receipt record is not a regular file; removing nothing" >&2
        RC=1
      fi
    fi
    fm_lock_release "$RECEIPT_LOCK"
    exit "$RC"
    ;;
  get)
    [ "$#" -eq 1 ] || usage
    GET_PATH=$(receipt_path "$1") || usage
    [ -s "$GET_PATH" ] || exit 1
    GET_JSON=$(cat "$GET_PATH")
    printf '%s\n' "$GET_JSON" | receipt_valid_stdin || {
      echo "error: task $1's receipt fails the fm-receipt.v1 schema" >&2
      exit 1
    }
    printf '%s\n' "$GET_JSON" | jq -c .
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$RECEIPT_LOCK"
    if ! last_index_seq >/dev/null; then
      echo "error: refusing read because the receipt index is malformed or non-sequential" >&2
      fm_lock_release "$RECEIPT_LOCK"
      exit 1
    fi
    if [ -s "$RECEIPT_INDEX" ]; then
      tail -n "$RECENT" "$RECEIPT_INDEX"
    fi
    fm_lock_release "$RECEIPT_LOCK"
    ;;
  validate)
    [ "$#" -eq 0 ] || usage
    VALIDATE_INPUT=$(cat)
    printf '%s\n' "$VALIDATE_INPUT" | receipt_valid_stdin || {
      echo "error: input is not a valid fm-receipt.v1 receipt" >&2
      exit 1
    }
    printf '%s\n' "$VALIDATE_INPUT" | jq -c .
    ;;
  *) usage ;;
esac
