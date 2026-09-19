#!/usr/bin/env bash
# tests/fm-attention.test.sh - the portfolio attention limit and the
# classification boundary it rests on.
#
# The limit exists to protect a human: the captain can hold only so many
# projects at once. It is worth pinning because every part of it is easy to get
# quietly wrong - counting a project the captain is not actually thinking about,
# failing to count one he is, or letting a fourth project in because nobody
# remembered the three already open. Each case below drives the real commands
# against durable records, never an internal function's idea of them.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ATTENTION="$ROOT/bin/fm-attention.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-attention)

command -v jq >/dev/null 2>&1 || { echo "# skip fm-attention: jq not installed"; exit 0; }

# --- fixture builders -------------------------------------------------------

make_home() {  # <name> - echoes the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

register() {  # <home> <line-body>, e.g. "alpha [no-mistakes +focus] - app (added 2026-01-01)"
  printf -- '- %s\n' "$2" >> "$1/data/projects.md"
}

queue_captain_hold() {  # <home> <id> <repo>
  local home=$1 id=$2 repo=$3 tmp="$1/data/backlog.md.tmp"
  awk -v row="- [ ] $id - decide it (repo: $repo) (kind: captain) (hold: pick one) (hold-kind: captain)" '
    { print }
    /^## Queued$/ { print ""; print row }
  ' "$home/data/backlog.md" > "$tmp" && mv "$tmp" "$home/data/backlog.md"
}

set_limit() {  # <home> <value> - write config/attention-limit verbatim plus a newline
  mkdir -p "$1/config"
  printf '%s\n' "$2" > "$1/config/attention-limit"
}

set_limit_raw() {  # <home> <exact-bytes> - write config/attention-limit with no added newline
  mkdir -p "$1/config"
  printf '%s' "$2" > "$1/config/attention-limit"
}

queue_row() {  # <home> <id> - a plain dispatchable queued item
  local home=$1 id=$2 tmp="$1/data/backlog.md.tmp"
  awk -v row="- [ ] $id - ship it (kind: ship)" '
    { print }
    /^## Queued$/ { print ""; print row }
  ' "$home/data/backlog.md" > "$tmp" && mv "$tmp" "$home/data/backlog.md"
}

task() {  # <home> <id> <project> [key=value...]
  local home=$1 id=$2 project=$3
  shift 3
  {
    printf 'kind=ship\n'
    printf 'project=%s/projects/%s\n' "$home" "$project"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$home/state/$id.meta"
  : > "$home/state/$id.status"
}

status_line() {  # <home> <id> <line>
  printf '%s\n' "$3" >> "$1/state/$2.status"
}

run_attention() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$ATTENTION" "$@" 2>&1
}

run_in_home() {  # <home> <command> [args...]
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$@" 2>&1
}

run_in_home_quiet() {  # <home> <command> [args...] - stdout only
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$@" 2>/dev/null
}

class_of() {  # <home> <project>
  run_attention "$1" status --json | jq -r --arg p "$2" '
    ([.projects[] | select(.name == $p)] | first | .class) // "absent"'
}

# --- the classification boundary -------------------------------------------

test_registered_quiet_projects_do_not_consume_attention() {
  local home
  home=$(make_home quiet)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta [direct-PR] - tool (added 2026-01-02)'

  [ "$(class_of "$home" alpha)" = quiet ] || fail "a registered project with no open captain lane should be quiet"
  [ "$(class_of "$home" beta)" = quiet ] || fail "delivery posture alone should not make a project attention-active"
  assert_contains "$(run_attention "$home" status)" "attention: 0/3" "a quiet portfolio should consume no attention"
  pass "registration alone never consumes captain attention"
}

test_each_durable_captain_lane_makes_a_project_active() {
  local home out
  home=$(make_home lanes)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'

  # 1: a backlog task held for the captain and due now.
  queue_captain_hold "$home" hold-1 alpha
  # 2: a worker's still-open keyed decision.
  task "$home" dec-1 beta yolo=on
  status_line "$home" dec-1 'needs-decision: [key=shape] one or two?'
  # 3: a PR whose merge the captain must approve.
  task "$home" pr-1 gamma yolo=off pr=https://example.test/org/gamma/pull/7

  [ "$(class_of "$home" alpha)" = active ] || fail "an actionable captain hold should make its project attention-active"
  [ "$(class_of "$home" beta)" = active ] || fail "an open keyed decision should make its project attention-active"
  [ "$(class_of "$home" gamma)" = active ] || fail "a PR waiting on the captain's merge word should make its project attention-active"

  out=$(run_attention "$home" status)
  assert_contains "$out" "captain-hold:hold-1" "the classification should say which record holds the slot"
  assert_contains "$out" "open-decision:dec-1" "an open decision should be named as the reason"
  assert_contains "$out" "review-gate:pr-1" "a waiting merge decision should be named as the reason"
  assert_contains "$out" "attention: 3/3" "three open captain lanes should fill the portfolio"
  pass "each durable captain lane - hold, open decision, waiting merge - counts, and says why"
}

test_answered_decision_releases_the_slot() {
  local home
  home=$(make_home answered)
  register "$home" 'alpha - app (added 2026-01-01)'
  task "$home" dec-2 alpha yolo=on
  status_line "$home" dec-2 'needs-decision: [key=shape] one or two?'
  [ "$(class_of "$home" alpha)" = active ] || fail "an open decision should hold the slot"

  status_line "$home" dec-2 'resolved: [key=shape] captain picked one'
  [ "$(class_of "$home" alpha)" = quiet ] || fail "an answered decision should release the attention slot"
  pass "a closed decision releases the project's attention slot"
}

test_autonomous_execution_creates_no_attention_lane() {
  local home
  home=$(make_home autonomous)
  register "$home" 'alpha [no-mistakes +yolo] - app (added 2026-01-01)'
  # A worker under way with a PR firstmate may merge itself: no captain lane.
  task "$home" auto-1 alpha yolo=on pr=https://example.test/org/alpha/pull/9
  status_line "$home" auto-1 'working: implementing'

  [ "$(class_of "$home" alpha)" = quiet ] || fail "autonomous execution must not consume captain attention"
  pass "a worker shipping without a captain decision lane leaves its project quiet"
}

test_parked_projects_stay_quiet_and_uncounted() {
  local home out
  home=$(make_home parked)
  register "$home" 'alpha [+parked] - shelved (added 2026-01-01)'
  # Even with records that would otherwise count, parked stays out.
  queue_captain_hold "$home" hold-p alpha
  task "$home" pr-p alpha yolo=off pr=https://example.test/org/alpha/pull/1

  [ "$(class_of "$home" alpha)" = parked ] || fail "a +parked project should classify as parked"
  out=$(run_attention "$home" status)
  assert_contains "$out" "attention: 0/3" "a parked project must not consume an attention slot"
  pass "a parked project stays quiet and uncounted until it is reopened"
}

test_focus_is_shown_but_counts_only_while_it_carries_a_lane() {
  local home out status held
  home=$(make_home focus)
  register "$home" 'alpha [no-mistakes +focus] - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'

  [ "$(class_of "$home" alpha)" = focus ] || fail "the +focus project should classify as focus"
  out=$(run_attention "$home" status)
  assert_contains "$out" "focus: alpha" "status should name the focus project"
  assert_contains "$out" "attention: 0/3" "a quiet focus project should consume no attention slot"
  assert_contains "$out" "focus designation" "the focus tag should read as a designation, not a slot-holding lane"
  out=$(run_attention "$home" check gamma); status=$?
  expect_code 0 "$status" "a quiet focus project should leave every slot free"
  assert_contains "$out" "slot 1 of 3" "a quiet focus project should not have taken a slot"

  # An open lane on the focus project counts it - exactly once.
  queue_captain_hold "$home" hold-f alpha
  out=$(run_attention "$home" status)
  [ "$(class_of "$home" alpha)" = focus ] || fail "an open lane should not change the focus class"
  assert_contains "$out" "attention: 1/3" "a focus project with an open lane should occupy a slot"
  held=$(run_attention "$home" status --json | jq -r '[.counted_projects[] | select(. == "alpha")] | length')
  [ "$held" = 1 ] || fail "the focus project should be counted exactly once, got $held"

  register "$home" 'beta2 [+focus] - second focus (added 2026-01-03)'
  out=$(run_attention "$home" status)
  assert_contains "$out" "conflict:" "two +focus projects should be reported as a conflict"
  pass "focus is shown as its own class, counts only while a lane is open, and a second one is a conflict"
}

test_unregistered_worked_on_projects_are_classified_too() {
  local home
  home=$(make_home unregistered)
  register "$home" 'alpha - app (added 2026-01-01)'
  task "$home" stray-1 orphan yolo=off pr=https://example.test/org/orphan/pull/2

  [ "$(class_of "$home" orphan)" = active ] || fail "a worked-on project missing from the registry should still be classified"
  assert_contains "$(run_attention "$home" status --json)" '"registered": false' \
    "the registry gap itself should stay visible"
  pass "a project with work but no registry entry is classified and flagged unregistered"
}

test_a_captain_approval_ship_counts_from_dispatch() {
  local home out status
  home=$(make_home merge-lanes)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  register "$home" 'delta - next (added 2026-01-04)'
  register "$home" 'epsilon [+yolo] - autonomous (added 2026-01-05)'
  # In flight, no PR yet: the captain's merge word is already promised.
  task "$home" lane-a alpha yolo=off
  task "$home" lane-b beta yolo=off
  task "$home" lane-c gamma yolo=off
  # Autonomous execution still opens no lane.
  task "$home" auto-e epsilon yolo=on

  [ "$(class_of "$home" alpha)" = active ] || fail "an in-flight captain-approval ship should make its project attention-active"
  [ "$(class_of "$home" epsilon)" = quiet ] || fail "a yolo ship must leave its project quiet"

  out=$(run_attention "$home" status)
  assert_contains "$out" "merge-lane:lane-a" "the classification should name the ship holding the slot"
  assert_contains "$out" "attention: 3/3" "three in-flight captain-approval ships should fill the portfolio"

  out=$(run_attention "$home" check delta); status=$?
  expect_code 3 "$status" "a fourth captain-approval project should be refused"
  assert_contains "$out" "alpha, beta, gamma" "the refusal should name the three ships already open"
  pass "a captain-approval ship holds a slot from dispatch, and a yolo ship never does"
}

test_a_secondmate_home_consumes_no_attention_slot() {
  local home out
  home=$(make_home secondmate)
  register "$home" 'alpha - app (added 2026-01-01)'
  task "$home" sm-1 sm-home kind=secondmate yolo=off
  status_line "$home" sm-1 'needs-decision: [key=scope] which scope?'

  [ "$(class_of "$home" sm-home)" = absent ] || fail "a secondmate home is not a project and must not be classified as one"
  out=$(run_attention "$home" status)
  assert_contains "$out" "attention: 0/3" "a secondmate's open decisions must not burn a captain attention slot"
  pass "a secondmate home is never counted as an attention-consuming project"
}

test_a_scout_lane_counts_from_dispatch() {
  local home out status
  home=$(make_home scout-lanes)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  register "$home" 'delta - next (added 2026-01-04)'
  task "$home" look-a alpha kind=scout yolo=off
  task "$home" look-b beta kind=scout yolo=off
  task "$home" look-c gamma kind=scout yolo=off

  [ "$(class_of "$home" alpha)" = active ] || fail "a dispatched scout should make its project attention-active"
  out=$(run_attention "$home" status)
  assert_contains "$out" "scout-lane:look-a" "the classification should name the scout holding the slot"
  assert_contains "$out" "attention: 3/3" "three dispatched scouts should fill the portfolio"

  out=$(run_attention "$home" check delta); status=$?
  expect_code 3 "$status" "a fourth scout project should be refused"
  assert_contains "$out" "alpha, beta, gamma" "the refusal should name the three scouts already open"

  rm -f "$home/state/look-c.meta" "$home/state/look-c.status"
  out=$(run_attention "$home" check delta); status=$?
  expect_code 0 "$status" "a scout whose record is gone should release its slot"
  pass "a scout holds a slot from dispatch and releases it when its record is gone"
}

# --- the configured limit ---------------------------------------------------

# The limit was a pinned constant until the captain asked for it to be
# configurable. The constraint that came with the ask is the interesting part:
# relaxation must stay deliberate and visible, so the value lives in a validated
# file rather than an ambient variable, and a value that does not validate is
# never quietly replaced by the default.

test_an_absent_config_keeps_the_built_in_default() {
  local home
  home=$(make_home limit-absent)
  register "$home" 'alpha - app (added 2026-01-01)'
  [ ! -e "$home/config/attention-limit" ] || fail "the fixture should have no config file"
  assert_contains "$(run_attention "$home" status)" "attention: 0/3" \
    "an unconfigured home should carry the built-in default of three"
  pass "an absent config file leaves the built-in default in force"
}

test_a_configured_limit_moves_the_edge_intake_refuses_at() {
  local home out status
  home=$(make_home limit-configured)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  register "$home" 'delta - next (added 2026-01-04)'
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta

  # Two lanes open. At a limit of two the third project is refused; at the
  # default of three it is admitted, so the file is what moved the edge.
  set_limit "$home" 2
  assert_contains "$(run_attention "$home" status)" "attention: 2/2" \
    "status should report the configured limit"
  out=$(run_attention "$home" check gamma); status=$?
  expect_code 3 "$status" "a configured limit of two should refuse the third project"
  assert_contains "$out" "attention limit of 2" "the refusal should name the configured limit"

  set_limit "$home" 4
  out=$(run_attention "$home" check gamma); status=$?
  expect_code 0 "$status" "raising the configured limit should admit the third project"
  assert_contains "$out" "slot 3 of 4" "the admission should count against the configured limit"
  pass "the configured value, not a constant, decides where intake refuses"
}

test_a_disabled_limit_admits_without_refusing_and_says_so_everywhere() {
  local home out status
  home=$(make_home limit-off)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  register "$home" 'delta - next (added 2026-01-04)'
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta
  queue_captain_hold "$home" hold-c gamma
  set_limit "$home" off

  out=$(run_attention "$home" check delta); status=$?
  expect_code 0 "$status" "a disabled limit should admit a fourth attention project"
  assert_contains "$out" "disabled in config/attention-limit" \
    "the admission should say the limit is disabled rather than pretending it passed a check"

  # Disabled is never silent: every surface the captain reads says so.
  out=$(run_attention "$home" status)
  assert_contains "$out" "limit is disabled in config/attention-limit" \
    "status should disclose that enforcement is off"
  assert_not_contains "$out" "at limit" "a disabled limit cannot be at its limit"
  out=$(run_in_home "$home" "$ROOT/bin/fm-fleet-view.sh")
  assert_contains "$out" "limit is disabled in config/attention-limit" \
    "the fleet view should disclose that enforcement is off"
  pass "a disabled limit admits without refusing, and every surface discloses it"
}

test_a_disabled_limit_still_leaves_a_parked_project_parked() {
  local home out status
  home=$(make_home limit-off-parked)
  register "$home" 'alpha [+parked] - shelved (added 2026-01-01)'
  set_limit "$home" off

  out=$(run_attention "$home" check alpha); status=$?
  expect_code 3 "$status" "disabling the limit must not reopen a parked project"
  assert_contains "$out" "is parked" "the refusal should still be the parking refusal"
  pass "disabling the limit does not unpark a parked project"
}

test_an_invalid_configured_limit_fails_loudly_instead_of_defaulting() {
  local home out status value
  home=$(make_home limit-invalid)
  register "$home" 'alpha - app (added 2026-01-01)'

  # Each of these is a value a captain could plausibly write. None may be
  # silently replaced by the default, and none may silently disable the limit.
  for value in 0 -2 lots 07 'off please'; do
    set_limit "$home" "$value"
    out=$(run_attention "$home" status 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "an invalid limit \"$value\" was accepted"$'\n'"$out"
    assert_contains "$out" "config/attention-limit" \
      "the failure should name the file the captain has to fix (value: $value)"
    assert_not_contains "$out" "attention: 0/3" \
      "an invalid limit must never fall back to the built-in default (value: $value)"
  done

  # A value with no terminating newline is malformed too, not a near-miss.
  set_limit_raw "$home" 3
  out=$(run_attention "$home" status 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a value with no terminating newline was accepted"$'\n'"$out"

  # And the presentation surfaces stay readable, naming the config file rather
  # than blaming the registry, which is a different failure with a different fix.
  set_limit "$home" lots
  out=$(run_in_home_quiet "$home" "$ROOT/bin/fm-fleet-view.sh")
  assert_contains "$out" "Classification unavailable" \
    "the fleet view should degrade rather than disappear"
  assert_contains "$out" "attention limit was rejected" \
    "the fleet view should name the configured limit as the cause"
  assert_not_contains "$out" "registry data/projects.md could not be read" \
    "a bad limit must not be reported as a registry problem"
  pass "an invalid configured limit fails loudly by name and never becomes the default"
}

test_a_config_file_that_is_not_a_plain_regular_file_is_rejected() {
  local home out status
  home=$(make_home limit-file-shape)
  register "$home" 'alpha - app (added 2026-01-01)'

  # A symlinked limit file: the value the captain audits in config/ is not the
  # value that would be read, so it is refused rather than followed.
  printf '9\n' > "$home/elsewhere-limit"
  ln -s "$home/elsewhere-limit" "$home/config/attention-limit"
  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a symlinked limit file was accepted"$'\n'"$out"
  assert_contains "$out" "config/attention-limit" "the failure should name the file to fix"
  assert_not_contains "$out" "attention: 0/9" "a symlinked limit must never be honored"
  rm -f "$home/config/attention-limit"

  # A hardlinked limit file. This is the only platform-forked branch in the
  # reader, so it is driven with a real second link rather than a stub.
  printf '9\n' > "$home/config/attention-limit"
  if ln "$home/config/attention-limit" "$home/second-link" 2>/dev/null; then
    out=$(run_attention "$home" status); status=$?
    [ "$status" -ne 0 ] || fail "a hardlinked limit file was accepted"$'\n'"$out"
    assert_contains "$out" "config/attention-limit" "the failure should name the file to fix"
    assert_not_contains "$out" "attention: 0/9" "a hardlinked limit must never be honored"
    rm -f "$home/second-link"
  else
    echo "# skip fm-attention: this filesystem does not support hard links"
  fi
  rm -f "$home/config/attention-limit"

  # A non-regular file in the limit's place.
  if mkfifo "$home/config/attention-limit" 2>/dev/null; then
    out=$(run_attention "$home" status); status=$?
    [ "$status" -ne 0 ] || fail "a non-regular limit file was accepted"$'\n'"$out"
    assert_contains "$out" "config/attention-limit" "the failure should name the file to fix"
    rm -f "$home/config/attention-limit"
  else
    echo "# skip fm-attention: this filesystem does not support named pipes"
  fi

  pass "a limit file that is not a plain regular file is refused rather than read"
}

test_a_symlinked_config_directory_is_rejected() {
  local home out status
  home=$(make_home limit-config-symlink)
  register "$home" 'alpha - app (added 2026-01-01)'

  # Redirecting the whole config directory hides the limit just as effectively
  # as redirecting the file, so the directory is checked too.
  mkdir -p "$home/elsewhere-config"
  printf '9\n' > "$home/elsewhere-config/attention-limit"
  rmdir "$home/config"
  ln -s "$home/elsewhere-config" "$home/config"

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a symlinked config directory was accepted"$'\n'"$out"
  assert_contains "$out" "config directory is symlinked" "the failure should name what to fix"
  assert_not_contains "$out" "attention: 0/9" "a redirected config directory must never be honored"
  assert_not_contains "$out" "attention: 0/3" "a rejected limit must never fall back to the default"
  pass "a symlinked config directory is refused rather than followed"
}

test_an_unreadable_limit_file_fails_loudly() {
  local home out status
  home=$(make_home limit-unreadable)
  register "$home" 'alpha - app (added 2026-01-01)'
  set_limit "$home" 9

  chmod 000 "$home/config/attention-limit"
  if [ -r "$home/config/attention-limit" ]; then
    chmod 644 "$home/config/attention-limit"
    echo "# skip fm-attention: file permissions are not enforced for this user"
    return 0
  fi
  out=$(run_attention "$home" status); status=$?
  chmod 644 "$home/config/attention-limit"
  [ "$status" -ne 0 ] || fail "an unreadable limit file was accepted"$'\n'"$out"
  assert_contains "$out" "config/attention-limit" "the failure should name the file to fix"
  assert_not_contains "$out" "attention: 0/3" "an unreadable limit must never fall back to the default"
  pass "an unreadable limit file fails loudly instead of defaulting"
}

test_the_limit_is_not_configurable_through_the_environment() {
  local home out
  home=$(make_home limit-env)
  register "$home" 'alpha - app (added 2026-01-01)'

  # An ambient variable is the silent relaxation the file exists to replace, so
  # neither the old removed knob nor the library's own variable names may work.
  out=$(FM_ATTENTION_LIMIT=9 FM_ATTENTION_PORTFOLIO_LIMIT=9 run_attention "$home" status)
  assert_contains "$out" "attention: 0/3" "no environment variable may set the limit"
  pass "the limit answers to the config file alone, never to the environment"
}

# --- the limit --------------------------------------------------------------

test_fourth_attention_project_is_refused_at_the_edge() {
  local home out status
  home=$(make_home edge)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  register "$home" 'delta - next (added 2026-01-04)'
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta

  # Two open: the third is still admissible.
  out=$(run_attention "$home" check delta); status=$?
  expect_code 0 "$status" "a third attention project should be admitted"
  assert_contains "$out" "slot 3 of 3" "the third project should be named as the last free slot"

  # Three open: the fourth stops intake.
  queue_captain_hold "$home" hold-c gamma
  out=$(run_attention "$home" check delta); status=$?
  expect_code 3 "$status" "a fourth attention project should be refused"
  assert_contains "$out" "already carrying 3 projects" "the refusal should say the captain is at the limit"
  assert_contains "$out" "alpha, beta, gamma" "the refusal should name what holds the three slots"
  assert_contains "$out" "finish or explicitly park" "the refusal should say how the captain clears a slot"

  # A project already holding a slot keeps working.
  out=$(run_attention "$home" check beta); status=$?
  expect_code 0 "$status" "a project already holding a slot should not be refused"

  # Parking one of the three frees the slot again.
  register "$home" 'gamma2 - unused (added 2026-01-05)'
  sed -i.bak 's/^- gamma - lib/- gamma [+parked] - lib/' "$home/data/projects.md"
  out=$(run_attention "$home" check delta); status=$?
  expect_code 0 "$status" "parking one of the three should free a slot"
  pass "the limit admits three, refuses the fourth by name, and reopens when one is parked"
}

test_parked_project_refuses_new_work_until_reopened() {
  local home out status
  home=$(make_home parked-intake)
  register "$home" 'alpha [+parked] - shelved (added 2026-01-01)'

  out=$(run_attention "$home" check alpha); status=$?
  expect_code 3 "$status" "a parked project should refuse new attention-consuming work"
  assert_contains "$out" "is parked" "the refusal should say the project is parked"
  assert_contains "$out" "reopen" "the refusal should point at reopening it"
  pass "a parked project refuses new captain-facing work until it is reopened"
}

test_override_is_the_only_way_past_a_refusal() {
  local home out status
  home=$(make_home override)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta
  queue_captain_hold "$home" hold-c gamma

  out=$(run_attention "$home" check delta --override); status=$?
  expect_code 0 "$status" "an explicit captain instruction should carry past the refusal"
  assert_contains "$out" "explicit captain instruction" "the override should say what authorized it"

  # The relaxation is per-invocation: nothing about it persists.
  out=$(run_attention "$home" check delta); status=$?
  expect_code 3 "$status" "an override must not leave standing permission behind"

  # The captain later asked for the limit itself to be configurable, so a
  # config file DOES move it - but that is a deliberate, visible setting rather
  # than a standing override. What must never work is an ambient variable,
  # which is the silent relaxation the file replaced.
  out=$(FM_ATTENTION_LIMIT=9 FM_ATTENTION_PORTFOLIO_LIMIT=9 run_attention "$home" status)
  assert_contains "$out" "attention: 3/3" "no ambient environment variable may raise the limit"
  out=$(FM_ATTENTION_LIMIT=9 FM_ATTENTION_PORTFOLIO_LIMIT=9 run_attention "$home" check delta); status=$?
  expect_code 3 "$status" "an ambient environment variable must not carry a refusal"
  pass "only a current explicit instruction passes a refusal, and it leaves nothing standing"
}

test_an_unreadable_classification_fails_instead_of_refusing() {
  local home out status
  home=$(make_home unreadable)
  register "$home" 'alpha - app (added 2026-01-01)'

  # A foreign document that happens to carry a .portfolio key.
  printf '%s\n' '{"schema":"something-else","portfolio":{"notes":"not a classification"}}' \
    > "$home/foreign.json"
  out=$(run_attention "$home" check delta --snapshot "$home/foreign.json"); status=$?
  [ "$status" -ne 3 ] || fail "a malformed classification must never be reported as a refusal"$'\n'"$out"
  expect_code 1 "$status" "an uncomputable classification should fail so the caller can fail open"
  assert_not_contains "$out" "attention limit" "a failure must not read like a limit refusal"

  # A valid classification through the same path still decides.
  run_attention "$home" status --json > "$home/good.json"
  printf '%s\n' "$(jq -n --slurpfile p "$home/good.json" '{portfolio:$p[0]}')" > "$home/good-doc.json"
  out=$(run_attention "$home" check delta --snapshot "$home/good-doc.json"); status=$?
  expect_code 0 "$status" "a well-formed snapshot should still be classified"$'\n'"$out"
  pass "an uncomputable classification fails the check rather than refusing intake"
}

test_a_snapshot_without_an_enforced_field_is_read_as_enforced() {
  local home out status
  home=$(make_home pre-upgrade-doc)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta
  queue_captain_hold "$home" hold-c gamma

  # A document written before the limit became configurable: a numeric limit
  # and no "enforced" key at all. Read permissively it would disable the limit.
  run_attention "$home" status --json > "$home/current.json"
  jq '{portfolio:(del(.enforced))}' "$home/current.json" > "$home/pre-upgrade.json"
  [ "$(jq -r '.portfolio | has("enforced")' "$home/pre-upgrade.json")" = false ] \
    || fail "the fixture should carry no enforced key"
  [ "$(jq -r '.portfolio.limit' "$home/pre-upgrade.json")" = 3 ] \
    || fail "the fixture should carry a numeric limit"

  out=$(run_attention "$home" check delta --snapshot "$home/pre-upgrade.json"); status=$?
  expect_code 3 "$status" "a document with no enforced key must still enforce the limit"$'\n'"$out"
  assert_not_contains "$out" "disabled" "a missing enforced key must never read as a disabled limit"
  pass "a portfolio document with no enforced field is read as enforced, not disabled"
}

test_an_over_limit_refusal_reports_the_counted_set_it_names() {
  local home out status
  home=$(make_home over-limit)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  register "$home" 'delta - fourth (added 2026-01-04)'
  # The override path is how a fourth project gets in, so counted can exceed the limit.
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta
  queue_captain_hold "$home" hold-c gamma
  queue_captain_hold "$home" hold-d delta

  out=$(run_attention "$home" check epsilon); status=$?
  expect_code 3 "$status" "a fifth project should still be refused"
  assert_contains "$out" "carrying 4 projects" "the refusal should report the projects actually counted, not the limit"
  assert_contains "$out" "alpha, beta, delta, gamma" "the refusal should name every project holding a slot"
  assert_contains "$out" "would make it 5" "the refusal should say what starting another would make it"
  pass "a refusal reports the counted set it just named, even past the limit"
}

test_a_failed_registry_read_fails_instead_of_forgetting_parked_projects() {
  local home out status
  home=$(make_home registry-unreadable)
  register "$home" 'alpha [+parked] - shelved (added 2026-01-01)'
  out=$(run_attention "$home" check alpha); status=$?
  expect_code 3 "$status" "a parked project should be refused while the registry reads"

  chmod 000 "$home/data/projects.md"
  if [ -r "$home/data/projects.md" ]; then
    chmod 644 "$home/data/projects.md"
    echo "# skip fm-attention: registry permissions are not enforced for this user"
    return 0
  fi
  out=$(run_attention "$home" check alpha); status=$?
  chmod 644 "$home/data/projects.md"
  [ "$status" -ne 0 ] || fail "an unreadable registry must never quietly admit work on a parked project"$'\n'"$out"
  expect_code 1 "$status" "a registry read failure should fail the check so the caller fails open"$'\n'"$out"
  pass "a registry read failure fails loudly instead of forgetting the parked and focus flags"
}

test_an_override_says_so_only_where_it_carried_the_admission() {
  local home out status
  home=$(make_home override-wording)
  register "$home" 'alpha [+parked] - shelved (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'

  out=$(run_attention "$home" check alpha --override); status=$?
  expect_code 0 "$status" "an explicit captain instruction should admit one dispatch on a parked project"
  assert_contains "$out" "override applied:" "an admission that needed the override should say so"
  assert_contains "$out" "stays parked" "the override must not claim the project was reopened"
  assert_not_contains "$out" "reopened on" "the override must not claim the project was reopened"
  [ "$(class_of "$home" alpha)" = parked ] || fail "an overridden dispatch must not unpark the project"

  out=$(run_attention "$home" check beta --override); status=$?
  expect_code 0 "$status" "an admissible project should stay admissible"
  assert_not_contains "$out" "override applied:" "an override that was not needed must not be announced"
  pass "an override is announced only where it actually carried the admission, and never unparks"
}

# --- presentation -----------------------------------------------------------

test_portfolio_presentation_surfaces_show_the_classification() {
  local home out
  home=$(make_home presentation)
  register "$home" 'alpha [no-mistakes +focus] - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma [+parked] - shelved (added 2026-01-03)'
  queue_captain_hold "$home" hold-b beta

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    "$VIEW" 2>&1)
  assert_contains "$out" "## Portfolio" "the fleet view should present the portfolio"
  assert_contains "$out" "Captain attention: 1/3" "the fleet view should show the counted set against the limit"
  assert_contains "$out" "| alpha | focus |" "the fleet view should show the focus project's class"
  assert_contains "$out" "| beta | active |" "the fleet view should show an attention-active project"
  assert_contains "$out" "| gamma | parked |" "the fleet view should show a parked project"
  pass "the fleet view presents each project's attention classification"
}

test_the_fleet_view_shows_the_limit_even_during_a_focus_conflict() {
  local home out
  home=$(make_home conflict-at-limit)
  register "$home" 'alpha [no-mistakes +focus] - app (added 2026-01-01)'
  register "$home" 'beta [+focus] - second focus (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta
  queue_captain_hold "$home" hold-c gamma

  out=$(run_in_home "$home" "$VIEW")
  assert_contains "$out" "More than one project is flagged +focus" "the fleet view should report the focus conflict"
  assert_contains "$out" "At the attention limit" "a focus conflict must not hide the attention limit"
  pass "the fleet view reports a focus conflict and the attention limit together"
}

test_an_unreadable_registry_keeps_every_presentation_surface_readable() {
  local home out status
  home=$(make_home registry-unavailable)
  register "$home" 'alpha [+parked] - shelved (added 2026-01-01)'
  chmod 000 "$home/data/projects.md"
  if [ -r "$home/data/projects.md" ]; then
    chmod 644 "$home/data/projects.md"
    echo "# skip fm-attention: registry permissions are not enforced for this user"
    return 0
  fi

  out=$(run_in_home_quiet "$home" "$SNAPSHOT" --json); status=$?
  expect_code 0 "$status" "an unreadable registry must not take the whole snapshot down"$'\n'"$out"
  printf '%s' "$out" | jq -e '.portfolio.available == false and (.portfolio.reason | length) > 0' >/dev/null \
    || fail "the snapshot should carry an explicit unavailable portfolio block"$'\n'"$out"
  printf '%s' "$out" | jq -e '.portfolio.projects == null and .portfolio.counted == null' >/dev/null \
    || fail "an unavailable classification must not read as an empty, permissive portfolio"

  out=$(run_in_home "$home" "$VIEW"); status=$?
  expect_code 0 "$status" "the fleet view should still render"$'\n'"$out"
  assert_contains "$out" "Classification unavailable" "the fleet view should say the classification is unavailable"

  out=$(run_in_home_quiet "$home" "$BEARINGS" --json); status=$?
  expect_code 0 "$status" "the bearings snapshot should still render"$'\n'"$out"
  assert_contains "$out" "classification unavailable" "bearings should disclose the unavailable classification"

  out=$(run_in_home "$home" "$SNAPSHOT" --portfolio); status=$?
  [ "$status" -ne 0 ] || fail "the intake surface must keep failing hard on an unreadable registry"
  chmod 644 "$home/data/projects.md"
  pass "an unreadable registry degrades the presentation surfaces loudly instead of taking them down"
}

test_an_absent_registry_is_unavailable_rather_than_a_quiet_fleet() {
  local home out status
  home=$(make_home registry-absent)
  [ -e "$home/data/projects.md" ] && rm -f "$home/data/projects.md"

  out=$(run_in_home_quiet "$home" "$SNAPSHOT" --json); status=$?
  expect_code 0 "$status" "an absent registry must not take the snapshot down"$'\n'"$out"
  printf '%s' "$out" | jq -e '.portfolio.available == false and (.portfolio.reason | test("absent"))' >/dev/null \
    || fail "the unavailable reason should say the registry is absent"$'\n'"$out"

  out=$(run_in_home "$home" "$VIEW"); status=$?
  expect_code 0 "$status" "the fleet view should still render"$'\n'"$out"
  assert_contains "$out" "Classification unavailable" "the fleet view should say the classification is unavailable"

  out=$(run_attention "$home" check delta); status=$?
  [ "$status" -ne 0 ] || fail "an absent registry must not answer permissively"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an absent registry is a failure, not a refusal"
  pass "an absent registry reads as unavailable, never as a quiet fleet that admits anything"
}

test_a_prose_bullet_is_not_a_project() {
  local home out
  home=$(make_home prose-bullet)
  register "$home" 'alpha - app (added 2026-01-01)'
  # Prose that is NOT written in the entry shape: no "[...]" annotation and no
  # " - " clause after the first word. The registry has to keep carrying notes
  # like these, and none of them may become a project.
  {
    printf '\n## Conventions\n\n'
    printf -- '- Keep each description short enough to identify the project.\n'
    printf -- '- Park a quiet project instead of removing its clone.\n'
    # A bracket group carrying a plus character but no flag token is prose too.
    printf -- '- Toolchains we support are [C++] and Rust.\n'
    printf -- '- Deploys target [staging+prod] together.\n'
  } >> "$home/data/projects.md"

  [ "$(class_of "$home" alpha)" = quiet ] || fail "the real registry entry should still classify"
  [ "$(class_of "$home" Keep)" = absent ] || fail "a prose bullet must not become a project"
  [ "$(class_of "$home" Park)" = absent ] || fail "a prose bullet must not become a project"
  [ "$(class_of "$home" Toolchains)" = absent ] || fail "a bracketed plus character must not read as a flag"
  [ "$(class_of "$home" Deploys)" = absent ] || fail "a bracketed plus character must not read as a flag"
  out=$(run_attention "$home" status)
  assert_not_contains "$out" "out of place" \
    "bracket prose carrying no flag token must not fail the registry read"
  out=$(run_attention "$home" status --json)
  [ "$(printf '%s' "$out" | jq -r '.projects | length')" = 1 ] \
    || fail "only the registry entry should be listed"$'\n'"$out"
  pass "a prose bullet in the registry is neither listed as a project nor parsed for flags"
}

# The cost of failing hard on a dateless entry (below) is that registry prose
# must not be written in the entry shape. That is a real constraint on what the
# captain may write, so it is pinned here rather than left to the header alone.
test_entry_shaped_prose_is_rejected_rather_than_guessed_at() {
  local home out status
  home=$(make_home prose-entry-shape)
  register "$home" 'alpha - app (added 2026-01-01)'
  printf -- '- Never - do this thing.\n' >> "$home/data/projects.md"

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a bullet written in the entry shape must not be silently ignored"$'\n'"$out"
  assert_contains "$out" "Never" "the failure should name the line it could not read"
  assert_contains "$out" "added" "the failure should name the missing contract field"
  pass "prose written in the entry shape is refused by name, never guessed at"
}

test_a_dateless_entry_fails_loudly_instead_of_unparking_the_project() {
  local home out status
  home=$(make_home dateless-parked-entry)
  # A hand-written parked entry that omits the documented added-date tail.
  # Dropping it would take its +parked flag with it and admit work on a project
  # the captain parked, so the classification must refuse to answer at all.
  register "$home" 'alpha [+parked] - shelved'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a dateless registry entry must not read as an empty portfolio"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the entry it could not read"
  assert_contains "$out" "added" "the failure should name the missing added-date tail"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag could not be read"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "a dateless entry fails loudly rather than silently unparking its project"
}

test_an_entry_without_a_description_still_carries_its_flags() {
  local home out status
  home=$(make_home terse-entry)
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'delta [+parked] (added 2026-01-02)'

  [ "$(class_of "$home" delta)" = parked ] || fail "an entry with no description separator should still parse its flags"
  out=$(run_attention "$home" check delta); status=$?
  expect_code 3 "$status" "intake must refuse attention-consuming work on that parked project"
  assert_contains "$out" "is parked" "the refusal should say the project is parked"

  out=$(run_in_home_quiet "$home" "$ROOT/bin/fm-project-mode.sh" delta); status=$?
  expect_code 0 "$status" "the single-project read should answer for the same entry"
  [ "$out" = "no-mistakes off" ] || fail "the entry's delivery posture should resolve, got: $out"
  pass "a registry entry without a description separator is read by both surfaces"
}

test_an_entry_carrying_only_the_added_date_is_still_a_project() {
  local home out status
  home=$(make_home bare-entry)
  # The registry contract makes the added-date tail required and the " - <desc>"
  # separator optional, so a name plus that tail is a whole entry. Dropping it
  # would hide the project from every portfolio surface and report it as never
  # registered at all.
  register "$home" 'alpha (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  queue_captain_hold "$home" hold-a alpha

  [ "$(class_of "$home" alpha)" = active ] || fail "a name-plus-date entry should classify like any other"
  out=$(run_attention "$home" status --json)
  printf '%s' "$out" | jq -e '[.projects[] | select(.name == "alpha")] | first | .registered' >/dev/null \
    || fail "a name-plus-date entry must read as registered"$'\n'"$out"
  [ "$(printf '%s' "$out" | jq -r '.projects | length')" = 2 ] \
    || fail "both registry entries should be listed"$'\n'"$out"

  out=$(run_in_home_quiet "$home" "$ROOT/bin/fm-project-mode.sh" alpha); status=$?
  expect_code 0 "$status" "the single-project read should answer for the same entry"
  [ "$out" = "no-mistakes off" ] || fail "the entry's delivery posture should resolve, got: $out"
  pass "an entry carrying only the added-date tail is read by both surfaces"
}

test_a_parked_focus_project_still_reports_the_focus_conflict() {
  local home out
  home=$(make_home parked-focus-conflict)
  # Parking exempts a project from the COUNT, never from the diagnostics: two
  # +focus annotations are a conflict even when one of them is parked.
  register "$home" 'alpha [+focus +parked] - shelved focus (added 2026-01-01)'
  register "$home" 'beta [+focus] - tool (added 2026-01-02)'
  queue_captain_hold "$home" hold-a alpha
  queue_captain_hold "$home" hold-b beta

  [ "$(class_of "$home" alpha)" = parked ] || fail "a parked project stays parked whatever else it carries"
  out=$(run_attention "$home" status)
  assert_contains "$out" "conflict:" "a parked +focus project must not hide the focus conflict"
  assert_contains "$out" "alpha" "the conflict should name the parked focus project"
  assert_contains "$out" "attention: 1/3" "the parked focus project must still count nothing"
  assert_contains "$out" "focus: beta" "the focus pointer should name the unparked focus project"
  out=$(run_attention "$home" status --json)
  [ "$(printf '%s' "$out" | jq -r '.focus')" = beta ] \
    || fail "the focus pointer must skip a parked +focus project"$'\n'"$out"
  [ "$(printf '%s' "$out" | jq -r '[.counted_projects[] | select(. == "alpha")] | length')" = 0 ] \
    || fail "a parked project must never enter the counted set"$'\n'"$out"
  printf '%s' "$out" | jq -e '
    [.projects[] | select(.name == "alpha")] | first | .reasons | index("focus designation")' >/dev/null \
    || fail "the parked project should still show its focus designation"$'\n'"$out"
  pass "a parked focus designation is still surfaced and still reported as a conflict"
}

test_an_indented_note_under_an_entry_is_not_a_project() {
  local home out status
  home=$(make_home indented-note)
  register "$home" 'alpha [no-mistakes +parked] - app (added 2026-01-01)'
  printf -- '  - blocked - waiting on the captain\n' >> "$home/data/projects.md"
  register "$home" 'beta - tool (added 2026-01-02)'

  out=$(run_attention "$home" status); status=$?
  expect_code 0 "$status" "an indented note must not take the classification down"$'\n'"$out"
  [ "$(class_of "$home" alpha)" = parked ] || fail "the parked entry above the note must still classify as parked"
  [ "$(class_of "$home" beta)" = quiet ] || fail "the entry below the note must still classify"
  [ "$(class_of "$home" blocked)" = absent ] || fail "an indented note must not become a project"

  out=$(run_attention "$home" check alpha); status=$?
  expect_code 3 "$status" "intake must still refuse work on the parked project"$'\n'"$out"
  assert_contains "$out" "is parked" "the refusal should say the project is parked"

  pass "an indented note is a note on the entry above it, never a project in the portfolio"
}

test_an_indented_entry_fails_instead_of_vanishing_from_the_portfolio() {
  local home out status
  home=$(make_home indented-entry)
  # A compliant entry the captain indented by mistake. Dropping it would take
  # its +parked flag with it and admit work on a project he shelved, so the
  # misplaced line is refused by name like any other unreadable entry.
  register "$home" 'beta - tool (added 2026-01-02)'
  printf -- '  - alpha [+parked] - shelved (added 2026-01-01)\n' >> "$home/data/projects.md"

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "an indented entry must not vanish from the portfolio"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the misplaced entry"
  assert_contains "$out" "column 0" "the failure should say where a registry entry must start"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag could not be read"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "an indented but otherwise compliant entry is refused rather than silently dropped"
}

test_an_indented_flag_annotation_is_refused_as_a_misplaced_entry() {
  local home out status
  home=$(make_home indented-flag)
  # No date tail this time: the portfolio flag alone is enough to say the line
  # is an entry the captain misplaced rather than a note.
  register "$home" 'beta - tool (added 2026-01-02)'
  printf -- '  - alpha [+focus] - the one to watch\n' >> "$home/data/projects.md"

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "an indented portfolio flag must not be read as prose"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the misplaced entry"
  assert_contains "$out" "column 0" "the failure should say where a registry entry must start"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not answer from a registry it could not read"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  pass "an indented bullet carrying a portfolio flag is refused as a misplaced entry"
}

test_an_indented_mistyped_flag_is_refused_as_a_misplaced_entry() {
  local home out status
  home=$(make_home indented-mistyped-flag)
  # Indentation plus a flag typo plus no date tail was the last shape by which
  # an intended parking annotation could vanish without a diagnostic.
  register "$home" 'beta - tool (added 2026-01-02)'
  printf -- '  - alpha [+parkd] - shelved\n' >> "$home/data/projects.md"

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "an indented mistyped flag must not be dropped silently"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the misplaced entry"
  assert_contains "$out" "column 0" "the failure should say where a registry entry must start"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not answer from a registry it could not read"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  pass "an indented bullet carrying any + token is refused as a misplaced entry"
}

test_an_indented_local_only_entry_keeps_its_delivery_posture() {
  local home out status
  home=$(make_home indented-local-only)
  # The delivery-posture read is permissive on purpose: its callers suppress
  # stderr and do not fail closed, so a line it fails to see would let fleet
  # sync and home seeding treat a local-only project as remote-backed.
  register "$home" 'beta - tool (added 2026-01-02)'
  printf -- '  - alpha [local-only] - x\n' >> "$home/data/projects.md"

  out=$(run_in_home_quiet "$home" "$ROOT/bin/fm-project-mode.sh" alpha); status=$?
  expect_code 0 "$status" "the single-project read should answer for an indented entry"
  [ "$out" = "local-only off" ] || fail "an indented local-only entry must keep its posture, got: $out"
  pass "an indented registry entry still resolves its delivery posture"
}

test_prose_ending_in_a_non_date_added_note_is_not_a_project() {
  local home out
  home=$(make_home added-parenthetical-prose)
  register "$home" 'alpha - app (added 2026-01-01)'
  # An "(added ...)" parenthetical that is not a date is prose, not an entry.
  {
    printf '\n## Conventions\n\n'
    printf -- '- Flags are recorded by the captain (added by hand, never by a worker)\n'
  } >> "$home/data/projects.md"

  [ "$(class_of "$home" alpha)" = quiet ] || fail "the real registry entry should still classify"
  [ "$(class_of "$home" Flags)" = absent ] || fail "a non-date added parenthetical must not become a project"
  out=$(run_attention "$home" status --json)
  [ "$(printf '%s' "$out" | jq -r '.projects | length')" = 1 ] \
    || fail "only the registry entry should be listed"$'\n'"$out"
  pass "prose ending in a non-date (added ...) parenthetical is not a project"
}

test_an_added_tail_carrying_further_clauses_still_lists() {
  local home
  home=$(make_home added-tail-clauses)
  # The live registry records renames and origin changes after the date.
  register "$home" 'alpha - app (added 2026-01-01; renamed 2026-01-05)'

  [ "$(class_of "$home" alpha)" = quiet ] || fail "an added tail with further clauses should still list"
  pass "an added-date tail carrying further clauses is still a registry entry"
}

test_a_duplicated_project_name_fails_instead_of_picking_a_row() {
  local home out status
  home=$(make_home duplicate-name)
  # The re-added row sits above the parked one, so any silent selection drops
  # the captain's parking decision.
  register "$home" 'alpha - app (added 2026-02-01)'
  register "$home" 'alpha [+parked] - app, shelved (added 2026-01-01)'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a duplicated project name must not resolve to one of its rows"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the duplicated project"
  assert_contains "$out" "more than once" "the failure should say the project is listed twice"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag is ambiguous"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "a duplicated registry name fails loudly rather than silently unparking a project"
}

test_prose_ending_in_an_added_date_is_not_a_project() {
  local home out
  home=$(make_home added-date-prose)
  register "$home" 'alpha [+parked] - app (added 2026-01-01)'
  # A history note whose first word happens to be a real project name: it must
  # stay prose rather than list as a second, unparked alpha row.
  {
    printf '\n## History\n\n'
    printf -- '- alpha moved off the old host (added 2026-05-01)\n'
    printf -- '- Superseded the old beta clone (added 2026-05-02)\n'
  } >> "$home/data/projects.md"

  [ "$(class_of "$home" alpha)" = parked ] || fail "the real entry must keep its parking decision"
  [ "$(class_of "$home" Superseded)" = absent ] || fail "a history note must not become a project"
  out=$(run_attention "$home" status --json)
  [ "$(printf '%s' "$out" | jq -r '.projects | length')" = 1 ] \
    || fail "only the registry entry should be listed"$'\n'"$out"
  pass "a note that merely ends in an added-date tail stays prose"
}

test_an_unrecognized_mode_is_shown_with_the_posture_it_actually_ships() {
  local home out
  home=$(make_home unrecognized-mode)
  # +yolo alongside the bad mode: the fallback resets the yolo posture too, so
  # the cell must name the whole effective posture rather than the mode alone.
  register "$home" 'alpha [weird +yolo] - x (added 2026-01-01)'

  out=$(run_in_home "$home" "$VIEW")
  assert_contains "$out" "weird" "the portfolio table should show what the registry actually says"
  assert_contains "$out" "unrecognized" "an unrecognized mode should be marked as such"
  assert_contains "$out" "ships no-mistakes off" \
    "the table should name the whole posture the project actually ships, yolo included"

  # What the delivery-posture consumers actually resolve, which the cell claims.
  out=$(run_in_home_quiet "$home" "$ROOT/bin/fm-project-mode.sh" alpha)
  [ "$out" = "no-mistakes off" ] || fail "the marker must name the posture consumers resolve, got: $out"

  out=$(run_attention "$home" status --json)
  [ "$(printf '%s' "$out" | jq -r '.projects[0].yolo')" = on ] \
    || fail "the machine-readable yolo must stay the registry's own word"$'\n'"$out"
  [ "$(printf '%s' "$out" | jq -r '.projects[0].mode')" = weird ] \
    || fail "the machine-readable mode must stay the registry's own word"$'\n'"$out"
  [ "$(printf '%s' "$out" | jq -r '.projects[0].mode_recognized')" = false ] \
    || fail "an unrecognized mode should be flagged as unrecognized"$'\n'"$out"
  pass "an unrecognized registered mode is shown as written and marked with its real posture"
}

test_a_conditional_policy_mode_is_displayed_as_itself() {
  local home out
  home=$(make_home prod-only-mode)
  register "$home" 'alpha [no-mistakes-prod-only] - x (added 2026-01-01)'

  out=$(run_in_home "$home" "$VIEW")
  assert_contains "$out" "no-mistakes-prod-only" "a conditional policy should display as itself"
  assert_not_contains "$out" "unrecognized" "a conditional policy is a recognized mode, not a typo"
  pass "a conditional policy mode is displayed as itself, never marked unrecognized"
}

test_an_annotation_after_the_date_tail_is_refused() {
  local home out status
  home=$(make_home annotation-out-of-place)
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'alpha (added 2026-01-01) [+parked]'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a misplaced annotation must not be dropped with its flags"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the entry it could not read"
  assert_contains "$out" "immediately follow" "the failure should say where the annotation belongs"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag was misplaced"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "an annotation placed after the added-date tail is refused rather than dropped"
}

test_an_annotation_after_the_description_is_refused() {
  local home out status
  home=$(make_home late-annotation)
  register "$home" 'beta - tool (added 2026-01-02)'
  # Otherwise a well-formed entry, so nothing else refuses it: the annotation
  # sits where the parser never reads it, and the parking decision would vanish.
  register "$home" 'alpha - app [+parked] (added 2026-01-01)'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a late annotation must not list with its flags dropped"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the entry it could not read"
  assert_contains "$out" "immediately follow" "the failure should say where the annotation belongs"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag was misplaced"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "an annotation placed after the description is refused rather than dropped"
}

test_a_second_bracket_group_beside_the_annotation_is_refused() {
  local home out status
  home=$(make_home second-bracket-group)
  register "$home" 'beta - tool (added 2026-01-02)'
  # The first group parses; a second one beside it is read by nothing, so its
  # focus designation would vanish without a diagnostic.
  register "$home" 'gamma [no-mistakes][+focus] - app (added 2026-01-03)'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a second bracket group must not be read as part of the annotation"$'\n'"$out"
  assert_contains "$out" "gamma" "the failure should name the entry it could not read"
  assert_contains "$out" "immediately follow" "the failure should say where the annotation belongs"
  pass "a second bracket group beside the annotation is refused rather than misparsed"
}

test_a_bracket_group_glued_to_a_word_is_refused() {
  local home out status
  home=$(make_home glued-bracket-group)
  register "$home" 'beta - tool (added 2026-01-02)'
  # One space away from the shape above, and read by nothing at all: the
  # brackets begin no whitespace-separated field.
  register "$home" 'alpha - app[+parked] (added 2026-01-01)'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a glued bracket group must not drop its flags silently"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the entry it could not read"
  assert_contains "$out" "immediately follow" "the failure should say where the annotation belongs"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag was glued"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "a bracket group glued to a word is refused rather than dropped"
}

test_a_bracket_group_glued_to_the_name_is_refused() {
  local home out status
  home=$(make_home glued-to-name)
  register "$home" 'beta - tool (added 2026-01-02)'
  # Without the rule this lists a phantom row named "alpha[+parked]", leaving
  # the real alpha absent from the registry altogether.
  register "$home" 'alpha[+parked] - app (added 2026-01-01)'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a name glued to its annotation must not become a phantom project"$'\n'"$out"
  assert_contains "$out" "immediately follow" "the failure should say where the annotation belongs"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not treat the parked project as unregistered"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "a bracket group glued to the project name is refused rather than read as the name"
}

test_a_glued_group_before_a_real_annotation_is_refused() {
  local home out status
  home=$(make_home glued-before-annotation)
  register "$home" 'beta - tool (added 2026-01-02)'
  # A legitimate annotation follows the glued one, so the parsed slot is not the
  # first bracket group on the line.
  register "$home" 'alpha[+parked] [no-mistakes] - app (added 2026-01-01)'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a glued group before the annotation must not be skipped"$'\n'"$out"
  assert_contains "$out" "immediately follow" "the failure should say where the annotation belongs"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag was glued"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "a glued group before a real annotation is refused, not mistaken for the parsed slot"
}

test_an_unterminated_annotation_cannot_swallow_a_later_group() {
  local home out status
  home=$(make_home unterminated-annotation)
  register "$home" 'beta - tool (added 2026-01-02)'
  # The annotation is missing its "]", so a naive scan pairs it with the later
  # group's bracket and reads the whole span as one in-place annotation.
  register "$home" 'alpha [no-mistakes - app [+parked] (added 2026-01-01)'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "an unterminated annotation must not absorb a later flag group"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the entry it could not read"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not admit work on a project whose parking flag was swallowed"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  assert_not_contains "$out" "takes attention slot" \
    "intake must never answer permissively from a registry it could not read"
  pass "an unterminated annotation is refused rather than swallowing a later flag group"
}

test_a_name_only_bullet_is_a_half_written_entry() {
  local home out status
  home=$(make_home bare-name-entry)
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'alpha'

  out=$(run_attention "$home" status); status=$?
  [ "$status" -ne 0 ] || fail "a name-only bullet must not vanish from the portfolio"$'\n'"$out"
  assert_contains "$out" "alpha" "the failure should name the half-written entry"
  assert_contains "$out" "added" "the failure should name the missing added-date tail"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "intake must not answer from a registry it could not read"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "an unreadable registry is a failure, not a refusal"
  pass "a bullet carrying only a project name is refused as a half-written entry"
}

test_a_dateless_entry_still_resolves_its_delivery_posture() {
  local home out status
  home=$(make_home dateless-entry)
  register "$home" 'alpha [local-only] - alpha project'

  # The delivery-posture read must never lose a registered local-only project:
  # its callers read it permissively, so an unrecognized line would void the guard.
  out=$(run_in_home_quiet "$home" "$ROOT/bin/fm-project-mode.sh" alpha); status=$?
  expect_code 0 "$status" "the single-project read should answer for a dateless entry"
  [ "$out" = "local-only off" ] || fail "a dateless entry must keep its registered posture, got: $out"
  pass "a registry entry without the added-date tail keeps its delivery posture"
}

test_a_mistyped_portfolio_flag_fails_loudly() {
  local home out status
  home=$(make_home mistyped-flag)
  register "$home" 'alpha [+park] - shelved (added 2026-01-01)'

  out=$(run_in_home "$home" "$ROOT/bin/fm-project-mode.sh" --list); status=$?
  [ "$status" -ne 0 ] || fail "a mistyped portfolio flag must fail the registry read"$'\n'"$out"
  assert_contains "$out" "+park" "the failure should name the offending token"
  assert_contains "$out" "alpha" "the failure should name the project"
  assert_contains "$out" "+yolo, +focus, +parked" "the failure should name the accepted flags"

  # The single-project read now shares the fail-closed contract: its
  # delivery-posture callers refuse on a non-zero read, so a mistyped flag
  # exits non-zero with no mode line to guess from (bin/fm-project-mode.sh).
  out=$(run_in_home_quiet "$home" "$ROOT/bin/fm-project-mode.sh" alpha); status=$?
  expect_code 1 "$status" "the single-project read must refuse a mistyped flag"
  [ -z "$out" ] || fail "a failed posture read printed a mode to guess from: $out"
  out=$(run_in_home "$home" "$ROOT/bin/fm-project-mode.sh" alpha); status=$?
  assert_contains "$out" "+park" "the single-project failure should name the offending token"
  assert_contains "$out" "+yolo, +focus, +parked" "the failure should name the accepted flags"

  out=$(run_attention "$home" check alpha); status=$?
  [ "$status" -ne 0 ] || fail "a mistyped parking annotation must not quietly admit work"$'\n'"$out"
  [ "$status" -ne 3 ] || fail "a rejected registry is a failure, not a refusal"
  pass "a mistyped portfolio flag fails loudly instead of voiding the captain's decision"
}

# --- intake enforcement -----------------------------------------------------

setup_intake_home() {  # <name> [quiet] - echoes "home|proj|wt|fakebin|launchlog"
  local name=$1 quiet=${2:-} case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/delta"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  register "$home" 'alpha - app (added 2026-01-01)'
  register "$home" 'beta - tool (added 2026-01-02)'
  register "$home" 'gamma - lib (added 2026-01-03)'
  if [ -z "$quiet" ]; then
    queue_captain_hold "$home" hold-a alpha
    queue_captain_hold "$home" hold-b beta
    queue_captain_hold "$home" hold-c gamma
  fi
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

test_intake_refuses_a_fourth_attention_project_before_anything_is_created() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-refuse)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  fm_test_spawn_brief "$home" wip-1 "Delivery contract: mode=no-mistakes"

  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-1 "$proj" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "dispatching a fourth attention project should refuse"$'\n'"$out"
  assert_contains "$out" "attention limit" "the refusal should name the attention limit"
  assert_contains "$out" "alpha, beta, gamma" "the refusal should name the three projects already open"
  [ ! -e "$home/state/wip-1.meta" ] || fail "a refused intake must not leave a task record behind"
  [ ! -s "$launchlog" ] || fail "a refused intake must not launch a worker"
  pass "intake refuses a fourth attention project before any worker or record exists"
}

test_intake_refuses_a_parked_project_as_parked_not_as_a_limit_breach() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-parked quiet)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  # An empty portfolio, so nothing here is anywhere near the limit: the only
  # reason to refuse is that the captain parked this project.
  register "$home" 'delta [+parked] - shelved (added 2026-01-04)'
  fm_test_spawn_brief "$home" wip-1 "Delivery contract: mode=no-mistakes"

  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-1 "$proj" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "dispatching on a parked project should refuse"$'\n'"$out"
  assert_contains "$out" "is parked" "the refusal should say the project is parked"
  assert_contains "$out" "reopen" "the refusal should point at reopening the project"
  assert_not_contains "$out" "attention limit" \
    "a parked refusal must not claim a limit breach that did not happen"
  assert_not_contains "$out" "holds the slots" \
    "a parked refusal must not point at finding a slot to free"
  assert_contains "$out" "--attention-override" "the override guidance should stay visible"
  [ ! -e "$home/state/wip-1.meta" ] || fail "a refused intake must not leave a task record behind"
  [ ! -s "$launchlog" ] || fail "a refused intake must not launch a worker"
  pass "a parked project is refused at intake as parked, never as an attention-limit breach"
}

