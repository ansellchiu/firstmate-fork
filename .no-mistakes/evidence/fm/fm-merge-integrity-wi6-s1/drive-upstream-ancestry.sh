#!/usr/bin/env bash
# Live driver: runs the real `upstream-ancestry` job step from .github/workflows/ci.yml
# (extracted verbatim from the YAML) against the real bin/fm-upstream.sh in a checkout
# made the way actions/checkout@v6 with fetch-depth 0 makes it, using disposable local
# origin and upstream repositories.
set -u
WT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-ancestry.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
ruby -ryaml -e 'j=YAML.load_file(ARGV[0]).fetch("jobs").fetch("upstream-ancestry"); s=j["steps"].find{|x| x.key?("run")}; File.write(ARGV[1], s["run"])' "$WT/.github/workflows/ci.yml" "$T/step.sh"
echo "== job step under test (extracted from ci.yml) =="; cat "$T/step.sh"

g() { git -C "$T/work" "$@"; }
git clone -q --no-local "$WT" "$T/seed"
git -C "$T/seed" checkout -q -B main HEAD
git clone -q --bare "$T/seed" "$T/upstream.git"
git clone -q --bare "$T/seed" "$T/origin.git"
for r in upstream origin; do git -C "$T/$r.git" symbolic-ref HEAD refs/heads/main; git -C "$T/$r.git" for-each-ref --format='%(refname)' refs/heads | grep -vx refs/heads/main | xargs -r -n1 git -C "$T/$r.git" update-ref -d; done
git clone -q "$T/origin.git" "$T/work"
git clone -q "$T/upstream.git" "$T/uwork"

run_job() { # $1 label, $2 FM_UPSTREAM_URL
  local label=$1 url=$2 co="$T/runner-$1" rc
  mkdir -p "$co" "$T/rt-$1"
  # what actions/checkout@v6 does with fetch-depth: 0
  git -C "$co" init -q
  git -C "$co" remote add origin "$T/origin.git"
  git -C "$co" fetch -q --prune --no-recurse-submodules origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
  git -C "$co" checkout -q --force -B main refs/remotes/origin/main
  echo; echo "=================== scenario: $label  (FM_UPSTREAM_URL=$url) ==================="
  ( cd "$co" && FM_UPSTREAM_URL="$url" RUNNER_TEMP="$T/rt-$1" bash --noprofile --norc -eo pipefail "$T/step.sh" ) 2>&1
  rc=$?
  echo "---- job step exit status: $rc"
}

# 1. current: private commit on origin, upstream unchanged
echo private > "$T/work/PRIVATE-NOTE.txt"; g add PRIVATE-NOTE.txt; g commit -qm "private: note"; g push -q origin main
run_job current "$T/upstream.git"

# 2. diverged: upstream gains a genuinely new commit
echo upstream > "$T/uwork/UPSTREAM-FEATURE.txt"; git -C "$T/uwork" add UPSTREAM-FEATURE.txt; git -C "$T/uwork" commit -qm "upstream: feature"; git -C "$T/uwork" push -q origin main
run_job diverged "$T/upstream.git"

# 3. not-compared: upstream URL unreachable
run_job not-compared "$T/does-not-exist.git"

# 4. topology refusal: upstream URL is origin itself -> diagnostics must still print
run_job same-repo-refusal "$T/origin.git"

# 5. contained: origin cherry-picks upstream's one new commit (patch-equivalent)
g remote add upstream "$T/upstream.git"; g fetch -q upstream
g cherry-pick upstream/main >/dev/null || { echo "fixture cherry-pick failed"; exit 1; }; g push -q origin main
run_job contained "$T/upstream.git"

# 6. ancestry-gap: upstream adds two commits; a sync branch merges upstream, and main
#    lands it as a squash, dropping the upstream parent (the hand-merge failure mode)
for n in two three; do echo "$n" > "$T/uwork/UPSTREAM-$n.txt"; git -C "$T/uwork" add .; git -C "$T/uwork" commit -qm "upstream: $n"; done; git -C "$T/uwork" push -q origin main
g fetch -q upstream
g checkout -q -b sync-upstream main
g merge -q --no-ff -X theirs upstream/main -m "reconcile upstream" >/dev/null || { echo "fixture merge failed"; exit 1; }
g push -q origin sync-upstream
g checkout -q main; g merge -q --squash sync-upstream >/dev/null; g commit -qm "squash upstream reconciliation"; g push -q origin main
run_job ancestry-gap "$T/upstream.git"
