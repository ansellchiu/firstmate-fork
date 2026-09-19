#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The single-project read's consumers are bin/fm-fleet-sync.sh (skip local-only
# clones), bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh (refuse local-only
# seeding, run no-mistakes init), bin/fm-spawn.sh's registry-deviation check,
# and bin/fm-send.sh's validation-trigger posture check. Every one of them fails
# closed on a non-zero read - a guard that cannot read its posture refuses,
# never guesses - so a mistyped annotation surfaces as a refusal naming the
# file, the annotation, and the caller, never as a silently disabled guard.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#   - <name> (added <date>)                            -> no-mistakes off
#
# The "(added <date>)" tail is REQUIRED on every entry, and <date> must be a real
# YYYY-MM-DD date so that prose ending in some other "(added ...)" parenthetical
# is not mistaken for an entry. Further clauses may follow the date, as in
# "(added 2026-08-14; renamed 2026-08-20)". The " - <desc>" separator is
# optional, so "- delta [+parked] (added 2026-01-02)" lists like any other entry.
#
# --list reads a bullet as ENTRY-SHAPED when its first word is the project name
# and EITHER nothing follows that name OR the added-date tail is the WHOLE
# remainder after it OR a "[...]" annotation or the " - " description separator
# follows it. The date alternative is what lets a bare "- alpha (added
# 2026-01-01)" list, and it is whole-remainder so that a note like "- alpha moved
# off the old host (added 2026-05-01)" stays prose instead of listing as a second
# alpha row. The other two are what make an entry-shaped bullet that lacks the
# tail a hard error naming the line, after which the portfolio classification
# takes its unavailable path. A name-only "- alpha" is such a bullet rather than
# prose, because it is far more plausibly a half-written entry, and because that
# keeps the required added-date tail required without exception. The cost is
# accepted deliberately: a prose bullet of exactly two words, such as "- Ideas",
# also fails. The registry is firstmate-maintained, the failure names the line,
# and the correction is trivial, so a loud fixable error beats quietly ignoring a
# bullet that may be a project whose parking decision would vanish with it.
# It is not skipped: a dropped row would take its +parked and +focus flags with
# it, so a dateless "- alpha [+parked] - shelved" would read as an unparked
# project and silently void the captain's parking decision - the same failure the
# flag rule below fails hard to prevent, and the reason both rules are loud.
#
# The "[...]" annotation must IMMEDIATELY follow the project name, separated from
# it by a space. That parsed slot is the only place a flag is read, so ONE rule
# covers every other placement: a bracket group anywhere else in the raw line
# whose content carries a "+"-prefixed token is a MISPLACED annotation, and
# --list fails naming the line rather than reading the flags out of a slot
# nothing parses. The scan is over the raw line, not over whitespace-separated
# fields, so gluing the brackets to a word hides nothing. All of these refuse:
#   - alpha - app [+parked] (added <date>)     after the description
#   - alpha - app[+parked] (added <date>)      glued after the description
#   - alpha[+parked] - app (added <date>)      glued to the name
#   - alpha [no-mistakes][+parked] - app (...) a second, adjacent group
#   - alpha (added <date>) [+parked]           after the added-date tail
# The one group exempt from the rule is the parsed slot itself, identified by
# where it BEGINS - the character position field 3 starts at - not by being the
# first group on the line, so an earlier glued group as in
# "- alpha[+parked] [no-mistakes] - app (...)" is still the misplaced one. A "["
# inside the resolved slot is the same error, so an unterminated annotation as in
# "- alpha [no-mistakes - app [+parked] (...)" cannot swallow a later group.
# A glued group is never parsed as the in-place annotation, and two adjacent
# groups are never read as one. A bracket group whose "+" does not begin a token,
# as in "[C++]" or "[staging+prod]", carries no flag and is ordinary prose.
#
# A project may hold only ONE entry. A name --list sees twice is a hard error
# naming the project, because choosing between the rows or merging them could
# either way discard the captain's parking decision.
#
# A bullet that is not entry-shaped is prose and is ignored, so ordinary notes
# can live in the registry. The cost of the rule above is that registry prose
# must not be WRITTEN in the entry shape: "- Never - do this thing." reads as a
# dateless entry and fails. Keep prose out of that shape.
#
# An entry is a bullet whose dash sits at COLUMN 0. To --list an INDENTED bullet
# is a note on the entry above it, never an entry, so a nested
# "  - blocked - waiting on the captain" is free to be written in the entry shape
# and neither fails --list nor becomes a project.
# An indented bullet that carries the added-date tail or any "+" token in a
# "[...]" annotation is the one exception: that shape is a MISPLACED entry rather
# than a note, so --list fails naming the line and saying an entry must start at
# column 0. Any "+" token counts, not just the three accepted flags, so a
# mistyped "+parkd" on an indented bullet is caught by the same rule.
# Silently dropping it would take its +parked and +focus flags with it, which is
# the same permissive answer the two rules above are loud to prevent.
#
# The single-project delivery-posture read stays permissive about MATCHING: it
# matches any bullet whose first word is the project name, indented or not and
# with no added-date requirement, so both a dateless "- alpha [local-only] - x"
# and an indented one still resolve to local-only. The column-0 rule above is a
# --list rule only, and the dateless-entry hard error stays a --list error: the
# single-project read needs no added-date tail to answer. Matching is permissive
# so a line it recognizes still answers; what it is never permissive about is an
# annotation it cannot trust, which exits non-zero for its callers to refuse on.
#
# The annotation slot also carries portfolio flags, which are orthogonal to the
# delivery posture and never change the "<mode> <yolo>" output:
#   +focus   the captain's single focus project
#   +parked  parked: registered but deliberately quiet until reopened
# bin/fm-attention-lib.sh is the single owner of what those flags mean.
# Any "+" token is a flag, never a mode, so an annotation that carries only
# flags (e.g. "[+parked]") keeps the registered default mode.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --list prints one TAB-separated row per registered project:
#   <name>\t<raw-mode>\t<yolo on|off>\t<focus on|off>\t<parked on|off>
# It is the machine surface for portfolio consumers and takes no project name.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
#
# +yolo, +focus, and +parked are the accepted flags. An unrecognized "+" token
# fails hard on BOTH surfaces, naming the project, the token, and the registry
# file. --list feeds the portfolio classification, which then takes its
# unavailable path rather than reading a mistyped "+parkd" as an unparked
# project and silently voiding the captain's parking decision. The
# single-project read exits non-zero for the same reason: its delivery-posture
# callers refuse the operation on that non-zero exit, so a mistyped annotation
# can never silently void the local-only guard by answering with a guessed
# posture. A legacy entry with no bracket keeps its existing meaning.

