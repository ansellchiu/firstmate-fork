#!/usr/bin/env bash
# Live: real bin/fm-teardown.sh <task> --standdown on a lab home whose ship task has pr= + stamped status.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TMUXD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB"); export TMUX_TMPDIR="$TMUXD"; unset TMUX
trap 'tmux kill-server 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
mkdir -p "$LAB/shim"; printf '#!/bin/sh\nexit 0\n' > "$LAB/shim/treehouse"; chmod +x "$LAB/shim/treehouse"; export PATH="$LAB/shim:$PATH"
task=fm-dispatch-model-id-validation-s1; STATE="$LAB/state"; proj="$LAB/projects/demo"; wt="$LAB/wt"
git init -q -b main "$proj"; git -C "$proj" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
git -C "$proj" worktree add -q -b "$task" "$wt" main
tmux new-session -d -s lab -n "fm-$task" "sleep 3600"
printf 'window=lab:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nspawn_gen=1\ndispatch_base=%s\npr=https://github.com/ansellchiu/firstmate-fork/pull/33\n' \
  "$task" "$task" "$wt" "$proj" "$(git -C "$wt" rev-parse HEAD)" > "$STATE/$task.meta"
printf 'needs-decision [at=1791218000] [key=ci-1]: CI choice\nresolved [at=1791218932] [key=ci-1]: answered\n' > "$STATE/$task.status"
env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" "$task" --standdown; echo "teardown rc=$?"
echo "meta present? $([ -f "$STATE/$task.meta" ] && echo yes || echo NO); status present? $([ -f "$STATE/$task.status" ] && echo yes || echo NO)"
