#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Default usage prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
# --branch-prefix instead prints one value: the project's registered ship-branch
# prefix, "fm/" when the project registers none, is unregistered, or the registry
# is absent, so every existing installation keeps its current "fm/<task-id>"
# branch names unchanged.
# With --forge it prints one word instead: the project's registered forge,
# none|gerrit. The forge is asked for explicitly, so the default output stays
# the same two words for every project, bound or not.
#
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode,
# yolo, and ship-branch prefix are resolved by firstmate at intake and passed
# explicitly to bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md
# section 7; bin/fm-brief.sh's own header owns the --branch-prefix flag it accepts).
# The single-project read's consumers are bin/fm-fleet-sync.sh (skip local-only
# clones), bin/fm-home-seed.sh and bin/fm-remote-home-seed.sh (refuse local-only
# seeding, run no-mistakes init), bin/fm-spawn.sh's registry-deviation check,
# bin/fm-send.sh's validation-trigger posture check, and --forge for
# bin/fm-spawn.sh's forge agreement and yolo refusal and for bin/fm-promote.sh,
# which takes the forge binding from here because it is a project fact rather
# than a task choice. Every one of them fails closed on a non-zero read - a
# guard that cannot read its posture refuses, never guesses - so a mistyped
# annotation surfaces as a refusal naming the file, the annotation, and the
# caller, never as a silently disabled guard.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                                 -> no-mistakes off fm/  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)                        -> <mode> off fm/
#   - <name> [<mode> +yolo] - <desc> (added <date>)                  -> <mode> on fm/
#   - <name> [<mode> +yolo branch=<prefix>] - <desc> (added <date>)  -> <mode> <yolo> <prefix>
#   - <name> [<mode> forge=gerrit] - <desc> (added <date>)           -> <mode> off, --forge gerrit
#   - <name> (added <date>)                                          -> no-mistakes off fm/
#   <name> may contain spaces; it ends at the literal " [" or " - " that follows it.
#   Bracket tokens are order-independent: +yolo, +focus, +parked, branch=<prefix>,
#   and forge=<value> are recognized by their own shape wherever they appear, and
#   whichever token is left over is the mode. <prefix> must not contain a space;
#   an empty override ("branch=") resolves to "" for a bare "<task-id>" ship
#   branch instead of the legacy "fm/<task-id>".
#
# The "(added <date>)" tail is REQUIRED on every entry, and <date> must be a real
# YYYY-MM-DD date so that prose ending in some other "(added ...)" parenthetical
# is not mistaken for an entry. Further clauses may follow the date, as in
# "(added 2026-08-14; renamed 2026-08-20)". The " - <desc>" separator is
# optional, so "- delta [+parked] (added 2026-01-02)" lists like any other entry.
#
# --list resolves a bullet's name the same way the single-project read does: the
# text up to the first " [" or " - ", or the first word when neither follows.
# A single-word name is ENTRY-SHAPED when EITHER nothing follows that name OR
# the added-date tail is the WHOLE remainder after it OR a "[...]" annotation or
# the " - " description separator follows it. A multi-word name is entry-shaped
# only when the bullet carries the added-date tail, so a prose note such as
# "- Delivery modes - see the docs" or "- Toolchains are [C++] and Rust." stays
# prose rather than becoming a dateless-entry error; such a prose bullet has no
# parsed slot, so a "+" group inside it is still refused as misplaced.
# The date alternative is what lets a bare "- alpha (added 2026-01-01)" list, and
# it is whole-remainder so that a note like "- alpha moved off the old host
# (added 2026-05-01)" stays prose instead of listing as a second alpha row. The
# other two are what make an entry-shaped bullet that lacks the tail a hard error
# naming the line, after which the portfolio classification takes its
# unavailable path. A name-only "- alpha" is such a bullet rather than prose,
# because it is far more plausibly a half-written entry, and because that keeps
# the required added-date tail required without exception. The cost is accepted
# deliberately: a prose bullet of exactly two words, such as "- Ideas", also
# fails. The registry is firstmate-maintained, the failure names the line, and
# the correction is trivial, so a loud fixable error beats quietly ignoring a
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
# where it BEGINS - the character position right after the resolved name - not
# by being the first group on the line, so an earlier glued group as in
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
# The single-project delivery-posture read matches the WHOLE registered name on
# the raw line text (never a regex, so a name containing dots or brackets is
# compared literally): the bullet's text must start with the name, and the text
# right after it must be empty, a "[...]" annotation, the " - " separator, or the
# added-date tail, so a name that is a leading prefix of a longer registered
# name does not match that longer row. It stays permissive about the bullet
# itself: indented or not, and with no added-date requirement, so both a
# dateless "- alpha [local-only] - x" and an indented one still resolve to
# local-only. The column-0 rule above is a --list rule only, and the
# dateless-entry hard error stays a --list error: the single-project read needs
# no added-date tail to answer. Matching is permissive so a line it recognizes
# still answers; what it is never permissive about is an annotation it cannot
# trust, which exits non-zero for its callers to refuse on.
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
# branch=<prefix> (orthogonal) = overrides the "fm/" ship-branch prefix so a
#   project's branch and PR do not read as firstmate-authored, e.g. for a
#   third-party repo that does not use this tooling. Query it with
#   --branch-prefix; it never appears in the default "<mode> <yolo>" output, so
#   existing mechanical callers are unaffected by its presence.
# forge (orthogonal, and orthogonal to yolo too) = which forge the project's
#   remote actually is, never inferred from mode, remote name, host, or protocol.
#   `none` means a forge whose pull requests and checks no-mistakes already
#   drives, and `gerrit` means a Gerrit server: no pull requests, so the worker
#   publishes a change with gerrit-axi instead (bin/fm-dod-lib.sh owns what that
#   changes for a worker in each publishing mode).
#   The binding is EXPLICIT because a provider family must never be guessed;
#   bin/fm-forge-detect.sh proposes it from a protocol fact at project-add
#   intake, and the captain's confirmation is what this record holds.
#   A forge describes what a mode publishes, so it composes with no-mistakes and
#   direct-PR and is REFUSED on local-only, which publishes nothing: that mode
#   lands by fast-forwarding local main, which on a review-server project
#   advances it with content the server has never seen
#   (docs/gerrit-forge-integration.md section 3).
#
# A registered `forge=gerrit` project reports yolo=off with an explicit stderr
# refusal, on the captain's decision of 2026-09-15: a Gerrit Code-Review+2 is a
# positive attributed claim that a named human approved, read by colleagues and
# by any audit, and firstmate must not manufacture one.
#
# --list prints one TAB-separated row per registered project:
#   <name>\t<raw-mode>\t<yolo on|off>\t<focus on|off>\t<parked on|off>
# It is the machine surface for portfolio consumers and takes no project name.
#
# --raw prints the registered mode annotation unmapped, so a caller that must
# tell a conditional policy apart from a flat mode sees "no-mistakes-prod-only"
# itself. Not combined with --branch-prefix, which has no conditional-policy leg.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" (or
# "fm/" under --branch-prefix) and warns to stderr, so a typo never silently
# drops the gate. Other annotation tokens are ignored, as they always were, keyed
# ones included: a `<key>=<value>` token whose key is neither exactly `forge` nor
# `branch` resolves as it did before the forge existed, and in the mode slot it
# is read as an unknown mode. A key one or two edits from `forge` (such as
# `forg=` or `Forge=`) is still ignored, with one stderr warning naming the token
# and the forge=gerrit spelling. A malformed forge binding - a `forge=` token
# whose value is empty or outside the closed set - is REFUSED in the default and
# --forge output forms: nothing on stdout, exit status 3, the token named.
# Resolving it to "no registered forge" would hand a Gerrit project the
# pull-request contract the binding exists to prevent. local-only with a forge
# is refused the same way. --branch-prefix does not make that check: it answers
# only the registered prefix, and a prefix is orthogonal to the forge binding,
# so it prints even when the forge token is malformed; every path that reads the
# forge binding (default, --forge, and spawn's forge-agreement check) still
# refuses.
#
# +yolo, +focus, and +parked are the accepted flags. An unrecognized "+" token
# fails hard on EVERY surface (exit 1, nothing on stdout), naming the project,
# the token, and the registry file. --list feeds the portfolio classification,
# which then takes its unavailable path rather than reading a mistyped "+parkd"
# as an unparked project and silently voiding the captain's parking decision.
# The single-project read exits non-zero for the same reason: its
# delivery-posture callers refuse the operation on that non-zero exit, so a
# mistyped annotation can never silently void the local-only guard by answering
# with a guessed posture. A legacy entry with no bracket keeps its existing
# meaning.
#
# Usage: fm-project-mode.sh [--raw|--branch-prefix|--forge] <project-name>
#        fm-project-mode.sh --list
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
LIST=0
BRANCH_PREFIX_QUERY=0
WANT_FORGE=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --list) LIST=1; shift ;;
  --branch-prefix) BRANCH_PREFIX_QUERY=1; shift ;;
  --forge) WANT_FORGE=1; shift ;;
