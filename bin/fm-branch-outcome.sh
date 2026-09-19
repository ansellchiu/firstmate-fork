#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false,
#     "present":true|false,"repeat":N,"statusEndpoint":N,"statusIdent":"..."}.
#     Legacy rows without `silent`, presentation fields, or status provenance
#     remain valid and are treated as visible.
#     `present` is the PRESENTATION decision and `repeat` its repeat count;
#     see "Repeat suppression" below. Every outcome is stored in full whatever
#     they say, so suppression can never become record loss.
#     Every read and append validates the complete log as a gap-free sequence;
#     malformed, duplicate, or reordered rows fail closed.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     Pi as a routine merge note, persisted as a sequence-keyed visible captain
#     entry, emitted by the locked session-start replay, or silently consumed
#     there because `silent` is true. Records above the cursor are unread.
#     A captain row advances only after its matching visible entry exists in
#     Pi's session, so reload recovery is idempotent across that crash window.
#     A cursor beyond the validated store tail fails closed.
#   - Repeat suppression: an unchanged routine fact about one task is stored
#     every time but PRESENTED only once per bounded window, because a repeat
#     the captain has already read trains them to skim past outcomes. At
#     append, a routine non-silent row is fingerprinted from its whitespace-
#     normalized summary and compared with that task's last presented
#     fingerprint in $STATE/.branch-outcome-dedupe (a bounded, evictable
#     CACHE; the row's own `present` and `repeat` fields are the authority).
#     A first-of-a-kind or changed fingerprint presents immediately and opens a
#     new window. An identical fingerprint inside the window is suppressed
#     (`present:false`) and counted. The first identical fingerprint after the
#     window expires presents ONCE carrying `repeat` = how many were suppressed,
#     and reopens the window, so expiry re-delivers rather than resuming a
#     stream. A `captain` row is NEVER suppressed and clears its task's window,
#     so the next routine note about that task is presented again; that clear
#     runs once the row is durable, and a window that cannot be cleared fails
#     the append loudly rather than surviving to suppress the next routine
#     note - the stored outcome is still delivered by the next read. A `silent`
#     row is `present:false` with no window effect: it was already not rendered.
#     Window: $FM_BRANCH_OUTCOME_DEDUPE_WINDOW seconds, default 21600 (6h);
#     0 disables suppression, and a malformed value falls back to the default
#     rather than silently disabling it. An unreadable or unwritable cache
#     presents the outcome: the safe direction here is noise, never loss.
#     The window a row opens is recorded only after that row is durable, so an
#     append that never reached the store cannot suppress its own retry, and a
#     count the cache cannot be trusted to increment restarts at zero.
#   - Processed marker: $STATE/.branch-outcomes-processed holds the highest
#     seq whose captain rows main has ACKNOWLEDGED as processed, separately
#     from the read cursor: reading (the visible entry) is the branch's act,
#     processing (main acting on the outcome and calling its acknowledgement
#     tool) is main's. A captain row between the two markers is "unprocessed":
#     delivered and shown, not yet acted on. Routine rows never wait on this
#     marker. It only advances through an explicit sequence-bound
#     acknowledgement naming a currently unprocessed captain row at or below
#     the read cursor; a routine, unread, or already-processed target is
#     refused. It never moves past the read cursor or backwards, so an
#     unrelated or empty model answer cannot move it. An absent marker reads as
#     0 (every delivered captain row is unprocessed, the safe direction);
#     processed-init is the one-time migration that sets an absent marker to
#     the read cursor so rows delivered before the marker existed are not
#     re-presented. A present marker is validated before the migration returns,
#     and a marker ahead of the read cursor fails closed.
#   - Outcome index: $STATE/.<task>.branch-outcome-index stores one bounded
#     cache of the latest PRESENTED outcome's status provenance, because the
#     index answers "how far has this task's status log already reached the
#     captain", not "how far has it been stored". A suppressed repeat leaves
#     the cache at the last presented row's endpoint, so a status event the
#     captain has never seen stays uncovered and main's drain backstop can
#     still resurface it. The authoritative copy is in the append-only row. $STATE/.branch-outcome-index-ready is removed
#     before append and published only after the cache update; processed-init
#     rebuilds every cache before publishing it, so interruption or upgrade
#     fails closed without making each drain scan lifetime history.
#     bin/fm-teardown.sh removes a retired task's cache with its other records,
#     and append skips the cache for a task that has neither a live meta nor a
#     status log (the outcome itself is still stored), so the branch's report
#     of a teardown it just performed leaves no index behind.
#     Main-actor drain calls processed-init under the outcome lock when that
#     ready marker is absent or invalid, on every harness; only a genuine store
#     fault keeps the lost-wake backstop skipped.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the outcome is delivered to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh forget --task <id>
#     Drop that task's repeat-suppression window, so its next routine outcome
#     is presented as a first-of-a-kind fact. bin/fm-teardown.sh calls it for a
#     retired task id, which a later task may reuse. Never touches the store.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after handing the records to Pi.
#   fm-branch-outcome.sh unprocessed
#     Print every captain record that is read but not yet processed (raw
#     JSONL, ascending seq). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-processed --through <seq>
#     Advance the processed marker after main acknowledged the captain rows
#     through <seq>; the target itself must be a currently unprocessed captain
#     row at or below the read cursor.
#   fm-branch-outcome.sh processed-init [--held-lock]
#     Rebuild the bounded per-task outcome indexes, then create the processed
#     marker at the current read cursor when it does not exist yet; validate a
#     present marker without changing it. --held-lock is only for a descendant
#     of the process holding $STATE/.branch-outcomes.lock (fm-wake-drain.sh may
#     run its redirected presentation body in a subshell on Bash 3.2); it skips
#     the nested acquire so drain's bounded lock wait remains the deadline.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print the leading routine unread records under a
#     labeled header into the locked startup digest, skip rows whose `silent`
#     field is true, and mark those leading routine rows read. Stop before the
#     first captain row because only Pi's sequence-keyed visible entry may
#     acknowledge that row. Prints nothing when nothing replayable is unread.
#     Run it only when the session holds the lock (fm-session-start.sh owns the
#     call site).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
PROCESSED="$STATE/.branch-outcomes-processed"
LOCK="$STATE/.branch-outcomes.lock"
MAX_SAFE_SEQ=9007199254740991
OUTCOME_INDEX_VERSION=fm-branch-outcome-index-v1
OUTCOME_INDEX_MAX_BYTES=512
OUTCOME_INDEX_READY="$STATE/.branch-outcome-index-ready"
DEDUPE="$STATE/.branch-outcome-dedupe"
DEDUPE_VERSION=fm-branch-outcome-dedupe-v1
DEDUPE_MAX_ENTRIES=128
DEDUPE_WINDOW_DEFAULT=21600
TAB=$(printf '\t')

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] | forget --task <id> | unread | mark-read --through <seq> | unprocessed | mark-processed --through <seq> | processed-init [--held-lock] | list [--recent <n>] | startup-replay" >&2
  exit 2
}

