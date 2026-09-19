#!/usr/bin/env bash
# fm-attention-lib.sh - the single owner of the captain-attention classification
# and of the portfolio attention limit.
#
# The captain can hold at most a bounded number of projects at once, so the fleet
# enforces a portfolio limit rather than trusting intake memory: ONE focus
# project, and a bounded number of projects actively consuming captain attention
# at the same time. That bound defaults to three and is configurable through
# config/attention-limit (see CONFIGURATION below).
#
# CONFIGURATION. The limit lives in an explicit, validated file so that changing
# it is a deliberate, auditable act. It is deliberately NOT an environment
# variable: an ambient value is the silent, forgotten relaxation this limit
# exists to prevent, which is why an earlier environment knob was removed.
#
#   absent            the built-in default of three applies.
#   a positive integer  that many projects may consume captain attention.
#   off               enforcement is disabled; every surface says so, and the
#                     intake check admits without refusing.
#
# Anything else - an empty file, a zero or negative value, extra lines, a
# symlink, a hardlink, a non-regular file, an unreadable file - is a LOUD
# failure, never a silent fall back to the default and never a silent disable.
# A rejected file takes the same unavailable path as an unreadable registry: the
# presentation surfaces say the classification is unavailable and why, and the
# intake gate warns loudly while letting the dispatch through, exactly as it
# does for any other uncomputable classification (see LIMIT below for why that
# direction is right for this particular bound).
#
# Disabling enforcement is a configuration choice, not an override: the
# per-dispatch override below stays a current explicit captain instruction that
# carries ONE admission, and a parked project stays parked either way.
#
# CLASSIFICATION. Every registered project, plus every project a live task or
# backlog record names, lands in exactly one class. The class is derived from
# DURABLE work and decision records only - never from what a session remembers:
#
#   parked   the registry annotates it "+parked". Deliberately quiet until the
#            captain reopens it. Never counts, whatever its records say.
#   focus    the registry annotates it "+focus". The captain's single focus
#            project, shown as its own class so the captain always sees which
#            one it is. The designation is STANDING while attention is EARNED,
#            so a focus project counts only while it also carries an open lane:
#            a quiet focus project consumes no slot. Exactly one project may
#            carry the flag.
#   active   at least one open captain lane (see SIGNALS). Counts.
#   quiet    registered, or worked on, with no open captain lane. Never counts.
#            This is where autonomous worker execution lives: a crewmate
#            shipping a yolo task creates no captain decision lane, so its
#            project stays quiet.
#
# COUNTS is therefore one rule across the classes: a project counts while it is
# not parked and at least one signal names it.
#
# Parking exempts a project from the COUNT and from the singular focus POINTER,
# never from the diagnostics. A project annotated both "+parked" and "+focus"
# classifies as parked, counts nothing, and is not the project the surfaces name
# as the focus, because naming a parked project as the focus would point the
# captain at work he has deliberately shelved. It still shows its "focus
# designation" tag, and it still takes part in the single-focus conflict check,
# which reads the RAW "+focus" set: a focus designation that disappeared behind
# a parking annotation would be a captain decision silently voided, and the
# conflict would surface only later, when the captain reopened the project.
# So the pointer reads the UNPARKED "+focus" set and is absent when every
# "+focus" entry is parked, while the conflict reads the raw set.
#
# SIGNALS. A project is attention-active when any of these durable records
# names it. Each contributes a reason string to the project's reasons field, so
# a refusal can say what is holding the slot. These five are the only entries
# that hold a slot; the reasons field also carries the standing tag
# "focus designation" on the +focus project, which names what the project is
# rather than a lane, and never counts:
#
#   captain-hold:<id>   a backlog task held for the captain and actionable now
#                       (bin/fm-fleet-snapshot.sh owns captain_actionable).
#   open-decision:<id>  a task of that project with a still-open keyed decision
#                       or blocker (fm-classify-lib.sh's durable fold). A steer
#                       that answered one closes it with its resolved line, so a
#                       finished exchange stops counting on its own.
#   review-gate:<id>    a ship task of that project whose PR or landing waits on
#                       the captain's merge word (a recorded PR with yolo off).
#   merge-lane:<id>     a ship task of that project running with yolo off and no
#                       PR recorded yet. Its merge is a guaranteed future captain
#                       decision, so the lane opens at dispatch rather than when
#                       the PR appears.
#   scout-lane:<id>     a scout task of that project. A scout is admitted at
#                       intake precisely because its report lands on the
#                       captain's desk, and that report reliably becomes a
#                       captain decision, so the lane opens at dispatch by the
#                       same rule as the ship's merge lane.
#
# A signal is read from the DURABLE record alone, with no current-state probe, so
# a lane closes when its own record closes: a decision when its resolved line
# lands, a ship lane when the task record is torn down. This deliberately
# diverges from bin/fm-fleet-snapshot.sh, which clears the decision fold for a
# TERMINAL done/failed single-owner task. An unresolved needs-decision is live
# captain attention by definition, and reusing that clearing here would
# reintroduce the per-task current-state probe the portfolio read skips.
#
# A secondmate is not a work item and its home is not a project: kind=secondmate
# records are excluded from every signal and from the project set.
#
# LIMIT. The counted set is the unparked projects a signal names, whatever their
# class, so a quiet focus project is not in it. Starting newly
# attention-consuming work on an uncounted project when the counted set is
# already at the limit is refused: the captain finishes or explicitly parks one
# of the projects already holding a slot first. The only way past a refusal is a
# current explicit captain instruction, carried as the caller's override flag.
# There is deliberately no standing knob for admission past a refusal: the
# configuration above sets the limit itself, and disabling it is a visible
# choice every surface discloses, not a silent override.
#
# The override admits ONE dispatch and never unparks a project, because parking
# is a captain decision an admission must not silently undo. A parked project
# that receives an overridden dispatch keeps class parked and stays uncounted;
# its lanes start counting only once the captain reopens it by removing the
# +parked annotation, which the project-management skill owns.
#
# A project row also carries mode_recognized: whether the registered mode is one
# bin/fm-project-mode.sh, which owns that vocabulary, actually resolves. The mode
# field itself stays the registry's own word, so a human surface can show what
# the captain wrote AND that an unrecognized mode makes a consumer fall back to
# no-mistakes off, resetting the yolo posture along with the mode.
#
# Consumers: bin/fm-attention.sh (status and the intake check),
# bin/fm-fleet-snapshot.sh (the portfolio block every presentation surface
# renders), and bin/fm-spawn.sh (intake enforcement).

