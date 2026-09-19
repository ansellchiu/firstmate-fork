#!/usr/bin/env bash
# fm-findings-lib.sh - the per-task incidental-findings channel.
#
# ONE owner of the incidental-findings contract: the file location, the entry
# format, the slug and pending rules, record validation and dedup, the pending
# scan, and triage. bin/fm-findings.sh is the operator CLI (record, list,
# triage) over these functions. bin/fm-brief.sh's ship scaffold and
# bin/fm-promote.sh's ship instructions tell the worker the record command as
# a cross-reference, never a restatement of this format. bin/fm-teardown.sh
# and bin/fm-session-start.sh surface pending entries through
# fm_findings_pending_lines at their natural checkpoints; the
# per-task data dir is never removed by teardown, so a finding survives
# cleanup exactly like the task brief and a scout report.
#
# Layout under <data-dir>:
#   <task-id>/findings.md   append-only markdown, one `## finding:` entry per
#                           out-of-scope observation, created lazily
#
# Entry format (fm_findings_record writes it; fm_findings_triage edits it):
#   ## finding: <slug>
#   - status: pending
#   - recorded: <UTC ISO-8601 timestamp>
#   - evidence: <single line: file:line, command, or observation>
#   - suggested-disposition: <single line: the follow-up the worker suggests>
#   - context: <single line: what work was under way>   (only when supplied)
#
# Pending rule: an entry is PENDING exactly when its `- status:` line is
# absent or reads `pending`; any other value (triage writes `triaged ...`)
# hides it. The pending-default direction is deliberate: a torn or
# hand-mangled entry must surface for a human look rather than silently
# vanish. An entry whose header has an empty slug is surfaced as malformed
# for the same reason.
#
# Dedup rule: record is keyed on (slug, evidence) and applies only against a
# slug's newest entry while that entry is still PENDING and complete (it
# carries both an evidence and a suggested-disposition line). A torn entry
# left by a crashed record answers nothing about the new observation, so it
# never dedups and never blocks the slug: the retry appends a whole entry
# while the torn one keeps surfacing for a human look. Byte-identical
# evidence is an idempotent no-op success, so an accidental double record
# never doubles the entry. Different evidence is REFUSED without writing, so
# a genuinely new observation can never hide behind an open title; the worker
# picks a more specific title. Once the newest entry for a slug is triaged
# the slug is closed, not reserved: a later record appends a fresh pending
# entry so a re-observation after a dismissal surfaces again rather than
# reporting success into a closed entry. Fields are trimmed of surrounding
# blanks once at record time, so dedup compares what was written. This is
# record-level dedup only: deciding that a finding duplicates existing
# backlog work is firstmate's explicit triage judgment, never a mechanical
# act here.
#
# Triage rule: triage is the explicit close - firstmate files the follow-up
# work or dismisses the finding with a reason, then records that disposition
# as the triage note. A recorded finding never authorizes changing a project
# by itself and never expands the task it was recorded under.
#
# Concurrency: record and triage both mutate a task's file under that file's
# own lock (<findings.md>.lock, bin/fm-wake-lib.sh's lock primitives), so
# triage's read-rewrite-rename can never replace the inode under a record
# that appended in the meantime - firstmate triaging from the session-start
# digest while the recording worker still runs is the ordinary case. Reads
# (the pending scan) take no lock: an entry half-written by a crashed record
# degrades to the pending-default above, which surfaces rather than hides.

FM_FINDINGS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _fm_findings_lock / _fm_findings_unlock <file>: serialize the two mutating
# paths on one task's findings file. The wake library owns the lock
# primitives and is loaded only here, so the read-only pending scan keeps no
# dependency on it.
_fm_findings_lock() {
  command -v fm_lock_acquire_wait >/dev/null 2>&1 || {
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_FINDINGS_LIB_DIR/fm-wake-lib.sh"
  }
  fm_lock_acquire_wait "$1.lock"
}

_fm_findings_unlock() {
  fm_lock_release "$1.lock" || true
}

# fm_findings_trim <text>: surrounding blanks off a single-line field.
fm_findings_trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]\{1,\}//' -e 's/[[:space:]]\{1,\}$//'
}

