#!/usr/bin/env bash
# Drives the WI-5 documented /updatefirstmate steps against a disposable fork world.
set -u
REPO=$1
UP="$REPO/bin/fm-upstream.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/wi5.XXXXXX"); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
mkdir -p "$T/home/state" "$T/home/data"
git init -q --bare "$T/upstream.git"; git -C "$T/upstream.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/upstream.git" "$T/pub" 2>/dev/null
echo v1 > "$T/pub/core.txt"; mkdir -p "$T/pub/docs"; echo '{ "version": 1, "entries": [] }' > "$T/pub/docs/private-divergence.json"
git -C "$T/pub" add -A; git -C "$T/pub" commit -qm fork-point; git -C "$T/pub" push -q origin main
git clone -q --bare "$T/upstream.git" "$T/origin.git"; git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin.git" "$T/main"; git -C "$T/main" remote add upstream "$T/upstream.git"; git -C "$T/main" remote set-url --push upstream DISABLED
echo priv > "$T/main/private.txt"; git -C "$T/main" add -A; git -C "$T/main" commit -qm private-change; git -C "$T/main" push -q origin main
for i in 1 2 3; do echo "pub$i" > "$T/pub/pub$i.txt"; git -C "$T/pub" add -A; git -C "$T/pub" commit -qm "public-$i"; done; git -C "$T/pub" push -q origin main
run() { echo "\$ fm-upstream.sh $*"; (cd "$T/main" && FM_ROOT_OVERRIDE="$T/main" FM_HOME="$T/home" "$UP" "$@" 2>&1); local rc=$?; echo "[exit $rc]"; return $rc; }

echo "=== S1: check on a diverged fork, then reconcile (step 2) ==="
run check | grep -E 'upstream-status|exit'
out=$(run reconcile --branch fm-reconcile-test --worktree "$T/rwt"); echo "$out" | grep -E '^reconcile|merge-method|merged-commits|reconcile-upstream|private-commits|exit'
MERGED=$(echo "$out" | sed -n 's/^reconcile-merged-commits: //p')
UPTIP=$(echo "$out" | sed -n 's/^reconcile-upstream-tip: //p'); [ -n "$UPTIP" ] || UPTIP=$(git -C "$T/main" rev-parse upstream/main)
HEADSHA=$(git -C "$T/rwt" rev-parse HEAD)
git -C "$T/rwt" push -q origin fm-reconcile-test

echo "=== S2: documented pre-approval carried check, run literally from the reconcile worktree ==="
echo "\$ bin/fm-upstream.sh carried $HEADSHA \"\$(git rev-parse origin/main)\" $UPTIP"
c=$(cd "$T/rwt" && FM_ROOT_OVERRIDE="$T/main" FM_HOME="$T/home" "$UP" carried "$HEADSHA" "$(git rev-parse origin/main)" "$UPTIP" 2>&1); echo "$c"; echo "[exit $?]"
CC=$(echo "$c" | sed -n 's/^upstream-carried-commits: //p')
echo "compare: upstream-carried-commits=$CC reconcile-merged-commits=$MERGED -> $([ "$CC" = "$MERGED" ] && echo EQUAL || echo MISMATCH)"

echo "=== S3 (adversarial): ref name instead of sha, as the doc warns ==="
(cd "$T/rwt" && FM_ROOT_OVERRIDE="$T/main" FM_HOME="$T/home" "$UP" carried "$HEADSHA" origin/main "$UPTIP" 2>&1); echo "[exit $?]"

echo "=== S4 (adversarial): branch rewritten (squashed) on its way to the PR -> carried 0 ==="
git -C "$T/main" fetch -q origin
git -C "$T/main" worktree add -q -b rewritten "$T/rw2" origin/main; git -C "$T/rw2" merge -q --squash "$HEADSHA" >/dev/null; git -C "$T/rw2" commit -qm squashed-reconcile
RW=$(git -C "$T/rw2" rev-parse HEAD)
(cd "$T/main" && FM_ROOT_OVERRIDE="$T/main" FM_HOME="$T/home" "$UP" carried "$RW" "$(git rev-parse origin/main)" "$UPTIP" 2>&1); echo "[exit $?]"

echo "=== S5: reconciliation landed as squash -> check reports ancestry-gap; reconcile refuses exit 7 ==="
git -C "$T/rw2" push -q origin HEAD:main; git -C "$T/main" pull -q --ff-only origin main
run check | grep -E 'upstream-status|ancestry-gap|exit'
run reconcile --branch fm-reconcile-2 --worktree "$T/rwt2" | grep -E '^reconcile|exit|ancestry'

echo "=== S6: step 2a repair-ancestry -> repair: ready, repair-tree unchanged; land as merge commit; check again ==="
out=$(run repair-ancestry --branch fm-repair --worktree "$T/rep"); echo "$out"
RB=$(git -C "$T/main" rev-parse fm-repair)
echo "repair branch parents: $(git -C "$T/main" rev-list --parents -n1 "$RB")"
echo "files changed vs origin/main: $(git -C "$T/main" diff --name-only origin/main "$RB" | wc -l | tr -d ' ')"
echo "carried on repair PR: $(cd "$T/main" && FM_ROOT_OVERRIDE="$T/main" FM_HOME="$T/home" "$UP" carried "$RB" "$(git rev-parse origin/main)" "$UPTIP" 2>&1 | head -1)"
git -C "$T/main" merge -q --no-ff -m "Merge repair (merge commit)" "$RB"; git -C "$T/main" push -q origin main
run check | grep -E 'upstream-status|exit'

echo "=== S7: new genuinely public commit after repair -> diverged (step 2) ==="
echo pub4 > "$T/pub/pub4.txt"; git -C "$T/pub" add -A; git -C "$T/pub" commit -qm public-4; git -C "$T/pub" push -q origin main
run check | grep -E 'upstream-status|exit'