# The built-in default, used when config/attention-limit is absent.
FM_ATTENTION_PORTFOLIO_LIMIT=3

# The configuration file, relative to a home's config/ directory.
FM_ATTENTION_LIMIT_FILE=attention-limit

# Set by fm_attention_limit_valid on rejection, so a caller can name the concrete
# reason rather than reporting a generic failure. Read by consumers of this
# library (bin/fm-fleet-snapshot.sh), not within it.
# shellcheck disable=SC2034  # consumed by sourcing scripts
FM_ATTENTION_LIMIT_ERROR=

# Set by fm_attention_limit_valid on success, and read the same way.
# shellcheck disable=SC2034  # consumed by sourcing scripts
FM_ATTENTION_LIMIT_VALUE=

_fm_attention_limit_fail() {
  FM_ATTENTION_LIMIT_ERROR=$1
  return 1
}

_fm_attention_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

# fm_attention_limit_valid <config-dir>
# Resolves the effective limit into FM_ATTENTION_LIMIT_VALUE: a positive
# integer, or "off" when enforcement is disabled. An ABSENT file yields the
# built-in default, because no configuration is a legitimate state; a file that
# EXISTS but does not validate is rejected into FM_ATTENTION_LIMIT_ERROR,
# because a captain who wrote a value deserves to be told it was not honored
# rather than to have it quietly replaced by the default.
#
# This sets variables instead of printing so a caller can read the rejection
# reason. A caller that captures a PRINTING form in a command substitution runs
# it in a subshell and loses the reason, and would then report a bad limit as a
# registry fault, so every caller reads FM_ATTENTION_LIMIT_VALUE and
# FM_ATTENTION_LIMIT_ERROR at top level instead.
fm_attention_limit_valid() {  # <config-dir>
  local config_dir=$1 path links value
  FM_ATTENTION_LIMIT_VALUE=
  # shellcheck disable=SC2034  # read by sourcing scripts after a rejection
  FM_ATTENTION_LIMIT_ERROR=
  if [ -L "$config_dir" ]; then
    _fm_attention_limit_fail "config directory is symlinked"
    return 1
  fi
  path="$config_dir/$FM_ATTENTION_LIMIT_FILE"
  if [ -L "$path" ]; then
    _fm_attention_limit_fail "config/$FM_ATTENTION_LIMIT_FILE is symlinked"
    return 1
  fi
  if [ ! -e "$path" ]; then
    FM_ATTENTION_LIMIT_VALUE=$FM_ATTENTION_PORTFOLIO_LIMIT
    return 0
  fi
  if [ ! -f "$path" ]; then
    _fm_attention_limit_fail "config/$FM_ATTENTION_LIMIT_FILE is not a regular file"
    return 1
  fi
  links=$(_fm_attention_link_count "$path") || {
    _fm_attention_limit_fail "config/$FM_ATTENTION_LIMIT_FILE link count could not be inspected"
    return 1
  }
  if [ "$links" != 1 ]; then
    _fm_attention_limit_fail "config/$FM_ATTENTION_LIMIT_FILE is hardlinked"
    return 1
  fi
  value=$(cat "$path" 2>/dev/null) || {
    _fm_attention_limit_fail "config/$FM_ATTENTION_LIMIT_FILE could not be read"
    return 1
  }
  if ! printf '%s\n' "$value" | cmp -s "$path" -; then
    _fm_attention_limit_fail "config/$FM_ATTENTION_LIMIT_FILE must hold exactly one value followed by one newline"
    return 1
  fi
  case "$value" in
    off)
      FM_ATTENTION_LIMIT_VALUE=off
      return 0
      ;;
    ''|0|*[!0-9]*|0*)
      _fm_attention_limit_fail "config/$FM_ATTENTION_LIMIT_FILE must be one positive integer or \"off\", not \"$value\""
      return 1
      ;;
  esac
  # shellcheck disable=SC2034  # read by sourcing scripts after a successful read
  FM_ATTENTION_LIMIT_VALUE=$value
}