# fm_findings_file <data-dir> <task-id>: the canonical findings path.
fm_findings_file() {
  printf '%s/%s/findings.md\n' "$1" "$2"
}

# fm_findings_slug <title>: slugified title on stdout; empty output means the
# caller must refuse the record. Lowercase, non-alphanumeric runs collapse to
# one dash, trimmed, capped at 48 characters.
fm_findings_slug() {
  local s
  s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//')
  s=${s:0:48}
  while [ -n "$s" ] && [ "${s%"${s%?}"}" = "-" ]; do s=${s%?}; done
  printf '%s' "$s"
}

# fm_findings_field_ok <text>: fields must be single lines so entries stay
# line-oriented and machine-scannable.
fm_findings_field_ok() {
  case "$1" in
    *$'\n'* | *$'\r'* | *$'\037'*) return 1 ;;
  esac
  return 0
}

# fm_findings_id_ok <task-id>: the id names exactly one directory under the
# data dir, so a record always lands where the one-level pending scan looks.
fm_findings_id_ok() {
  case "$1" in
    '' | .* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_findings_record <data-dir> <task-id> <title> <evidence> <disposition> [context]
# Appends one validated entry, or no-ops on an identical duplicate.
# Prints a one-line result; exit 0 recorded (or dedup no-op), 1 refused.
fm_findings_record() {
  local data=$1 id=$2 title=$3 evidence=$4 disposition=$5 context=${6:-}
  local file slug ts existing existing_status existing_shape rc
  [ -n "$id" ] || {
    echo "error: a task id is required" >&2
    return 1
  }
  fm_findings_id_ok "$id" || {
    echo "error: invalid task id '$id' (one path component of letters, digits, dot, dash, or underscore)" >&2
    return 1
  }
  [ -n "$title" ] || {
    echo "error: --title is required" >&2
    return 1
  }
  [ -n "$evidence" ] || {
    echo "error: --evidence is required (file:line, command, or observation)" >&2
    return 1
  }
  [ -n "$disposition" ] || {
    echo "error: --disposition is required (the follow-up you suggest)" >&2
    return 1
  }
  if ! fm_findings_field_ok "$title" || ! fm_findings_field_ok "$evidence" \
    || ! fm_findings_field_ok "$disposition" || ! fm_findings_field_ok "$context"; then
    echo "error: title, evidence, disposition, and context must each be a single line" >&2
    return 1
  fi
  evidence=$(fm_findings_trim "$evidence")
  disposition=$(fm_findings_trim "$disposition")
  context=$(fm_findings_trim "$context")
  [ -n "$evidence" ] || {
    echo "error: --evidence is required (file:line, command, or observation)" >&2
    return 1
  }
  [ -n "$disposition" ] || {
    echo "error: --disposition is required (the follow-up you suggest)" >&2
    return 1
  }
  slug=$(fm_findings_slug "$title")
  [ -n "$slug" ] || {
    echo "error: --title must contain at least one letter or digit" >&2
    return 1
  }
  file=$(fm_findings_file "$data" "$id")
  mkdir -p "$(dirname "$file")"
  _fm_findings_lock "$file" || {
    echo "error: could not lock $file for recording" >&2
    return 1
  }
  if [ -f "$file" ]; then
    if grep -q "^## finding: ${slug}\$" "$file" 2>/dev/null; then
      # The NEWEST block for the slug decides: an open and complete one
      # dedups; a triaged one is closed and a torn one carries no answer, so
      # both let the re-observation append afresh.
      existing=$(awk -v want="$slug" '
        function sep() { return sprintf("%c", 31) }
        /^## finding: / {
          curslug = $0
          sub(/^## finding:[ \t]*/, "", curslug)
          sub(/[ \t]+$/, "", curslug)
          inblock = (curslug == want)
          if (inblock) { status = ""; evidence = ""; has_evidence = 0; has_disposition = 0 }
          next
        }
        inblock && /^- status:/ {
          status = $0
          sub(/^- status:[ \t]*/, "", status)
          sub(/[ \t]+$/, "", status)
          next
        }
        inblock && /^- suggested-disposition:/ {
          has_disposition = 1
          next
        }
        inblock && /^- evidence:/ {
          evidence = $0
          sub(/^- evidence:[ \t]*/, "", evidence)
          sub(/[ \t]+$/, "", evidence)
          has_evidence = 1
        }
        END {
          printf "%s%s%s%s%s", status, sep(), \
            (has_evidence && has_disposition ? "complete" : "torn"), sep(), evidence
        }
      ' "$file")
      existing_status=${existing%%$'\037'*}
      existing=${existing#*$'\037'}
      existing_shape=${existing%%$'\037'*}
      existing=${existing#*$'\037'}
      if { [ -z "$existing_status" ] || [ "$existing_status" = pending ]; } \
        && [ "$existing_shape" = complete ]; then
        if [ "$existing" = "$evidence" ]; then
          _fm_findings_unlock "$file"
          echo "already recorded: $slug (identical evidence; nothing appended)"
          return 0
        fi
        _fm_findings_unlock "$file"
        echo "error: a finding '$slug' already exists in $file with different evidence; record the new observation under a more specific title" >&2
        return 1
      fi
    fi
  fi
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ ! -e "$file" ]; then
    printf '# Incidental findings - task %s\n\n' "$id" >> "$file"
  fi
  rc=0
  {
    printf '## finding: %s\n' "$slug"
    printf -- '- status: pending\n'
    printf -- '- recorded: %s\n' "$ts"
    printf -- '- evidence: %s\n' "$evidence"
    printf -- '- suggested-disposition: %s\n' "$disposition"
    [ -n "$context" ] && printf -- '- context: %s\n' "$context"
    printf '\n'
  } >> "$file" || rc=1
  _fm_findings_unlock "$file"
  [ "$rc" -eq 0 ] || {
    echo "error: could not append the finding to $file" >&2
    return 1
  }
  echo "recorded: $slug in $file"
  return 0
}

# fm_findings_pending_tsv <data-dir>: one record per pending entry across
# every task's findings file, fields joined with the ASCII unit separator
# (octal 037, never valid in a field) so empty fields survive the read:
#   <task> <slug> <recorded> <evidence> <disposition> <file-path>
# A malformed unnamed entry surfaces with an empty slug (the formatter labels
# it) so mangled entries are seen, never silently dropped.
fm_findings_pending_tsv() {
  local data=$1 file id
  [ -d "$data" ] || return 0
  for file in "$data"/*/findings.md; do
    [ -f "$file" ] || continue
    id=$(basename "$(dirname "$file")")
    awk -v task="$id" '
      function sep() { return sprintf("%c", 31) }
      function emit() {
        if (!inblock) return
        if (status == "" || status == "pending") {
          printf "%s%s%s%s%s%s%s%s%s%s%s\n", task, sep(), slug, sep(), (recorded == "" ? "unknown" : recorded), sep(), evidence, sep(), disposition, sep(), FILENAME
        }
        inblock = 0
      }
      /^## finding: / {
        emit()
        inblock = 1
        slug = $0
        sub(/^## finding:[ \t]*/, "", slug)
        sub(/[ \t]+$/, "", slug)
        status = ""; recorded = ""; evidence = ""; disposition = ""
        next
      }
      inblock && /^- status:/ {
        status = $0
        sub(/^- status:[ \t]*/, "", status)
        sub(/[ \t]+$/, "", status)
        next
      }
      inblock && /^- recorded:/ {
        recorded = $0
        sub(/^- recorded:[ \t]*/, "", recorded)
        next
      }
      inblock && /^- evidence:/ {
        evidence = $0
        sub(/^- evidence:[ \t]*/, "", evidence)
        next
      }
      inblock && /^- suggested-disposition:/ {
        disposition = $0
        sub(/^- suggested-disposition:[ \t]*/, "", disposition)
        next
      }
      END { emit() }
    ' "$file"
  done
}

# fm_findings_pending_lines <data-dir> <task-id|all> <limit>: human lines for
# surfacing, bounded by the caller's limit in scan order (task directory name,
# then file order - not by recorded age); a final "- and N more" line
# discloses any remainder. Exit 1 prints nothing when none pending.
fm_findings_pending_lines() {
  local data=$1 scope=$2 limit=$3
  local task slug recorded evidence disposition file shown=0 total=0
  while IFS=$'\037' read -r task slug recorded evidence disposition file; do
    [ -n "$task" ] || continue
    if [ "$scope" != "all" ] && [ "$task" != "$scope" ]; then
      continue
    fi
    total=$((total + 1))
    if [ "$total" -gt "$limit" ]; then
      continue
    fi
    if [ -z "$slug" ]; then
      printf -- '- (malformed unnamed entry - read %s)\n' "$file"
    else
      printf -- '- %s%s (%s): %s\n' \
        "$([ "$scope" = "all" ] && printf '%s/' "$task")" \
        "$slug" \
        "${recorded%%T*}" \
        "${disposition:-<no disposition recorded>}"
    fi
    shown=$((shown + 1))
  done <<EOF
$(fm_findings_pending_tsv "$data")
EOF
  [ "$total" -eq 0 ] && return 1
  if [ "$total" -gt "$shown" ]; then
    printf -- '- and %d more (read the tasks'"'"' findings.md files)\n' "$((total - shown))"
  fi
  return 0
}

# fm_findings_triage <data-dir> <task-id> <slug> <note>: close every pending
# entry with that slug by rewriting its status line to
# `- status: triaged <UTC> -- <note>` (inserting one directly under the
# header when a malformed entry lacks it). Exit 1 when the task id is not a
# single path component, the file is missing, the note is not a single line,
# or no pending entry carries the slug (an already-triaged slug refuses too).
fm_findings_triage() {
  local data=$1 id=$2 slug=$3 note=$4
  local file ts tmp rc
  [ -n "$slug" ] || {
    echo "error: a finding slug is required" >&2
    return 1
  }
  [ -n "$note" ] || {
    echo "error: --note is required (where the work went, or why dismissed)" >&2
    return 1
  }
  fm_findings_field_ok "$note" || {
    echo "error: --note must be a single line" >&2
    return 1
  }
  fm_findings_id_ok "$id" || {
    echo "error: invalid task id '$id' (one path component of letters, digits, dot, dash, or underscore)" >&2
    return 1
  }
  file=$(fm_findings_file "$data" "$id")
  [ -f "$file" ] || {
    echo "error: no findings file at $file" >&2
    return 1
  }
  _fm_findings_lock "$file" || {
    echo "error: could not lock $file for triage" >&2
    return 1
  }
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="${file}.triage.$$"
  # note and ts travel through the environment (raw, no awk -v escape
  # processing) so a note containing backslashes survives verbatim.
  FM_FINDINGS_TS="$ts" FM_FINDINGS_NOTE="$note" FM_FINDINGS_SLUG="$slug" \
    awk '
    function flush(   i) {
      if (!inblock) return
      if (matched) {
        print header
        if (!have_status) {
          print stamp
          changed++
        }
        for (i = 1; i <= nbuf; i++) print buf[i]
      }
      inblock = 0
      matched = 0
      nbuf = 0
    }
    BEGIN {
      stamp = "- status: triaged " ENVIRON["FM_FINDINGS_TS"] " -- " ENVIRON["FM_FINDINGS_NOTE"]
      want = ENVIRON["FM_FINDINGS_SLUG"]
    }
    /^## finding: / {
      flush()
      curslug = $0
      sub(/^## finding:[ \t]*/, "", curslug)
      sub(/[ \t]+$/, "", curslug)
      inblock = 1
      matched = (curslug == want)
      have_status = 0
      nbuf = 0
      header = $0
      if (!matched) print
      next
    }
    {
      if (!inblock || !matched) {
        print
        next
      }
      if (/^- status:[ \t]*(pending)?[ \t]*$/) {
        buf[++nbuf] = stamp
        changed++
        have_status = 1
        next
      }
      if (/^- status:/) {
        have_status = 1
      }
      buf[++nbuf] = $0
    }
    END {
      flush()
      exit (changed > 0 ? 0 : 1)
    }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"
    _fm_findings_unlock "$file"
    echo "error: no pending finding '$slug' in $file (unknown slug, or already triaged)" >&2
    return 1
  }
  rc=0
  mv "$tmp" "$file" || rc=1
  _fm_findings_unlock "$file"
  [ "$rc" -eq 0 ] || {
    rm -f "$tmp"
    echo "error: could not write the triaged entry back to $file" >&2
    return 1
  }
  echo "triaged: $slug in $file"
  return 0
}
