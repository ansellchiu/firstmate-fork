#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
case_dir=$(fm_test_tmproot fm-slot-audit)
home="$case_dir/home"
other="$case_dir/other"
slot="$case_dir/pool/1/repo"
mkdir -p "$home/state" "$home/projects" "$other/state" "$slot" "$case_dir/bin" "$case_dir/clone/subdir" "$case_dir/isolated"
ln -s "$slot" "$case_dir/alias"
ln -s "$case_dir/clone" "$home/projects/demo"
printf 'worktree=%s/\n' "$case_dir/alias" > "$home/state/first.meta"
printf 'worktree=%s\n' "$slot" > "$other/state/second.meta"
printf 'home=%s\ntask=second\n' "$other" > "$case_dir/pool/1/.fm-slot-owner"
real_ps=$(command -v ps)
real_readlink=$(command -v readlink)
export AUDIT_FIXTURE="$case_dir" AUDIT_REAL_PS="$real_ps" AUDIT_REAL_READLINK="$real_readlink"
cat > "$case_dir/bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -eo ]; then
  cat "$AUDIT_FIXTURE/rows"
elif [ "$1" = -Eww ]; then
  cat "$AUDIT_FIXTURE/env-$5"
else
  exec "$AUDIT_REAL_PS" "$@"
fi
SH
cat > "$case_dir/bin/lsof" <<'SH'
#!/usr/bin/env bash
[ "${AUDIT_HIDE_CWD:-0}" != 1 ] || exit 1
cat "$AUDIT_FIXTURE/cwd-$2"
SH
cat > "$case_dir/bin/readlink" <<'SH'
#!/usr/bin/env bash
[ "${AUDIT_HIDE_CWD:-0}" != 1 ] || exit 1
exec "$AUDIT_REAL_READLINK" "$@"
SH
chmod +x "$case_dir/bin/ps" "$case_dir/bin/lsof" "$case_dir/bin/readlink"
: > "$case_dir/rows"
: > "$case_dir/pids"
cleanup_workers() {
  while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$case_dir/pids"
}
trap 'cleanup_workers; fm_test_cleanup' EXIT
add_process() {
  local task=$1 cwd=$2 comm=$3 args=$4 pid
  (cd "$cwd"; exec env FM_TASK_ID="$task" FM_TASK_INBOX="$home/state/$task.inbox" sleep 120) &
  pid=$!
  printf '%s\n' "$pid" >> "$case_dir/pids"
  printf '%s %s %s\n' "$pid" "$comm" "$args" >> "$case_dir/rows"
  printf 'sleep FM_TASK_ID=%s FM_TASK_INBOX=%s/state/%s.inbox\n' "$task" "$home" "$task" > "$case_dir/env-$pid"
  printf 'n%s\n' "$cwd" > "$case_dir/cwd-$pid"
  if [ "$task" != interactive ]; then
    printf 'kind=ship\n' > "$home/state/$task.meta"
  fi
}
add_process native "$home" 2.1.220 /opt/claude/versions/2.1.220
add_process cursor "$case_dir/clone/subdir" MainThread /opt/cursor-agent/versions/1/node
add_process gemini "$home" MainThread 'node /opt/@google/gemini-cli/bin/gemini.js'
add_process muse "$home" muse-bin-1.0 muse-bin-1.0
add_process signed "$home" pi-signed pi-signed
add_process launcher "$home" pi-launcher pi-launcher
add_process pi-app "$home" Pi Pi
for harness in claude cursor-agent agy codex opencode pi grok kimi devin rovo omp; do
  add_process "$harness" "$home" "$harness" "$harness"
done
add_process fix.v2 "$home" codex codex
git init --quiet "$case_dir/primary"
mkdir -p "$case_dir/primary/src"
git -C "$case_dir/primary" -c user.name=t -c user.email=t@example.invalid commit --quiet --allow-empty -m init
git -C "$case_dir/primary" worktree add --quiet --detach "$case_dir/linked"
add_process external "$case_dir/primary/src" codex codex
printf 'project=%s\n' "$case_dir/linked" >> "$home/state/external.meta"
add_process isolated "$case_dir/isolated" codex codex
add_process interactive "$home" codex codex
sleep 0.1
set +e
out=$(FM_HOME="$home" PATH="$case_dir/bin:$PATH" bash "$ROOT/bin/fm-slot-audit.sh")
status=$?
set -e
expect_code 1 "$status" 'audit reports ambiguous ownership'
assert_contains "$out" "DOUBLE_CLAIM $slot $home/state/first.meta $other/state/second.meta" 'canonical cross-home claimants are reported'
for task in fix.v2 external native cursor gemini muse signed launcher pi-app claude cursor-agent agy codex opencode pi grok kimi devin rovo omp; do
  assert_contains "$out" "OUT_OF_ISOLATION $task " "worker $task is detected"