test_intake_override_dispatches_the_fourth_project() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-override)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  queue_row "$home" wip-2
  fm_test_spawn_brief "$home" wip-2 "Delivery contract: mode=no-mistakes"

  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-2 "$proj" --mode no-mistakes --yolo off \
      --attention-override)
  status=$?
  expect_code 0 "$status" "an explicit captain instruction should dispatch past the limit"$'\n'"$out"
  assert_contains "$out" "dispatches on an explicit captain instruction" \
    "the override should be recorded loudly"
  [ -e "$home/state/wip-2.meta" ] || fail "an overridden intake should still dispatch"
  pass "an explicit captain instruction dispatches the fourth project and says so"
}

test_intake_fails_open_when_the_classification_cannot_be_computed() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-fail-open)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  queue_row "$home" wip-5
  fm_test_spawn_brief "$home" wip-5 "Delivery contract: mode=no-mistakes"
  # A dateless entry is unreadable to the registry --list surface, so the
  # attention classification cannot be computed, while the spawn's own project
  # posture read still answers - the attention bound fails open even though the
  # delivery-posture guard stays enforceable.
  register "$home" 'deltaless - shelved without a date tail'

  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-5 "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an uncomputable classification must not halt dispatch"$'\n'"$out"
  assert_contains "$out" "could not be checked" "the fail-open path should warn loudly"
  [ -e "$home/state/wip-5.meta" ] || fail "a fail-open dispatch should still create the task"
  pass "intake fails open with a loud warning when the classification cannot be computed"
}

