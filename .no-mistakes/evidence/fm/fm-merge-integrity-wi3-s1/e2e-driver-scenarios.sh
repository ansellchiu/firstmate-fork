# Appended to the helper prefix of tests/fm-pr-merge.test.sh. Real fm-pr-merge.sh,
# real fm-upstream.sh pr-guard/pr-landed against local git repos; only gh is mocked.
set +e
W=$(mktemp -d "${TMPDIR:-/tmp}/nm-e2e-world.XXXXXX")
git init -q --bare -b main "$W/upstream.git"; git init -q --bare -b main "$W/origin.git"
git clone -q "$W/upstream.git" "$W/pub" 2>/dev/null
( cd "$W/pub" && git checkout -q -b main && echo a > a && git add a && git commit -qm base && git push -q origin main )
git -C "$W/origin.git" fetch -q "$W/upstream.git" main:main
( cd "$W/pub" && echo u1 > u1 && git add u1 && git commit -qm "upstream 1" && echo u2 > u2 && git add u2 && git commit -qm "upstream 2" && git push -q origin main )
UP_TIP=$(git -C "$W/upstream.git" rev-parse main)
# PR 69: reconcile branch = merge of public upstream into origin main
git clone -q "$W/origin.git" "$W/dev"
( cd "$W/dev" && git fetch -q "$W/upstream.git" main:up && git merge -q --no-ff -m "merge upstream" up && git push -q origin HEAD:refs/pull/69/head )
CARRY_HEAD=$(git -C "$W/origin.git" rev-parse refs/pull/69/head)
# PR 70: an ordinary feature that carries nothing
( cd "$W/dev" && git checkout -q -b feat origin/main && echo f > f && git add f && git commit -qm feature && git push -q origin HEAD:refs/pull/70/head )
CLEAR_HEAD=$(git -C "$W/origin.git" rev-parse refs/pull/70/head)
# The firstmate home: origin is the GitHub URL, rewritten to the local bare repo.
git clone -q "$W/origin.git" "$W/home-root"
git -C "$W/home-root" remote set-url origin https://github.com/example/repo
git -C "$W/home-root" remote add upstream "$W/upstream.git"
git -C "$W/home-root" remote set-url --push upstream no_push
# Network stand-in: only git fetch of https://github.com/example/repo is redirected to the local bare origin.
mkdir -p "$W/shim"; REAL_GIT=$(command -v git)
cat > "$W/shim/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = fetch ] && exec "$REAL_GIT" -c "url.$W/origin.git.insteadOf=https://github.com/example/repo" "\$@"; done
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/shim/git"
GITCFG="PATH=$W/shim:\$PATH"
echo "world: upstream tip $UP_TIP carry-head $CARRY_HEAD clear-head $CLEAR_HEAD"

drive() { # name head pr extra...
  local name=$1 head=$2 pr=$3; shift 3
  case " $DRIVE_ONLY " in "  "|*" $name "*) ;; *) return 0;; esac
  local c; c=$(make_case "$name"); mkdir -p "$c/wt"
  add_gh_mocks "$c" "$head"; : > "$c/gh-axi.log"
  # The guard command is the REAL bin/fm-upstream.sh, rooted at the fixture home.
  cat > "$c/fakebin/real-guard" <<SH
#!/usr/bin/env bash
exec env FM_ROOT_OVERRIDE="$W/home-root" $GITCFG "$ROOT/bin/fm-upstream.sh" "\$@"
SH
  chmod +x "$c/fakebin/real-guard"
  # A forge simulation: a successful --merge really lands a merge commit on origin main.
  mv "$c/fakebin/gh" "$c/fakebin/gh-mock"
  cat > "$c/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "pr merge" ] && [ "\${FM_E2E_LAND:-}" = 1 ]; then
  case " \$* " in *" --merge "*)
    t=\$(mktemp -d); git clone -q "$W/origin.git" "\$t/c" && git -C "\$t/c" fetch -q origin "refs/pull/\$3/head:pr" \
      && git -C "\$t/c" merge -q --no-ff -m "Merge PR \$3" pr && git -C "\$t/c" push -q origin HEAD:main; rm -rf "\$t";;
  esac
fi
exec "$c/fakebin/gh-mock" "\$@"
SH
  chmod +x "$c/fakebin/gh"
  FM_UPSTREAM_GUARD_CMD="$c/fakebin/real-guard" run_pr_merge "$c" task-x1 "https://github.com/example/repo/pull/$pr" "$@" >"$c/stdout" 2>"$c/stderr"
  local rc=$?
  echo "=== $name: fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/$pr $* -> exit $rc"
  echo "--- guard verdict (real pr-guard):"; "$c/fakebin/real-guard" pr-guard --repo-url https://github.com/example/repo --pr-ref "refs/pull/$pr/head" --head "$head" --base main 2>&1 | sed 's/^/    /'
  echo "--- stderr:"; sed 's/^/    /' "$c/stderr"
  echo "--- stdout (tail):"; tail -n3 "$c/stdout" | sed 's/^/    /'
  echo "--- gh pr merge calls:"; grep '^pr merge' "$c/gh.log" | sed 's/^/    /' || echo "    (none)"
  echo
}
drive e2e-carry-default "$CARRY_HEAD" 69
drive e2e-carry-squash "$CARRY_HEAD" 69 -- --squash
drive e2e-carry-rebase "$CARRY_HEAD" 69 -- --rebase
drive e2e-carry-auto-merge "$CARRY_HEAD" 69 -- --merge --auto
drive e2e-clear-default "$CLEAR_HEAD" 70
echo "### attended --auto --merge on a carried PR"
drive e2e-carry-attended-auto-merge "$CARRY_HEAD" 69 --attended-override -- --auto --merge
echo "### lost ancestry: forge mock reports merged but origin main never received the merge"
drive e2e-carry-merge-lost "$CARRY_HEAD" 69 -- --merge
echo "### landed ancestry: forge really creates the merge commit on origin main"
FM_E2E_LAND=1 drive e2e-carry-merge-landed "$CARRY_HEAD" 69 -- --merge
echo "origin main now: $(git -C "$W/origin.git" log --oneline -1 main); upstream tip ancestor? $(git -C "$W/origin.git" merge-base --is-ancestor "$UP_TIP" main && echo yes || echo no)"
echo "### unknown: public upstream unreachable"
git -C "$W/home-root" remote set-url upstream "$W/does-not-exist.git"
drive e2e-unknown-default "$CARRY_HEAD" 69
drive e2e-unknown-merge "$CARRY_HEAD" 69 -- --merge
rm -rf "$W"
