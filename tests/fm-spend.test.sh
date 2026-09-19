#!/usr/bin/env bash
# Behavior tests for bin/fm-spend.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spend)
FAKE_BIN=$(fm_fakebin "$TMP_ROOT")

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-spend.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-spend.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-spend.sh emitted unexpected output: $out"
  pass "fm-spend.sh: bash -n succeeds"
}

test_help() {
  local out rc
  out=$("$ROOT/bin/fm-spend.sh" --help); rc=$?
  expect_code 0 "$rc" "fm-spend.sh --help must exit 0"
  assert_contains "$out" "usage: fm-spend.sh" "fm-spend.sh --help must print usage"
  pass "fm-spend.sh: --help prints usage and exits 0"
}

test_missing_tokscale() {
  local out rc
  out=$(PATH="$FAKE_BIN:/usr/bin:/bin" "$ROOT/bin/fm-spend.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "fm-spend.sh without tokscale must exit 1"
  assert_contains "$out" "fm-spend: tokscale not found" "fm-spend.sh must emit clear missing error"
  pass "fm-spend.sh: missing tokscale emits clear error and exits 1"
}

test_workspace_mapping_and_aggregation() {
  local home state fake_tokscale out rc
  home="$TMP_ROOT/home"
  state="$home/state"
  mkdir -p "$state"

  # Create task meta files
  fm_write_meta "$state/task-alpha.meta" \
    "worktree=/Users/testuser/.treehouse/firstmate-abc123/1/firstmate" \
    "endpoint_task_id=task-alpha"

  fm_write_meta "$state/task-beta.meta" \
    "worktree=/Users/testuser/.treehouse/quota-axi-xyz789/2/quota-axi" \
    "endpoint_task_id=task-beta"

  # Mock tokscale that returns a table with ANSI escape codes and multiple models per workspace
  fake_tokscale="$FAKE_BIN/tokscale"
  cat > "$fake_tokscale" <<'EOF'
#!/usr/bin/env bash
cat <<'TABLE'
  Token Usage Report by Model (Today)

┌────────────────────────────────────────────────────────┬───────────┬─────────────────┬──────────────────┬─────────┬────────┬─────────────┬────────────┬────────────┬───────┬───────┐
│ Workspace                                              │ Providers │ Sources         │ Model            │ Input   │ Output │ Cache Write │ Cache Read │ Total      │ ms/1K │ Cost  │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ -Users-testuser--treehouse-firstmate-abc123-1-firstmate│ Anthropic │ Claude Code     │ claude-opus-5    │      50 │ 15,601 │     137,988 │  2,849,318 │  3,002,957 │  69ms │ $2.68 │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ -Users-testuser--treehouse-quota-axi-xyz789-2-quota-axi│ Anthropic │ Claude Code     │ claude-opus-5    │      10 │  1,000 │      10,000 │    500,000 │    511,010 │  50ms │ $1.00 │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ -Users-testuser--treehouse-quota-axi-xyz789-2-quota-axi│ OpenAI    │ Codex           │ gpt-5.6-sol      │      20 │  2,000 │      20,000 │    400,000 │    422,020 │  40ms │ $0.50 │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ -Users-testuser--treehouse-unmapped-slot-9-repo        │ Anthropic │ Claude Code     │ claude-opus-5    │      12 │  2,207 │      11,446 │    938,268 │    951,933 │  35ms │ $0.60 │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ firstmate                                              │ Google    │ Antigravity CLI │ gemini-3.7-flash │ 100,000 │  1,000 │           0 │    300,000 │    401,000 │     — │ $0.10 │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ firstmate                                              │ Zai       │ Pi              │ glm-5.3-flash    │  10,000 │  5,000 │           0 │  2,000,000 │  2,015,000 │     — │ $0.05 │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ Total                                                  │           │                 │                  │ 110,082 │ 24,808 │     169,434 │  6,687,586 │  7,303,920 │  60ms │ $4.93 │
└────────────────────────────────────────────────────────┴───────────┴─────────────────┴──────────────────┴─────────┴────────┴─────────────┴────────────┴────────────┴───────┴───────┘
TABLE
EOF
  chmod +x "$fake_tokscale"

  out=$(PATH="$FAKE_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-spend.sh"); rc=$?
  expect_code 0 "$rc" "fm-spend.sh must exit 0 on valid table"

  # task-alpha mapped correctly
  assert_contains "$out" "task-alpha" "must map firstmate-abc123-1 to task-alpha"
  assert_contains "$out" "3,002,957 tokens" "must preserve task-alpha tokens"
  assert_contains "$out" "$  2.68" "must preserve task-alpha cost"

  # task-beta mapped and aggregated (3,002,957 is alpha; beta total is 511010 + 422020 = 933,030, cost $1.50)
  assert_contains "$out" "task-beta" "must map quota-axi-xyz789-2 to task-beta"
  assert_contains "$out" "933,030 tokens" "must aggregate task-beta tokens"
  assert_contains "$out" "$  1.50" "must aggregate task-beta cost"

  # unmapped row falls back to short path
  # shellcheck disable=SC2088
  assert_contains "$out" "~/.treehouse/unmapped-slot-9-repo" "must fall back to short path for unmapped row"

  # primary firstmate row aggregated (401000 + 2015000 = 2,416,000, cost $0.15)
  assert_contains "$out" "(firstmate)" "must label firstmate workspace as (firstmate)"
  assert_contains "$out" "2,416,000 tokens" "must aggregate primary tokens"
  assert_contains "$out" "$  0.15" "must aggregate primary cost"

  # Total summary row should not be printed as a workspace
  assert_not_contains "$out" "Total                                 " "must not print Total row as workspace"

  pass "fm-spend.sh: maps task IDs, aggregates per workspace, and falls back to short path"
}

test_works_from_any_cwd() {
  local home state fake_tokscale out rc foreign_dir
  home="$TMP_ROOT/home"
  state="$home/state"
  foreign_dir="$TMP_ROOT/foreign/nested"
  mkdir -p "$state" "$foreign_dir"

  fm_write_meta "$state/sample-task.meta" \
    "worktree=/Users/testuser/.treehouse/sample-repo-1/1/sample-repo" \
    "endpoint_task_id=sample-task"

  fake_tokscale="$FAKE_BIN/tokscale"
  cat > "$fake_tokscale" <<'EOF'
#!/usr/bin/env bash
cat <<'TABLE'
┌────────────────────────────────────────────────────────┬───────────┬─────────────────┬──────────────────┬─────────┬────────┬─────────────┬────────────┬────────────┬───────┬───────┐
│ Workspace                                              │ Providers │ Sources         │ Model            │ Input   │ Output │ Cache Write │ Cache Read │ Total      │ ms/1K │ Cost  │
├────────────────────────────────────────────────────────┼───────────┼─────────────────┼──────────────────┼─────────┼────────┼─────────────┼────────────┼────────────┼───────┼───────┤
│ -Users-testuser--treehouse-sample-repo-1-1-sample-repo │ Anthropic │ Claude Code     │ claude-opus-5    │     100 │  1,000 │           0 │     10,000 │     11,100 │  50ms │ $0.10 │
└────────────────────────────────────────────────────────┴───────────┴─────────────────┴──────────────────┴─────────┴────────┴─────────────┴────────────┴────────────┴───────┴───────┘
TABLE
EOF
  chmod +x "$fake_tokscale"

  out=$(cd "$foreign_dir" && PATH="$FAKE_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-spend.sh"); rc=$?
  expect_code 0 "$rc" "fm-spend.sh must work from any cwd"
  assert_contains "$out" "sample-task" "fm-spend.sh must find and resolve task from foreign cwd"
  pass "fm-spend.sh: works from any cwd"
}

test_passthrough_args() {
  local home state fake_tokscale out rc args_log
  home="$TMP_ROOT/home"
  state="$home/state"
  args_log="$TMP_ROOT/args.log"
  mkdir -p "$state"

  fake_tokscale="$FAKE_BIN/tokscale"
  cat > "$fake_tokscale" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$args_log"
cat <<'TABLE'
┌───────────┬───────┬───────┐
│ Workspace │ Total │ Cost  │
└───────────┴───────┴───────┘
TABLE
EOF
  chmod +x "$fake_tokscale"

  # Default with no args should pass --today
  PATH="$FAKE_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-spend.sh" >/dev/null
  assert_grep "--today" "$args_log" "default execution must pass --today to tokscale"

  # Explicit args should pass through
  PATH="$FAKE_BIN:$PATH" FM_HOME="$home" "$ROOT/bin/fm-spend.sh" --week --since 2026-08-01 >/dev/null
  assert_grep "--week --since 2026-08-01" "$args_log" "explicit args must pass through to tokscale"

  pass "fm-spend.sh: passes through arguments correctly"
}

test_script_parses
test_help
test_missing_tokscale
test_workspace_mapping_and_aggregation
test_works_from_any_cwd
test_passthrough_args