esac

# Shared awk program: resolve a bullet's name and split its registry annotation
# into mode, flags, and keyed tokens. Kept in one string so the single-project
# read and --list can never drift apart on what an annotation MEANS; they differ
# only in which bullets they recognize as an entry, which the header states as a
# rule.
# shellcheck disable=SC2016  # an awk program, not a shell expansion
ANNOTATION_AWK='
  function dist(x, y,   i, j, lx, ly, d, c, v) {
    lx = length(x); ly = length(y);
    for (i=0; i<=lx; i++) d[i,0] = i;
    for (j=0; j<=ly; j++) d[0,j] = j;
    for (i=1; i<=lx; i++) for (j=1; j<=ly; j++) {
      c = (substr(x,i,1) == substr(y,j,1)) ? 0 : 1;
      v = d[i-1,j] + 1;
      if (d[i,j-1] + 1 < v) v = d[i,j-1] + 1;
      if (d[i-1,j-1] + c < v) v = d[i-1,j-1] + c;
      d[i,j] = v;
    }
    return d[lx,ly];
  }
  function has_added_tail() {
    return ($0 ~ /\(added[[:space:]]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][^)]*\)[[:space:]]*$/);
  }
  function is_top_level() {
    return ($0 ~ /^-[[:space:]]/);
  }
  function is_indented_bullet() {
    return ($0 ~ /^[[:space:]]+-[[:space:]]/ && NF >= 2);
  }
  # Sets NM (the bullet name: text up to the first " [" or " - ", else the first
  # word), AFTER (the raw text after NM), and LEAD (characters before the name).
  function split_name(   body, p1, p2, p) {
    body = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", body);
    LEAD = length($0) - length(body);
    p1 = index(body, " ["); p2 = index(body, " - ");
    p = p1; if (p2 && (!p || p2 < p)) p = p2;
    if (p) { NM = substr(body, 1, p - 1); sub(/[[:space:]]+$/, "", NM) }
    else { NM = body; sub(/[[:space:]].*/, "", NM) }
    AFTER = substr(body, length(NM) + 1);
  }
  # Character position in $0 of the parsed annotation slot "[", or 0.
  function slot_start() {
    split_name();
    if (AFTER !~ /^[[:space:]]+\[/) return 0;
    if (index(NM, " ") > 0 && !has_added_tail()) return 0;
    return LEAD + length(NM) + index(AFTER, "[");
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
  function is_entry_shaped(   first) {
    if (!is_top_level() || NF < 2 || $2 ~ /^\[/) return 0;
    split_name();
    if (index(NM, " ") > 0) return has_added_tail();
    if (NF == 2) return 1;
    first = AFTER; sub(/^[[:space:]]+/, "", first); sub(/[[:space:]].*/, "", first);
    return ((has_added_tail() && first == "(added") || first ~ /^\[/ || first == "-");
  }
  # An entry-shaped bullet with no added-date tail is a hard error rather than a
  # silent drop, because dropping it would take its +parked and +focus flags with
  # it and answer permissively (see this script header).
  function is_entry() {
    if (!is_entry_shaped()) return 0;
    if (has_added_tail()) return 1;
    printf "error: registry entry \"%s\" in %s has no \"(added <date>)\" tail: %s\n", NM, reg, $0 > "/dev/stderr";
    exit 1;
  }
  # Parse the annotation that opens <after> (the text right after the name).
  # Tokens are order-independent: +yolo, +focus, +parked, branch=<prefix>, and
  # forge=<value> are recognized by their own shape wherever they appear, an
  # unknown "+" token is a hard error, keyed tokens that are neither are ignored
  # (recording a near miss of the forge key in NEAR/nnear), and the first token
  # left over is the mode.
  function annotation(name, after,   s, nk, rest, i, k, a, j, key, e, mode_set) {
    mode="no-mistakes"; yolo="off"; focus="off"; parked="off"; branch="fm/"; forge="none"; nnear=0;
    if (after !~ /^[[:space:]]+\[/) return;
    s="";
    nk = split(after, rest, " ");
    for (i=1; i<=nk; i++) { s = s (s==""?"":" ") rest[i]; if (rest[i] ~ /\]$/) break }
    gsub(/^\[|\]$/, "", s);
    k = split(s, a, " ");
    mode_set = 0;
    for (j=1; j<=k; j++) {
      if (a[j] == "") continue;
      if (a[j] == "+yolo") { yolo="on"; continue }
      if (a[j] == "+focus") { focus="on"; continue }
      if (a[j] == "+parked") { parked="on"; continue }
      if (substr(a[j], 1, 1) == "+") {
        printf "error: unknown flag \"%s\" on project \"%s\" in %s; accepted flags are +yolo, +focus, +parked\n", a[j], name, reg > "/dev/stderr";
        exit 1;
      }
      if (a[j] ~ /^branch=/) { branch = substr(a[j], 8); continue }
      if (a[j] ~ /^forge=/) { forge = a[j]; continue }
      if (a[j] ~ /^[^=]+=/) {
        key = substr(a[j], 1, index(a[j], "=") - 1);
        e = dist(key, "forge");
        if (e >= 1 && e <= 2) NEAR[++nnear] = a[j];
        if (mode_set == 0) { mode = a[j]; mode_set = 1 }
        continue
      }
      if (mode_set == 0) { mode = a[j]; mode_set = 1 }
    }
  }
'

if [ "$LIST" -eq 1 ]; then
  [ $# -eq 0 ] || { echo "usage: fm-project-mode.sh --list" >&2; exit 2; }
  [ -f "$REG" ] || exit 0
  awk -v reg="$REG" "$ANNOTATION_AWK"'
    is_indented_bullet() && (has_added_tail() || has_flag_token(1)) {
      split_name();
      printf "error: indented registry entry \"%s\" in %s is a misplaced project entry; a registry entry must start at column 0: %s\n", NM, reg, $0 > "/dev/stderr";
      exit 1;
    }
    is_top_level() && has_flag_token(0) {
      printf "error: registry entry \"%s\" in %s carries its \"[...]\" annotation out of place; the annotation must immediately follow the project name: %s\n", NM, reg, $0 > "/dev/stderr";
      exit 1;
    }
    is_entry() {
      if (NM in listed) {
        printf "error: registry project \"%s\" in %s is listed more than once; a project must have exactly one entry: %s\n", NM, reg, $0 > "/dev/stderr";
        exit 1;
      }
      listed[NM] = 1;
      annotation(NM, AFTER);
      printf "%s\t%s\t%s\t%s\t%s\n", NM, mode, yolo, focus, parked;
    }
  ' "$REG"
  exit 0
fi

NAME=${1:?usage: fm-project-mode.sh [--raw|--branch-prefix|--forge] <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "fm/"
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none; else echo "no-mistakes off"; fi
  exit 0
fi

# awk emits one "near <token>" line per keyed token whose key is a near miss of
# `forge`, then "posture <mode> <yolo> <forge> <branch-prefix>" (branch-prefix is
# the raw prefix, defaulting to "fm/"; forge is `none` or the whole `forge=<value>`
# token, so an empty value survives the split), or nothing if the project is
# absent. It exits non-zero, printing nothing, on an unknown "+" flag.
parsed=$(awk -v n="$NAME" -v reg="$REG" "$ANNOTATION_AWK"'
  {
    # Whole-name match on the raw text after the bullet dash (see the header).
    if ($0 !~ /^[[:space:]]*-[[:space:]]/) next
    body = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", body);
    if (substr(body, 1, length(n)) != n) next
    after = substr(body, length(n) + 1);
    if (after != "" && after !~ /^[[:space:]]+\[/ && substr(after, 1, 3) != " - " && after !~ /^[[:space:]]+\(added[[:space:]]/) next
    annotation(n, after);
    for (i=1; i<=nnear; i++) print "near", NEAR[i];
    # branch is printed LAST: an empty branch= override must survive as an
    # empty final field, which only holds when nothing follows it.
    print "posture", mode, yolo, forge, branch; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
    echo "fm/"
  elif [ "$WANT_FORGE" -eq 1 ]; then echo none; else echo "no-mistakes off"; fi
  exit 0
fi

posture=
while IFS=' ' read -r kind rest; do
  case "$kind" in
    near) echo "warn: ignoring \"$rest\" registered for $NAME in $REG; it is not a forge binding, and the forge binding is spelled forge=gerrit" >&2 ;;
    posture) posture=$rest ;;
  esac
done <<EOF
$parsed
EOF
while IFS=' ' read -r m y f b; do
  mode=$m; yolo=$y; rest_forge=$f; branch=$b
done <<EOF
$posture
EOF
forge=${rest_forge:-none}
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; branch=fm/ ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
if [ "$BRANCH_PREFIX_QUERY" -eq 1 ]; then
  echo "$branch"
  exit 0
fi

case "$forge" in
  none|forge=gerrit) forge=${forge#forge=} ;;
  forge=)
    echo "refused: empty forge binding \"forge=\" registered for $NAME in $REG; the accepted value is forge=gerrit, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
  *)
    echo "refused: unknown forge \"${forge#forge=}\" registered for $NAME in $REG; the accepted value is forge=gerrit, or no forge token at all for a forge whose pull requests no-mistakes already drives; correct the registry entry" >&2
    exit 3 ;;
esac
if [ "$forge" != none ] && [ "$mode" = local-only ]; then
  echo "refused: $NAME is registered local-only with forge=$forge in $REG; local-only publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; register no-mistakes or direct-PR to publish through the forge, or drop the forge token to keep the project local" >&2
  exit 3
fi
if [ "$WANT_FORGE" -eq 1 ]; then
  echo "$forge"
  exit 0
fi
if [ "$forge" = gerrit ] && [ "$yolo" = on ]; then
  echo "refused: +yolo is registered for $NAME but yolo is inactive for forge=gerrit, so this reports yolo=off: a Gerrit Code-Review+2 is a positive attributed claim that a named human approved, and firstmate must not manufacture one (captain's decision 2026-09-15)" >&2
  yolo=off
fi
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
