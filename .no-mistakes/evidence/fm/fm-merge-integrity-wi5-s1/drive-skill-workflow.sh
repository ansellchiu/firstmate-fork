#!/usr/bin/env bash
# Drives the documented /updatefirstmate steps 2 and 2a against the real bin/fm-upstream.sh
# in a disposable fork world (bare public upstream, bare private origin, working clone).
set -u
ROOT=$1; T=$(mktemp -d "${TMPDIR:-/tmp}/fm-wi5.XXXXXX"); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
U="$ROOT/bin/fm-upstream.sh"
world() { local w=$T/$1; mkdir -p $w/home/state $w/home/data; touch $w/home/state/.last-watcher-beat
  git init -q --bare $w/upstream.git; git -C $w/upstream.git symbolic-ref HEAD refs/heads/main
  git clone -q $w/upstream.git $w/pub 2>/dev/null; echo v1 > $w/pub/AGENTS.md; echo core > $w/pub/core.txt
  mkdir -p $w/pub/docs; echo '{ "version": 1, "entries": [] }' > $w/pub/docs/private-divergence.json
  git -C $w/pub add -A; git -C $w/pub commit -qm fork-point; git -C $w/pub push -q origin main
  git clone -q --bare $w/upstream.git $w/origin.git; git -C $w/origin.git symbolic-ref HEAD refs/heads/main
  git clone -q $w/origin.git $w/main; git -C $w/main remote add upstream $w/upstream.git
  git -C $w/main remote set-url --push upstream DISABLED; echo $w; }
pub() { git -C $1/pub pull -q origin main; echo "$3" > $1/pub/$2; git -C $1/pub add -A; git -C $1/pub commit -qm "public $2"; git -C $1/pub push -q origin main; }
priv() { echo "$3" > $1/main/$2; git -C $1/main add -A; git -C $1/main commit -qm "private $2"; git -C $1/main push -q origin main; }
fm() { local w=$1; shift; (cd $w/main && FM_ROOT_OVERRIDE=$w/main FM_HOME=$w/home "$U" "$@" 2>&1); echo "[exit $?]"; }
h() { printf '\n===== %s =====\n' "$*"; }

W=$(world A); priv $W private.txt mine; pub $W docs/u1.txt one; pub $W docs/u2.txt two
h "A1 step 1: check on a world with 2 new public commits"; fm $W check | grep -E '^(upstream-status|upstream-new|reconcile-required)|exit'
h "A2 step 2: reconcile"; OUT=$(fm $W reconcile); echo "$OUT" | grep -E '^(reconcile|reconcile-branch|reconcile-merged-commits|reconcile-upstream|merge-method-required|private-commits|active-checkout|pr-target)|exit'
BR=$(echo "$OUT" | sed -n 's/^reconcile-branch: //p'); N=$(echo "$OUT" | sed -n 's/^reconcile-merged-commits: //p')
UT=$(echo "$OUT" | sed -n 's/^reconcile-upstream-tip: //p'); [ -n "$UT" ] || UT=$(git -C $W/main rev-parse upstream/main)
git -C $W/main push -q origin "$BR"; HEADSHA=$(git -C $W/main rev-parse "$BR")
h "A3 documented pre-approval check, verbatim form: carried <pr-head> \"\$(git rev-parse origin/main)\" <upstream-tip>"
(cd $W/main && FM_ROOT_OVERRIDE=$W/main FM_HOME=$W/home "$U" carried "$HEADSHA" "$(git rev-parse origin/main)" "$UT"); echo "[exit $?] reconcile-merged-commits was: $N"
h "A4 caution in the doc: passing the ref name instead"; (cd $W/main && FM_ROOT_OVERRIDE=$W/main FM_HOME=$W/home "$U" carried "$HEADSHA" origin/main "$UT"); echo "[exit $?]"
h "A5 adversarial: branch rewritten (squashed) on its way to the PR"
git -C $W/main checkout -q -b rewritten origin/main; git -C $W/main merge -q --squash "$BR" >/dev/null; git -C $W/main commit -qm rewritten
RW=$(git -C $W/main rev-parse HEAD); git -C $W/main checkout -q main
(cd $W/main && FM_ROOT_OVERRIDE=$W/main FM_HOME=$W/home "$U" carried "$RW" "$(git rev-parse origin/main)" "$UT"); echo "[exit $?]"
h "A6 land as a merge commit, then check"
git -C $W/main fetch -q origin; git -C $W/main checkout -q -b land origin/main; git -C $W/main merge -q --no-ff "$BR" -m "Merge reconcile PR"
git -C $W/main push -q origin land:main; git -C $W/main checkout -q main; git -C $W/main pull -q origin main
fm $W check | grep -E '^upstream-status|exit'

W=$(world B); priv $W private.txt mine; pub $W docs/u1.txt one; pub $W docs/u2.txt two
OUT=$(fm $W reconcile); BR=$(echo "$OUT" | sed -n 's/^reconcile-branch: //p')
h "B1 adversarial: reconcile PR landed by SQUASH, then step 1 check"
git -C $W/main merge -q --squash "$BR" >/dev/null; git -C $W/main commit -qm "squash reconcile"; git -C $W/main push -q origin main
fm $W check | grep -E '^(upstream-status|upstream-ancestry-gap|ancestry-repair|reconcile-required)|exit'
h "B2 adversarial: run reconcile while status is ancestry-gap (doc: refuses with exit 7)"; fm $W reconcile | grep -E '^reconcile|exit'
h "B3 step 2a: repair-ancestry"; OUT=$(fm $W repair-ancestry); echo "$OUT" | grep -E '^(repair|active-checkout|merge-method)|exit'
RB=$(echo "$OUT" | sed -n 's/^repair-branch: //p'); git -C $W/main push -q origin "$RB"
h "B4 PR against origin: expected zero changed files"; echo "changed files: $(git -C $W/main diff --name-only origin/main "$RB" | wc -l | tr -d ' ')"
git -C $W/main checkout -q -b land origin/main; git -C $W/main merge -q --no-ff "$RB" -m "Merge repair PR"
git -C $W/main push -q origin land:main; git -C $W/main checkout -q main; git -C $W/main pull -q origin main
h "B5 step 2a: check again after merge-commit landing"; fm $W check | grep -E '^upstream-status|exit'
h "B6 new public commit after repair: check routes to diverged (step 2)"; pub $W docs/u3.txt three; fm $W check | grep -E '^(upstream-status|upstream-new)|exit'
