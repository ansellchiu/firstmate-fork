#!/usr/bin/env bash
# Live driver: real bin/fm-remote-job-reap-orphans.sh and bin/fm-teardown.sh
# against a disposable lab home, with TERM-ignoring fm-watch-arm.sh processes.
set -u
REPO=$PWD
T=${TMPDIR:-/tmp}; T=${T%/}
LAB=$(mktemp -d "$T/fm-lab.XXXXXX"); "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SIB=$(mktemp -d "$T/fm-sibling-home.XXXXXX"); mkdir -p "$SIB/state"
GONE=$(mktemp -d "$T/fm-gone-home.XXXXXX"); rmdir "$GONE"
OUTSIDE_BASE="$REPO/.lab-outside-tmp"; mkdir -p "$OUTSIDE_BASE"
echo "lab home      : $LAB"
echo "sibling home  : $SIB (exists)"
echo "gone home     : $GONE (never exists)"
mkroot() { # <base>
  local d; d=$(mktemp -d "$1/fm-pi-watch-extension.live.XXXXXX"); mkdir -p "$d/bin"
  cat > "$d/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM INT
end=$((SECONDS + 240))
while [ "$SECONDS" -lt "$end" ]; do sleep 0.2; done
SH
  chmod +x "$d/bin/fm-watch-arm.sh"; printf '%s\n' "$d"; }
launch() { # <home|-> <root>
  if [ "$1" = - ]; then env -u FM_HOME nohup "$2/bin/fm-watch-arm.sh" --restart >/dev/null 2>&1 &
  else env FM_HOME="$1" nohup "$2/bin/fm-watch-arm.sh" --restart >/dev/null 2>&1 &
  fi; echo $!; }
A=$(mkroot "$T"); B=$(mkroot "$T"); C=$(mkroot "$T"); D=$(mkroot "$T"); F=$(mkroot "$T"); G=$(mkroot "$OUTSIDE_BASE")
PA=$(launch "$LAB" "$A"); PB=$(launch "$SIB" "$B"); PC=$(launch "$LAB" "$C"); PD=$(launch - "$D"); PF=$(launch "$GONE" "$F"); PG=$(launch "$GONE" "$G")
sleep 2; echo "before prune: $(for p in $PA $PB $PC $PD $PF $PG; do kill -0 $p 2>/dev/null && printf "%s:alive " $p || printf "%s:gone " $p; done)"
rm -rf "$A" "$B" "$D" "$F" "$G"   # prune every code root except C
cat <<EOF
arms launched (code root pruned unless noted):
  A pid=$PA FM_HOME=lab        root under TMPDIR            -> expect REAPED
  B pid=$PB FM_HOME=sibling    root under TMPDIR            -> expect kept (sibling home)
  C pid=$PC FM_HOME=lab        root STILL EXISTS            -> expect kept
  D pid=$PD no FM_HOME         root under TMPDIR            -> expect kept (unattributable)
  F pid=$PF FM_HOME=gone dir   root under TMPDIR            -> expect REAPED (fixture space)
  G pid=$PG FM_HOME=gone dir   root outside TMPDIR and lab  -> expect kept
EOF
alive() { for p in "$@"; do if kill -0 "$p" 2>/dev/null; then printf '%s:alive ' "$p"; else printf '%s:gone ' "$p"; fi; done; echo; }
echo; echo "== 1. reaper --dry-run with FM_HOME=lab"
FM_HOME="$LAB" "$REPO/bin/fm-remote-job-reap-orphans.sh" --dry-run; echo "rc=$?"
echo "after dry-run: $(alive $PA $PB $PC $PD $PF $PG)"
echo; echo "== 2. reaper with FM_HOME unset (arm pass must do nothing)"
env -u FM_HOME "$REPO/bin/fm-remote-job-reap-orphans.sh"; echo "rc=$?"
echo "after unset run: $(alive $PA $PB $PC $PD $PF $PG)"
echo; echo "== 3. real fm-teardown.sh task-x1 --force in the lab home (FM_HOME=lab)"
FAKE="$LAB/fakebin"; mkdir -p "$FAKE"
for t in treehouse tmux gh-axi gh no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"; chmod +x "$FAKE/$t"; done
git init -q --bare "$LAB/origin.git"; git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/seed" 2>/dev/null
git -C "$LAB/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base; git -C "$LAB/seed" push -q origin main; rm -rf "$LAB/seed"
git clone -q "$LAB/origin.git" "$LAB/projects/proj"; git -C "$LAB/projects/proj" remote set-head origin main 2>/dev/null
git -C "$LAB/projects/proj" worktree add -q -b fm/task-x1 "$LAB/wt" main
git -C "$LAB/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
touch "$LAB/state/.last-watcher-beat"
printf '%s\n' window=firstmate:fm-task-x1 endpoint_task_id=task-x1 "worktree=$LAB/wt" "project=$LAB/projects/proj" kind=ship mode=local-only spawn_gen=lab-task-x1 > "$LAB/state/task-x1.meta"
FM_HOME="$LAB" "$REPO/bin/fm-receipt.sh" write-landing --task task-x1 --project-fallback proj --commit-sha 1111111111111111111111111111111111111111 --sha-source 'lab fixture' >/dev/null
FM_HOME="$LAB" PATH="$FAKE:$PATH" "$REPO/bin/fm-teardown.sh" task-x1 --force > "$LAB/td.out" 2> "$LAB/td.err"; echo "teardown rc=$?"
echo "-- teardown stderr lines from the sweep:"; grep -E 'watcher arm|remote job worker' "$LAB/td.err" || echo "(none)"
echo "-- teardown stdout tail:"; tail -3 "$LAB/td.out"
echo "after teardown: $(alive $PA $PB $PC $PD $PF $PG)"
echo; echo "== 4. cleanup of kept fixture arms"
for p in $PB $PC $PD $PG; do kill -KILL "$p" 2>/dev/null; done; sleep 0.3
echo "after cleanup: $(alive $PA $PB $PC $PD $PF $PG)"
rm -rf "$LAB" "$SIB" "$C" "$OUTSIDE_BASE"
echo "remaining live fixture arms: $(ps -u "$(id -u)" -ww -o pid=,command= | grep "[f]m-pi-watch-extension.live" | grep -vc grep)"