test_intake_refuses_when_the_registry_file_cannot_be_read() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-unreadable-registry)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  queue_row "$home" wip-8
  fm_test_spawn_brief "$home" wip-8 "Delivery contract: mode=no-mistakes"
  chmod 000 "$home/data/projects.md"
  if [ -r "$home/data/projects.md" ]; then
    chmod 644 "$home/data/projects.md"
    echo "# skip fm-attention: registry permissions are not enforced for this user"
    return 0
  fi

  # An unreadable registry FILE is the file-level half of the fail-closed
  # contract: the posture cannot be read at all, so the spawn must refuse rather
  # than dispatch against the permissive default.
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-8 "$proj" --mode no-mistakes --yolo off)
  status=$?
  chmod 644 "$home/data/projects.md"
  [ "$status" -ne 0 ] || fail "an unreadable registry file must refuse the dispatch"$'\n'"$out"
  assert_contains "$out" "cannot read the registered delivery posture" \
    "the refusal must say the posture could not be read"
  [ ! -e "$home/state/wip-8.meta" ] || fail "a refused intake must not create the task"
  pass "an unreadable registry file refuses intake instead of dispatching on the default posture"
}

test_intake_announces_an_override_only_where_it_was_used() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-override-unused)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  queue_row "$home" wip-6
  fm_test_spawn_brief "$home" wip-6 "Delivery contract: mode=no-mistakes"

  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-6 "$proj" --mode no-mistakes --yolo off \
      --attention-override)
  status=$?
  expect_code 0 "$status" "an admissible project should dispatch"$'\n'"$out"
  assert_not_contains "$out" "explicit captain instruction" \
    "an override that carried nothing must not be announced"
  pass "intake announces an override only where it actually carried the admission"
}