# Usage: fm-project-mode.sh [--raw] <project-name>
#        fm-project-mode.sh --list
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
LIST=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --list) LIST=1; shift ;;
esac

# Shared awk program: split a registry annotation into mode and flags. Kept in
# one string so the single-project read and --list can never drift apart on what
# an annotation MEANS; they differ only in which bullets they recognize as an
# entry, which the header states as a rule.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
ANNOTATION_AWK='
  function has_added_tail() {
    return ($0 ~ /\(added[[:space:]]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][^)]*\)[[:space:]]*$/);
  }
  function is_top_level() {
    return ($0 ~ /^-[[:space:]]/);
  }
  function is_indented_bullet() {
    return ($0 ~ /^[[:space:]]+-[[:space:]]/ && NF >= 2);
  }
  function annotation_body(   s, i, start) {
    start = 0;
    for (i=2; i<=NF; i++) { if ($i ~ /^\[/) { start = i; break } }
    if (start == 0) return "";
    s="";
    for (i=start; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
    gsub(/^\[|\]$/, "", s);
    return s;
  }
  function slot_start(   pos, i) {
    if ($3 !~ /^\[/) return 0;
    pos = 1;
    while (substr($0, pos, 1) ~ /[[:space:]]/) pos++;
    for (i=1; i<=2; i++) {
      pos += length($i);
      while (substr($0, pos, 1) ~ /[[:space:]]/) pos++;
    }
    return pos;
  }
  function has_flag_token(all_groups,   rest, at, end, body, k, a, j, pos, slot, gstart) {
    slot = all_groups ? 0 : slot_start();
    rest = $0; pos = 0;
    while (1) {
      at = index(rest, "[");
      if (at == 0) return 0;
      gstart = pos + at;
      rest = substr(rest, at + 1);
      pos = gstart;
      end = index(rest, "]");
      if (end == 0) { body = rest; rest = ""; pos += length(body) }
      else { body = substr(rest, 1, end - 1); rest = substr(rest, end + 1); pos += end }
      if (slot > 0 && gstart == slot) {
        if (index(body, "[") > 0) return 1;
      } else {
        k = split(body, a, " ");
        for (j=1; j<=k; j++) { if (substr(a[j], 1, 1) == "+") return 1 }
      }
      if (rest == "") return 0;
    }
  }
  function is_entry_shaped() {
    if (!is_top_level() || NF < 2 || $2 ~ /^\[/) return 0;
    if (NF == 2) return 1;
    return ((has_added_tail() && $3 == "(added") || ($3 ~ /^\[/ || $3 == "-"));
  }
  # An entry-shaped bullet with no added-date tail is a hard error rather than a
  # silent drop, because dropping it would take its +parked and +focus flags with
  # it and answer permissively (see this script header).
  function is_entry() {
    if (!is_entry_shaped()) return 0;
    if (has_added_tail()) return 1;
    printf "error: registry entry \"%s\" in %s has no \"(added <date>)\" tail: %s\n", $2, reg, $0 > "/dev/stderr";
    exit 1;
  }
  function annotation(line,   s, i, k, a, j) {
    mode="no-mistakes"; yolo="off"; focus="off"; parked="off";
    if ($3 ~ /^\[/) {
      s = annotation_body();
      k = split(s, a, " ");
      for (j=1; j<=k; j++) {
        if (a[j] == "") continue;
        if (a[j] == "+yolo") { yolo="on"; continue }
        if (a[j] == "+focus") { focus="on"; continue }
        if (a[j] == "+parked") { parked="on"; continue }
        if (substr(a[j], 1, 1) == "+") {
          printf "%s: unknown flag \"%s\" on project \"%s\" in %s; accepted flags are +yolo, +focus, +parked\n", (strict ? "error" : "warn"), a[j], $2, reg > "/dev/stderr";
          if (strict) exit 1;
          continue;
        }
        if (j == 1) mode = a[j];
      }
    }
  }
'

if [ "$LIST" -eq 1 ]; then
  [ $# -eq 0 ] || { echo "usage: fm-project-mode.sh --list" >&2; exit 2; }
  [ -f "$REG" ] || exit 0
  awk -v reg="$REG" -v strict=1 "$ANNOTATION_AWK"'
    is_indented_bullet() && (has_added_tail() || has_flag_token(1)) {
      printf "error: indented registry entry \"%s\" in %s is a misplaced project entry; a registry entry must start at column 0: %s\n", $2, reg, $0 > "/dev/stderr";
      exit 1;
    }
    is_top_level() && has_flag_token(0) {
      printf "error: registry entry \"%s\" in %s carries its \"[...]\" annotation out of place; the annotation must immediately follow the project name: %s\n", $2, reg, $0 > "/dev/stderr";
      exit 1;
    }
    is_entry() {
      if ($2 in listed) {
        printf "error: registry project \"%s\" in %s is listed more than once; a project must have exactly one entry: %s\n", $2, reg, $0 > "/dev/stderr";
        exit 1;
      }
      listed[$2] = 1;
      annotation($0);
      printf "%s\t%s\t%s\t%s\t%s\n", $2, mode, yolo, focus, parked;
    }
  ' "$REG"
  exit 0
fi

NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" -v reg="$REG" -v strict=1 "$ANNOTATION_AWK"'
  $1=="-" && $2==n { annotation($0); print mode, yolo; exit }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