done
if [[ "$out" == *'OUT_OF_ISOLATION interactive '* || "$out" == *'OUT_OF_ISOLATION isolated '* ]]; then
  fail 'interactive and isolated sessions must not be reported'
fi
pass 'audit recognizes harness surfaces, canonical claims and linked clones'
set +e
out=$(AUDIT_HIDE_CWD=1 FM_HOME="$home" PATH="$case_dir/bin:$PATH" bash "$ROOT/bin/fm-slot-audit.sh")
status=$?
set -e
expect_code 1 "$status" 'unreadable cwd cannot report clean'
assert_contains "$out" 'cannot-read-cwd task=native' 'missing cwd sources report an explicit error'
pass 'audit reports unavailable cwd sources' 
cleanup_workers
: > "$case_dir/pids"
: > "$case_dir/rows"
rm "$other/state/second.meta"
# Pin the lease scan to an empty pool so a host Treehouse cannot decide the clean verdict.
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$case_dir/bin/treehouse"
chmod +x "$case_dir/bin/treehouse"
set +e
out=$(FM_HOME="$home" PATH="$case_dir/bin:$PATH" bash "$ROOT/bin/fm-slot-audit.sh")
status=$?
set -e
expect_code 0 "$status" 'a single claimant and no escaped workers is clean'
[ -z "$out" ] || fail "clean audit emitted output: $out"
pass 'audit converges to clean after conflicting record and workers are removed'
cat > "$case_dir/bin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "status --json" ] || exit 1
case "$PWD:${AUDIT_STATUS_MODE:-ok}" in
  */demo:failed) exit 1 ;;
  */demo:invalid) printf 'invalid json\n'; exit 0 ;;
esac
printf '[{"name":"1","path":"%s","status":"leased","lease_holder":"fm-held:parked-holder"},{"name":"2","path":"/x/2/r","status":"leased","lease_holder":"someone-else"}]\n' "$AUDIT_FIXTURE/pool/1/repo"
SH
chmod +x "$case_dir/bin/treehouse"
mkdir -p "$case_dir/no-jq"
for tool in bash dirname uname mkdir grep cut sort awk tr cat; do
  ln -s "$(command -v "$tool")" "$case_dir/no-jq/$tool"
done
ln -s "$case_dir/bin/ps" "$case_dir/no-jq/ps"
ln -s "$case_dir/bin/treehouse" "$case_dir/no-jq/treehouse"
set +e
out=$(FM_HOME="$home" PATH="$case_dir/no-jq" "$(command -v bash)" "$ROOT/bin/fm-slot-audit.sh")
status=$?
set -e
expect_code 1 "$status" 'missing jq cannot report clean when treehouse is present'
assert_contains "$out" 'AUDIT_ERROR held-lease-scan-unavailable jq-missing' 'missing jq reports an explicit scan error'
pass 'audit reports an unavailable held-lease dependency'
command -v jq >/dev/null 2>&1 || { echo "ok - skipped held-lease report: jq is not installed"; exit 0; }
set +e
out=$(FM_HOME="$home" PATH="$case_dir/bin:$PATH" bash "$ROOT/bin/fm-slot-audit.sh")
status=$?
set -e
expect_code 1 "$status" 'a held-slot lease is reported'
assert_contains "$out" "HELD_LEASE $slot fm-held:parked-holder treehouse return '$slot'" 'the lease line carries the holder and the exact manual return command'
assert_not_contains "$out" "someone-else" 'a lease without the fm-held label is not reported'
pass 'audit reports held-slot leases with the exact manual return command'
mkdir -p "$home/projects/working"
for mode in failed invalid; do
  set +e
  out=$(AUDIT_STATUS_MODE="$mode" FM_HOME="$home" PATH="$case_dir/bin:$PATH" bash "$ROOT/bin/fm-slot-audit.sh")
  status=$?
  set -e
  expect_code 1 "$status" "a $mode project query cannot report clean"
  case "$mode" in
    failed) reason=status-failed ;;
    invalid) reason=invalid-status ;;
  esac
  assert_contains "$out" "AUDIT_ERROR held-lease-scan-unavailable $reason $home/projects/demo" "a $mode query identifies the unavailable project"
  assert_contains "$out" "HELD_LEASE $slot fm-held:parked-holder treehouse return '$slot'" 'other project leases are still reported'
done
pass 'audit reports failed and malformed project queries without losing sibling leases'