bounded_uint() {
  local value=$1
  case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#value}" -le "${#MAX_SAFE_SEQ}" ] || return 1
  [ "$value" -le "$MAX_SAFE_SEQ" ]
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  [ -e "$CURSOR" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$CURSOR" 2>/dev/null); then
    echo "error: refusing operation because the outcome cursor is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the outcome cursor is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the outcome cursor is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

read_processed() {
  local value
  [ -e "$PROCESSED" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$PROCESSED" 2>/dev/null); then
    echo "error: refusing operation because the processed marker is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the processed marker is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the processed marker is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

last_seq() {
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  jq -Rse '
    def valid:
      type == "object"
      and (
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
        or (
          keys == ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"]
          and (.silent | type) == "boolean"
          and ((.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint <= 9007199254740991 and .statusEndpoint == (.statusEndpoint | floor))
          and ((.statusIdent | type) == "string" and (.statusIdent | test("[\\t\\n]") | not))
        )
        or (
          keys == ["epoch", "present", "repeat", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"]
          and (.silent | type) == "boolean"
          and (.present | type) == "boolean"
          and ((.repeat | type) == "number" and .repeat >= 0 and .repeat <= 9007199254740991 and .repeat == (.repeat | floor))
          and ((.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint <= 9007199254740991 and .statusEndpoint == (.statusEndpoint | floor))
          and ((.statusIdent | type) == "string" and (.statusIdent | test("[\\t\\n]") | not))
        )
      )
      and ((.seq | type) == "number" and .seq >= 1 and .seq <= 9007199254740991 and .seq == (.seq | floor))
      and ((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
      and ((.task | type) == "string" and (.wake | type) == "string")
      and ((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
      and (.silent != true or (.task == "fleet" and .verdict == "routine"))
      and (.present != false or .verdict == "routine")
      and ((.repeat // 0) == 0 or (.present == true and .verdict == "routine"));
    if endswith("\n") then split("\n")[:-1]
    else error("unterminated outcome store")
    end
    | map(fromjson)
    | . as $rows
    | if reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid and .seq == ($i + 1)))
      then .[-1].seq
      else error("malformed or non-sequential outcome store")
      end
  ' "$STORE" 2>/dev/null
}

record_seq() { # <jsonl-line>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | jq -er '.seq'
}

outcome_index_path() { # <task>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.%s.branch-outcome-index' "$STATE" "$1"
}

capture_status_position() { # <task>
  local f="$STATE/$1.status" size ident size_after ident_after
  CAPTURED_STATUS_ENDPOINT=0
  CAPTURED_STATUS_IDENT=-
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  size=$(_fm_status_file_size "$f") || return 0
  size=${size//[[:space:]]/}
  ident=$(_fm_open_decisions_file_ident "$f") || return 0
  size_after=$(_fm_status_file_size "$f") || return 0
  size_after=${size_after//[[:space:]]/}
  ident_after=$(_fm_open_decisions_file_ident "$f") || return 0
  case "$size:$size_after" in *[!0-9:]*) return 0 ;; esac
  [ "$size" = "$size_after" ] && [ "$ident" = "$ident_after" ] || return 0
  case "$ident" in *$'\t'*|*$'\n'*|'') return 0 ;; esac
  CAPTURED_STATUS_ENDPOINT=$size
  CAPTURED_STATUS_IDENT=$ident
}

write_outcome_index() { # <task> <seq> [<endpoint> <identity>]
  local task=$1 seq=$2 endpoint=${3:-$CAPTURED_STATUS_ENDPOINT} ident=${4:-$CAPTURED_STATUS_IDENT} path tmp record
  path=$(outcome_index_path "$task") || return 1
  record=$(printf '%s\t%s\t%s\t%s\n' "$OUTCOME_INDEX_VERSION" "$seq" \
    "$endpoint" "$ident") || return 1
  [ "${#record}" -le "$OUTCOME_INDEX_MAX_BYTES" ] || return 1
  tmp=$(mktemp "$STATE/.branch-outcome-index.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$record" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# The status provenance of this task's newest PRESENTED row, which is the
# coverage the index may claim. No presented row means nothing about this task
# has reached the captain, so nothing is covered.
presented_status_position() { # <task>
  local task=$1 row
  PRESENTED_STATUS_ENDPOINT=0
  PRESENTED_STATUS_IDENT=-
  PRESENTED_STATUS_SEQ=
  [ -s "$STORE" ] || return 0
  row=$(jq -r -s --arg task "$task" '
    map(select(.task == $task and .present != false and .silent != true))
    | last
    | if . == null then empty
      else [(.seq | tostring), ((.statusEndpoint // 0) | tostring), (.statusIdent // "-")] | @tsv
      end
  ' "$STORE") || return 1
  [ -n "$row" ] || return 0
  PRESENTED_STATUS_SEQ=${row%%"$TAB"*}
  PRESENTED_STATUS_IDENT=${row##*"$TAB"}
  row=${row#*"$TAB"}
  PRESENTED_STATUS_ENDPOINT=${row%%"$TAB"*}
  case "$PRESENTED_STATUS_ENDPOINT" in ''|*[!0-9]*) PRESENTED_STATUS_ENDPOINT=0; PRESENTED_STATUS_IDENT=- ;; esac
  [ -n "$PRESENTED_STATUS_IDENT" ] || PRESENTED_STATUS_IDENT=-
}

publish_outcome_index_ready() { # <seq>
  local tmp
  tmp=$(mktemp "$STATE/.branch-outcome-index-ready.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$OUTCOME_INDEX_READY"
}

rebuild_outcome_indexes() {
  local rows task seq epoch endpoint ident f mtime
  rm -f -- "$OUTCOME_INDEX_READY" || return 1
  [ -s "$STORE" ] || { publish_outcome_index_ready 0; return; }
  # Rebuilt coverage is PRESENTED coverage: a task whose newest rows were all
  # suppressed repeats is covered only through its last presented row, and a
  # task with no presented row at all is covered nowhere.
  rows=$(jq -r -s '
    map(select(.task != "fleet"))
    | group_by(.task)
    | map(
        (map(select(.present != false and .silent != true)) | last) as $p
        | if $p == null
          then [(.[-1].task), (.[-1].seq | tostring), (.[-1].epoch | tostring), "0", "-"]
          else [$p.task, ($p.seq | tostring), ($p.epoch | tostring),
                (($p.statusEndpoint // "") | tostring), ($p.statusIdent // "")]
          end
      )[]
    | @tsv
  ' "$STORE") || return 1
  while IFS=$(printf '\t') read -r task seq epoch endpoint ident; do
    [ -n "$task" ] || continue
    if [ -z "$endpoint" ] || [ -z "$ident" ]; then
      f="$STATE/$task.status"
      endpoint=0
      ident=-
      if [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ]; then
        mtime=$(_fm_status_file_mtime "$f") || mtime=
        case "$mtime" in ''|*[!0-9]*) ;;
          *)
            # Legacy rows have only whole-second epochs, so equal timestamps
            # cannot prove whether the status preceded the outcome. Leave that
            # span uncovered: migration may rarely duplicate an old handled
            # event, but it will not hide a plausibly later captain-facing one.
            if [ "$mtime" -lt "$epoch" ]; then
              capture_status_position "$task"
              endpoint=$CAPTURED_STATUS_ENDPOINT
              ident=$CAPTURED_STATUS_IDENT
            fi
            ;;
        esac
      fi
    fi
    write_outcome_index "$task" "$seq" "$endpoint" "$ident" || return 1
  done <<EOF
$rows
EOF
  publish_outcome_index_ready "$(last_seq)"
}

# --- Repeat suppression ------------------------------------------------------
#
# The header's "Repeat suppression" bullet is the contract; this is its
# mechanism. Every failure direction in the presentation decision and in the
# window it opens PRESENTS the outcome, because an extra note costs the captain
# a glance while a wrongly hidden one costs them the event. The one direction
# that fails loudly instead is the captain-path window clear, which would
# otherwise leave a window standing that hides the next routine note; it runs
# only once the outcome is durable.

DECIDED_PRESENT=true
DECIDED_REPEAT=0
PENDING_WINDOW=
PENDING_COUNT=0
PENDING_FINGERPRINT=

dedupe_window() {
  local value=${FM_BRANCH_OUTCOME_DEDUPE_WINDOW:-}
  case "$value" in
    ''|*[!0-9]*|0[0-9]*) printf '%s\n' "$DEDUPE_WINDOW_DEFAULT"; return 0 ;;
  esac
  if bounded_uint "$value"; then printf '%s\n' "$value"; else printf '%s\n' "$DEDUPE_WINDOW_DEFAULT"; fi
}

# Whitespace-normalized so a re-wrapped identical fact still reads as identical,
# but nothing stronger: undersuppressing a repeat is far cheaper than
# suppressing a genuine change.
summary_fingerprint() { # <summary>
  local normalized
  normalized=$(printf '%s' "$1" | tr '\n\t' '  ' | awk '{ $1 = $1; print }')
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$normalized" | shasum -a 256 2>/dev/null | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$normalized" | sha256sum 2>/dev/null | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$normalized" | cksum | awk '{printf "%08x%08x\n", $1, $2}'
  fi
}

dedupe_other_entries() { # <task> - every valid cache line except this task's
  [ -f "$DEDUPE" ] && [ -r "$DEDUPE" ] && [ ! -L "$DEDUPE" ] || return 0
  awk -F'\t' -v ver="$DEDUPE_VERSION" -v task="$1" '
    NR == 1 { if ($0 != ver) exit 0; next }
    NF == 4 && $1 != task && $1 ~ /^[A-Za-z0-9._-]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print }
  ' "$DEDUPE" 2>/dev/null || true
}

dedupe_replace() { # <task> <window-epoch> <suppressed-count> <fingerprint>
  local tmp
  tmp=$(mktemp "$STATE/.branch-outcome-dedupe.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$DEDUPE_VERSION"
    # Newest window first, then truncate: the cache stays bounded by evicting
    # the tasks whose windows are oldest and therefore closest to expiry anyway.
    {
      printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
      dedupe_other_entries "$1"
    } | sort -t"$TAB" -k2,2nr | head -n "$DEDUPE_MAX_ENTRIES"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  # A truncated write would still parse as a cache, so prove the version line
  # landed rather than publishing a file whose first entry reads as a header.
  [ "$(head -n 1 "$tmp")" = "$DEDUPE_VERSION" ] || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$DEDUPE"
}

dedupe_forget() { # <task> - drop this task's window entirely
  local tmp
  [ -f "$DEDUPE" ] && [ ! -L "$DEDUPE" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcome-dedupe.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$DEDUPE_VERSION"
    dedupe_other_entries "$1"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  [ "$(head -n 1 "$tmp")" = "$DEDUPE_VERSION" ] || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$DEDUPE"
}

# Sets DECIDED_PRESENT and DECIDED_REPEAT for one routine, non-silent outcome,
# and the PENDING_* window its caller commits once the row is durable. Reading
# decides nothing else: a window recorded before the outcome exists could
# suppress the retry of a report that was never stored or delivered.
dedupe_decide() { # <task> <fingerprint> <now>
  local task=$1 fingerprint=$2 now=$3 window entry stored_window stored_count stored_fingerprint age
  local next_window=$3 next_count=0
  DECIDED_PRESENT=true
  DECIDED_REPEAT=0
  window=$(dedupe_window)
  entry=''
  if [ -f "$DEDUPE" ] && [ -r "$DEDUPE" ] && [ ! -L "$DEDUPE" ]; then
    entry=$(awk -F'\t' -v ver="$DEDUPE_VERSION" -v task="$task" '
      NR == 1 { if ($0 != ver) exit 0; next }
      NF == 4 && $1 == task && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $2 "\t" $3 "\t" $4; exit 0 }
    ' "$DEDUPE" 2>/dev/null) || entry=''
  fi
  if [ -n "$entry" ] && [ "$window" -gt 0 ]; then
    stored_window=${entry%%"$TAB"*}
    stored_fingerprint=${entry##*"$TAB"}
    stored_count=${entry#*"$TAB"}
    stored_count=${stored_count%%"$TAB"*}
    # The cache may never cost more than a repeated note, so a count that is
    # not a safe integer to increment restarts at zero rather than wrapping
    # into the row's `repeat` and failing every later read of the store.
    if ! bounded_uint "$stored_count" || [ "$stored_count" -ge "$MAX_SAFE_SEQ" ]; then
      stored_count=0
    fi
    if [ "$stored_fingerprint" = "$fingerprint" ]; then
      age=$(( now - stored_window ))
      # A backwards clock leaves the window unprovable, so present and restart
      # it rather than suppressing on arithmetic nobody can trust.
      if [ "$age" -ge 0 ] && [ "$age" -lt "$window" ]; then
        DECIDED_PRESENT=false
        next_window=$stored_window
        next_count=$(( stored_count + 1 ))
      else
        DECIDED_REPEAT=$stored_count
      fi
    fi
  fi
  PENDING_WINDOW=$next_window
  PENDING_COUNT=$next_count
  PENDING_FINGERPRINT=$fingerprint
}

print_unread() {
  local cursor last
  cursor=$(read_cursor)
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson cursor "$cursor" 'select(.seq > $cursor)' "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor processed tmp
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing cursor advancement because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

write_processed() { # <seq>
  local through=$1 tmp
  tmp=$(mktemp "$STATE/.branch-outcomes-processed.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$PROCESSED"
}

# Captain rows above the processed marker and at or below the read cursor.
print_unprocessed() {
  local cursor processed last
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing read because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson processed "$processed" --argjson cursor "$cursor" \
    'select(.verdict == "captain" and .seq > $processed and .seq <= $cursor)' "$STORE"
}

# Assumes $LOCK is already held. Callers that do not already hold it use the
# processed-init command, which acquires and releases around this body.
processed_init_locked() {
  local store_last cursor_seq processed_seq
  if ! store_last=$(last_seq); then
    echo "error: refusing processed initialization because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if ! cursor_seq=$(read_cursor); then
    return 1
  fi
  if [ "$cursor_seq" -gt "$store_last" ]; then
    echo "error: refusing processed initialization because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ -e "$PROCESSED" ]; then
    if ! processed_seq=$(read_processed); then
      return 1
    fi
    if [ "$processed_seq" -gt "$cursor_seq" ]; then
      echo "error: refusing processed initialization because the processed marker is ahead of the read cursor" >&2
      return 1
    fi
  else
    write_processed "$cursor_seq" || return 1
  fi
  if ! rebuild_outcome_indexes; then
    echo "error: outcome index migration could not be completed safely" >&2
    return 1
  fi
}

held_lock_owned_by_ancestor() {
  local owner owner_pid pid parent depth=0
  case "$PPID" in ''|*[!0-9]*|0|1) return 1 ;; esac
  if [ -L "$LOCK" ]; then
    owner=$(fm_lock_link_owner "$LOCK" 2>/dev/null) || return 1
    fm_lock_points_to_owner "$LOCK" "$owner" || return 1
  elif [ -d "$LOCK" ]; then
    owner=$LOCK
  else
    return 1
  fi
  owner_pid=$(cat "$owner/pid" 2>/dev/null) || return 1
  fm_pid_alive "$owner_pid" || return 1

  # Bash 3.2 keeps $$ unchanged in a redirected subshell while that subshell's
  # real pid becomes this script's parent. Walk the bounded live ancestry so
  # that legitimate drain shape is accepted without trusting an arbitrary
  # caller merely because it can name or observe the lock owner.
  pid=$PPID
  while [ "$depth" -lt 64 ]; do
    [ "$pid" = "$owner_pid" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
    depth=$((depth + 1))
  done
  return 1
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    outcome_index_path "$TASK" >/dev/null || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    if [ "$SILENT" = true ] && { [ "$TASK" != fleet ] || [ "$VERDICT" != routine ]; }; then
      echo "error: silent outcomes must be routine fleet outcomes" >&2
      exit 2
    fi
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor) || [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome cursor is invalid or ahead of the store" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    NOW=$(date +%s)
    # Presentation decision (header: "Repeat suppression"). A captain outcome
    # is always presented and reopens its task's window; a silent fleet review
    # was already unrendered; only a routine note can repeat itself into noise.
    DECIDED_PRESENT=true
    DECIDED_REPEAT=0
    # Both window actions are deferred until the row is durable: a window
    # opened or left standing over an outcome that was never stored decides
    # the presentation of a retry that nobody has seen.
    WINDOW_ACTION=none
    if [ "$SILENT" = true ]; then
      DECIDED_PRESENT=false
    elif [ "$VERDICT" = captain ]; then
      WINDOW_ACTION=clear
    else
      dedupe_decide "$TASK" "$(summary_fingerprint "$SUMMARY")" "$NOW"
      WINDOW_ACTION=open
    fi
    capture_status_position "$TASK"
    rm -f -- "$OUTCOME_INDEX_READY" || { fm_lock_release "$LOCK"; exit 1; }
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"present":%s,"repeat":%s,"statusEndpoint":%s,"statusIdent":"%s"}\n' \
      "$SEQ" "$NOW" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$DECIDED_PRESENT" "$DECIDED_REPEAT" \
      "$CAPTURED_STATUS_ENDPOINT" \
      "$(json_escape "$CAPTURED_STATUS_IDENT")" >> "$STORE"
    # A task with neither a live meta nor a status log is retired: the branch
    # reports the teardown it just performed, and writing the index here would
    # recreate the footprint teardown removed. The outcome itself is still
    # stored and delivered; only the reader-less cache is skipped.
    if [ -e "$STATE/$TASK.meta" ] || [ -e "$STATE/$TASK.status" ]; then
      INDEX_SEQ=$SEQ
      INDEX_ENDPOINT=$CAPTURED_STATUS_ENDPOINT
      INDEX_IDENT=$CAPTURED_STATUS_IDENT
      if [ "$DECIDED_PRESENT" != true ]; then
        # The index claims coverage, and a suppressed row covered nothing: hold
        # it at the last presented row so a status event the captain never saw
        # stays uncovered for main's drain backstop.
        if ! presented_status_position "$TASK"; then
          fm_lock_release "$LOCK"
          echo "error: outcome was stored but its presented coverage could not be resolved" >&2
          exit 1
        fi
        INDEX_ENDPOINT=$PRESENTED_STATUS_ENDPOINT
        INDEX_IDENT=$PRESENTED_STATUS_IDENT
        [ -z "$PRESENTED_STATUS_SEQ" ] || INDEX_SEQ=$PRESENTED_STATUS_SEQ
      fi
      if ! write_outcome_index "$TASK" "$INDEX_SEQ" "$INDEX_ENDPOINT" "$INDEX_IDENT"; then
        fm_lock_release "$LOCK"
        echo "error: outcome was stored but its bounded task index could not be updated" >&2
        exit 1
      fi
    fi
    if ! publish_outcome_index_ready "$SEQ"; then
      fm_lock_release "$LOCK"
      echo "error: outcome was stored but its bounded task index could not be updated" >&2
      exit 1
    fi
    case "$WINDOW_ACTION" in
      clear)
        if ! dedupe_forget "$TASK"; then
          fm_lock_release "$LOCK"
          echo "error: outcome was stored but its task's repeat-suppression window could not be cleared" >&2
          exit 1
        fi
        ;;
      open)
        # A window that cannot be recorded costs a repeated note next time,
        # never a hidden one, so it never fails an append that already landed.
        dedupe_replace "$TASK" "$PENDING_WINDOW" "$PENDING_COUNT" "$PENDING_FINGERPRINT" || true
        ;;
    esac
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  forget)
    [ "${1:-}" = --task ] || usage
    TASK=${2:-}
    [ "$#" -eq 2 ] || usage
    outcome_index_path "$TASK" >/dev/null || usage
    fm_lock_acquire_wait "$LOCK"
    dedupe_forget "$TASK" || { fm_lock_release "$LOCK"; echo "error: could not drop the task's repeat-suppression window" >&2; exit 1; }
    fm_lock_release "$LOCK"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement beyond a valid stored outcome" >&2
      exit 1
    fi
    if ! advance_cursor "$THROUGH"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  unprocessed)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unprocessed
    STATUS=$?
    fm_lock_release "$LOCK"
    exit "$STATUS"
    ;;
  mark-processed)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! CURSOR_SEQ=$(read_cursor) || ! PROCESSED_SEQ=$(read_processed); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$PROCESSED_SEQ" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the processed marker is ahead of the read cursor" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement beyond the read cursor ($CURSOR_SEQ)" >&2
      exit 1
    fi
    if [ "$THROUGH" -le "$PROCESSED_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is already processed" >&2
      exit 1
    fi
    VERDICT=$(jq -r --argjson through "$THROUGH" 'select(.seq == $through) | .verdict' "$STORE")
    if [ "$VERDICT" != captain ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is not an unprocessed captain outcome" >&2
      exit 1
    fi
    write_processed "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  processed-init)
    HELD_LOCK=0
    if [ "${1:-}" = --held-lock ]; then
      HELD_LOCK=1
      shift
    fi
    [ "$#" -eq 0 ] || usage
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_acquire_wait "$LOCK"
    elif ! held_lock_owned_by_ancestor; then
      echo "error: --held-lock requires an ancestor process to own the outcome lock" >&2
      exit 1
    fi
    if ! processed_init_locked; then
      if [ "$HELD_LOCK" -eq 0 ]; then
        fm_lock_release "$LOCK"
      fi
      exit 1
    fi
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_release "$LOCK"
    fi
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ -s "$STORE" ]; then
      tail -n "$RECENT" "$STORE"
    fi
    fm_lock_release "$LOCK"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      REPLAYABLE=$(printf '%s\n' "$UNREAD" | jq -sc '
        map(.verdict) as $verdicts
        | ($verdicts | index("captain")) as $captain
        | .[0:($captain // length)][]
      ')
      # Legacy rows carry no presentation decision, so both guards are load
      # bearing: `silent` covers them, `present` covers every current row.
      VISIBLE=$(printf '%s\n' "$REPLAYABLE" | jq -c 'select(.silent != true and .present != false)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$REPLAYABLE" | tail -n 1)")
      if [ -n "$LAST" ] && ! advance_cursor "$LAST"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
    fi
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