# An admission that happened only because the caller carried an override is
# printed behind this prefix, so a caller announces an override where one was
# actually used and stays quiet where the work was admissible anyway.
FM_ATTENTION_OVERRIDE_PREFIX="override applied: "

# Emit the registry rows as JSON. Registry parsing itself stays owned by
# bin/fm-project-mode.sh; this only reshapes its --list output.
# A registry that is absent, a read that fails, and a row that is not the
# five-column --list contract are all FAILURES and never an empty registry: an
# empty row set would silently drop every +parked and +focus flag and answer
# permissively. Callers propagate the non-zero
# status into the classification's fail-open-with-a-warning path.
fm_attention_registry_json() {  # <fm-project-mode.sh path> <registry path>
  local mode_script=$1 registry=$2 listing
  [ -f "$registry" ] || return 1
  listing=$(FM_DATA_OVERRIDE="$(dirname "$registry")" "$mode_script" --list) || return 1
  printf '%s' "$listing" \
    | jq -R -s --arg path "$registry" '
        [ splits("\n") | select(length > 0) | split("\t") ] as $rows
        | if any($rows[]; length != 5) then
            error("registry row does not match the --list contract")
          else
            {path:$path,
             rows:[ $rows[]
                    | {name:.[0],mode:.[1],yolo:.[2],focus:(.[3] == "on"),parked:(.[4] == "on")} ]}
          end'
}