test_intake_never_silently_admits_work_on_a_mistyped_parking_annotation() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-mistyped-flag)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  register "$home" 'delta [+park] - typo for parked (added 2026-01-05)'
  queue_row "$home" wip-7
  fm_test_spawn_brief "$home" wip-7 "Delivery contract: mode=no-mistakes"

  # The mistyped flag sits on the SPAWN TARGET's own annotation, so the
  # delivery-posture read refuses the dispatch outright - a stronger guarantee
  # than the attention bound's fail-open: work is never admitted on a posture
  # the guard could not read.
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-7 "$proj" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a mistyped annotation on the target project must refuse the dispatch"$'\n'"$out"
  assert_contains "$out" 'unknown flag "+park" on project "delta"' \
    "the refusal must name the offending annotation"
  assert_contains "$out" "cannot read the registered delivery posture for delta" \
    "the refusal must name the caller and the project"
  [ ! -e "$home/state/wip-7.meta" ] || fail "a refused intake must not create the task"
  pass "a mistyped parking annotation refuses intake instead of quietly admitting work"
}

test_intake_does_not_gate_work_that_opens_no_captain_lane() {
  local rec home proj wt fakebin launchlog out status
  rec=$(setup_intake_home intake-autonomous)
  IFS='|' read -r home proj wt fakebin launchlog <<EOF
$rec
EOF
  queue_row "$home" wip-3
  fm_test_spawn_brief "$home" wip-3 "Delivery contract: mode=no-mistakes"

  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" wip-3 "$proj" --mode no-mistakes --yolo on)
  status=$?
  expect_code 0 "$status" "autonomous work should not be gated by the captain's attention limit"$'\n'"$out"
  assert_not_contains "$out" "attention limit" "autonomous work should not mention the limit at all"
  [ -e "$home/state/wip-3.meta" ] || fail "autonomous work should dispatch"
  pass "work that opens no captain decision lane is never gated by the limit"
}

