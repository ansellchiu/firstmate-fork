#!/usr/bin/env bash
# Lab setup: real tmux server on the lab's private socket, real claude panes per task record.
set -u
LAB=$1; PROJ="$LAB/proj"; export TMUX_TMPDIR="$LAB/tmux"
tmux -L fm-lab -f /dev/null new-session -d -s fmses -n init -c "$PROJ"
shift
for spec in "$@"; do
  IFS=: read -r id h m <<<"$spec"; wt="$LAB/wt-$id"
  git -C "$PROJ" worktree add -q -b "task-$id" "$wt"
  mkdir -p "$LAB/data/$id"; printf '# Task\n## Captain'"'"'s intent\nlab task %s\n\n## Firstmate spec\nidle\n' "$id" > "$LAB/data/$id/brief.md"
  printf 'window=fmses:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=%s\nkind=ship\nmode=no-mistakes\nyolo=off\ntasktmp=/tmp/fm-%s\nmodel=%s\neffort=default\nbackend=tmux\n' "$id" "$id" "$wt" "$PROJ" "$h" "$id" "$m" > "$LAB/state/$id.meta"
  tmux -L fm-lab new-window -d -t fmses -n "fm-$id" -c "$wt"; sleep 0.5; tmux -L fm-lab send-keys -t "fmses:fm-$id" "claude" Enter
done