# The portfolio object. Pure jq over records the caller already collected, so
# the classification cannot drift between the snapshot and the intake check.
#   <backlog-json>   bin/fm-fleet-snapshot.sh's backlog object
#   <tasks-json>     array of {id,project,kind,yolo,pr,open_decisions:[...]}
#   <registry-json>  fm_attention_registry_json output
#   <limit>          the effective limit fm_attention_limit_valid resolved into
#                    FM_ATTENTION_LIMIT_VALUE: a positive integer, or "off" when
#                    enforcement is disabled.
#                    Omitted, it falls back to the built-in default, so a caller
#                    that has not read the configuration still gets a coherent
#                    object rather than a broken one.
fm_attention_portfolio_json() {  # <backlog-json> <tasks-json> <registry-json> [<limit>]
  local limit=${4:-$FM_ATTENTION_PORTFOLIO_LIMIT} limit_json enforced
  if [ "$limit" = off ]; then
    limit_json=null
    enforced=false
  else
    limit_json=$limit
    enforced=true
  fi
  jq -n \
    --argjson backlog "$1" \
    --argjson tasks "$2" \
    --argjson registry "$3" \
    --argjson limit "$limit_json" \
    --argjson enforced "$enforced" '
    def base_name: if . == null or . == "" then null else (split("/") | last) end;

    ($tasks
     | map(select(.kind != "secondmate"))
     | map(. + {project_name:(.project | base_name)})) as $tasks
    | [ $backlog.records[]?
        | select(.structured == true and .captain_actionable == true)
        | select((.repo // "") != "")
        | {name:(.repo | base_name), reason:"captain-hold:\(.id // "?")"} ] as $holds
    | [ $tasks[]
        | select(.project_name != null)
        | select((.open_decisions | length) > 0)
        | {name:.project_name, reason:"open-decision:\(.id)"} ] as $decisions
    | [ $tasks[]
        | select(.project_name != null)
        | select(.kind == "ship" and .yolo == "off")
        | {name:.project_name,
           reason:(if (.pr // "") != "" then "review-gate:\(.id)" else "merge-lane:\(.id)" end)} ] as $gates
    | [ $tasks[]
        | select(.project_name != null)
        | select(.kind == "scout")
        | {name:.project_name, reason:"scout-lane:\(.id)"} ] as $scouts
    | ($holds + $decisions + $gates + $scouts) as $signals
    | ([ $registry.rows[]?.name ]
       + [ $signals[].name ]
       + [ $tasks[] | select(.project_name != null) | .project_name ]
       | unique) as $names
    | [ $names[]
        | . as $name
        | ([ $registry.rows[]? | select(.name == $name) ] | first) as $row
        | ([ $signals[] | select(.name == $name) | .reason ] | unique) as $reasons
        | (($row.focus // false)) as $focus
        | (($row.parked // false)) as $parked
        | (if $parked then "parked"
           elif $focus then "focus"
           elif ($reasons | length) > 0 then "active"
           else "quiet" end) as $class
        | {name:$name,
           registered:($row != null),
           mode:($row.mode // null),
           mode_recognized:(if $row == null then null
                            else ($row.mode | IN("no-mistakes", "direct-PR", "local-only", "no-mistakes-prod-only")) end),
           yolo:($row.yolo // null),
           class:$class,
           counts:(($parked | not) and ($reasons | length) > 0),
           reasons:(if $focus then (["focus designation"] + $reasons) else $reasons end)} ]
      as $projects
    | ([ $projects[] | select(.counts) ]) as $counted
    | ([ $registry.rows[]? | select(.focus) | .name ]) as $focus_names
    | ([ $registry.rows[]? | select(.focus and (.parked | not)) | .name ]) as $unparked_focus_names
    | {schema:"fm-attention-portfolio.v1",
       available:true,
       limit:$limit,
       enforced:$enforced,
       registry:{path:$registry.path},
       focus:($unparked_focus_names | first),
       focus_conflict:(if ($focus_names | length) > 1 then $focus_names else [] end),
       counted:($counted | length),
       counted_projects:[ $counted[].name ],
       at_limit:($enforced and ($counted | length) >= $limit),
       over_limit:($enforced and ($counted | length) > $limit),
       projects:$projects}
  '
}

# True when <portfolio-json> is a portfolio object this library can classify
# against. A document that is merely present but wrong-shaped must fail the
# check rather than be read as a refusal.
# Enforcement is disabled only by an explicit "enforced": false, so a document
# written before the limit became configurable - a numeric limit and no
# enforced key - is read as ENFORCED rather than as a silent disable, and must
# therefore still carry a numeric limit to be classifiable.
fm_attention_portfolio_valid() {  # <portfolio-json>
  printf '%s' "$1" | jq -e '
    type == "object"
    and .schema == "fm-attention-portfolio.v1"
    and (.enforced == null or (.enforced | type) == "boolean")
    and (if .enforced == false then .limit == null else (.limit | type) == "number" end)
    and (.counted | type) == "number"
    and (.projects | type) == "array"
    and (.counted_projects | type) == "array"' >/dev/null 2>&1
}

# Decide whether newly attention-consuming work may start on <project>.
# Prints a human verdict line on stdout and returns:
#   0 allowed, 3 refused, 4 the classification could not be computed.
# An admission that needed the override is prefixed with
# $FM_ATTENTION_OVERRIDE_PREFIX; a plain admission never is.
# A refusal is a decision; 4 is a failure, and the caller fails OPEN on it: the
# limit is a working-memory bound on a human, not a safety boundary.
# The caller owns whether the work it is about to start creates a captain lane
# at all; this answers only "does the portfolio have room for this project".
fm_attention_admit() {  # <portfolio-json> <project> <override 0|1>
  local portfolio=$1 project=$2 override=$3 verdict
  if ! fm_attention_portfolio_valid "$portfolio"; then
    printf 'the portfolio classification is missing or malformed, so the attention limit could not be computed\n'
    return 4
  fi
  verdict=$(printf '%s' "$portfolio" | jq -r --arg p "$project" --argjson override_raw "$override" '
    ($override_raw == 1) as $override
    | ([.projects[] | select(.name == $p)] | first) as $row
    | (.counted_projects | join(", ")) as $held
    | if ($row.class // "") == "parked" then
        (if $override then
           "allow-override\tthis dispatch on parked project \($p) is admitted on an explicit captain instruction; \($p) stays parked, and reopening it by removing +parked is a separate captain decision the project-management skill owns"
         else
           "refuse\t\($p) is parked: it stays quiet until the captain reopens it. Ask the captain to reopen \($p) before starting attention-consuming work there."
         end)
      elif ($row.counts // false) then
        "allow\t\($p) already holds one of the \(.counted) attention slots the captain is carrying"
      elif (.enforced == false) then
        "allow\tthe attention limit is disabled in config/attention-limit, so \($p) is admitted without a limit check (the captain is carrying \(.counted) projects)"
      elif (.counted < .limit) then
        "allow\t\($p) takes attention slot \(.counted + 1) of \(.limit)"
      elif $override then
        "allow-override\tattention limit of \(.limit) exceeded for \($p) on an explicit captain instruction (currently: \($held))"
      else
        "refuse\tthe captain is already carrying \(.counted) projects against the attention limit of \(.limit) (\($held)); starting \($p) would make it \(.counted + 1). Ask the captain to finish or explicitly park one of those first."
      end') || {
    printf 'the portfolio classification could not be computed\n'
    return 4
  }
  case "$verdict" in
    allow-override*) printf '%s\n' "$FM_ATTENTION_OVERRIDE_PREFIX${verdict#*$'\t'}" ;;
    *) printf '%s\n' "${verdict#*$'\t'}" ;;
  esac
  case "$verdict" in
    allow*) return 0 ;;
    refuse*) return 3 ;;
    *) printf 'the portfolio classification produced no verdict\n'; return 4 ;;
  esac
}