test_registered_quiet_projects_do_not_consume_attention
test_each_durable_captain_lane_makes_a_project_active
test_answered_decision_releases_the_slot
test_autonomous_execution_creates_no_attention_lane
test_parked_projects_stay_quiet_and_uncounted
test_focus_is_shown_but_counts_only_while_it_carries_a_lane
test_unregistered_worked_on_projects_are_classified_too
test_a_captain_approval_ship_counts_from_dispatch
test_a_secondmate_home_consumes_no_attention_slot
test_a_scout_lane_counts_from_dispatch
test_an_unreadable_classification_fails_instead_of_refusing
test_a_snapshot_without_an_enforced_field_is_read_as_enforced
test_an_override_says_so_only_where_it_carried_the_admission
test_an_unreadable_registry_keeps_every_presentation_surface_readable
test_an_absent_registry_is_unavailable_rather_than_a_quiet_fleet
test_a_mistyped_portfolio_flag_fails_loudly
test_an_absent_config_keeps_the_built_in_default
test_a_configured_limit_moves_the_edge_intake_refuses_at
test_a_disabled_limit_admits_without_refusing_and_says_so_everywhere
test_a_disabled_limit_still_leaves_a_parked_project_parked
test_an_invalid_configured_limit_fails_loudly_instead_of_defaulting
test_a_config_file_that_is_not_a_plain_regular_file_is_rejected
test_a_symlinked_config_directory_is_rejected
test_an_unreadable_limit_file_fails_loudly
test_the_limit_is_not_configurable_through_the_environment
test_a_prose_bullet_is_not_a_project
test_entry_shaped_prose_is_rejected_rather_than_guessed_at
test_a_dateless_entry_fails_loudly_instead_of_unparking_the_project
test_an_entry_without_a_description_still_carries_its_flags
test_a_dateless_entry_still_resolves_its_delivery_posture
test_an_entry_carrying_only_the_added_date_is_still_a_project
test_a_parked_focus_project_still_reports_the_focus_conflict
test_an_indented_note_under_an_entry_is_not_a_project
test_an_indented_entry_fails_instead_of_vanishing_from_the_portfolio
test_an_indented_flag_annotation_is_refused_as_a_misplaced_entry
test_an_indented_mistyped_flag_is_refused_as_a_misplaced_entry
test_an_indented_local_only_entry_keeps_its_delivery_posture
test_prose_ending_in_a_non_date_added_note_is_not_a_project
test_an_added_tail_carrying_further_clauses_still_lists
test_a_duplicated_project_name_fails_instead_of_picking_a_row
test_prose_ending_in_an_added_date_is_not_a_project
test_an_unrecognized_mode_is_shown_with_the_posture_it_actually_ships
test_a_conditional_policy_mode_is_displayed_as_itself
test_an_annotation_after_the_date_tail_is_refused
test_an_annotation_after_the_description_is_refused
test_a_second_bracket_group_beside_the_annotation_is_refused
test_a_bracket_group_glued_to_a_word_is_refused
test_a_bracket_group_glued_to_the_name_is_refused
test_a_glued_group_before_a_real_annotation_is_refused
test_an_unterminated_annotation_cannot_swallow_a_later_group
test_a_name_only_bullet_is_a_half_written_entry
test_an_over_limit_refusal_reports_the_counted_set_it_names
test_a_failed_registry_read_fails_instead_of_forgetting_parked_projects
test_fourth_attention_project_is_refused_at_the_edge
test_parked_project_refuses_new_work_until_reopened
test_override_is_the_only_way_past_a_refusal
test_portfolio_presentation_surfaces_show_the_classification
test_the_fleet_view_shows_the_limit_even_during_a_focus_conflict
test_intake_refuses_a_fourth_attention_project_before_anything_is_created
test_intake_refuses_a_parked_project_as_parked_not_as_a_limit_breach
test_intake_override_dispatches_the_fourth_project
test_intake_does_not_gate_work_that_opens_no_captain_lane
test_intake_fails_open_when_the_classification_cannot_be_computed
test_intake_never_silently_admits_work_on_a_mistyped_parking_annotation
test_intake_refuses_when_the_registry_file_cannot_be_read
test_intake_announces_an_override_only_where_it_was_used

echo "# all fm-attention tests passed"
