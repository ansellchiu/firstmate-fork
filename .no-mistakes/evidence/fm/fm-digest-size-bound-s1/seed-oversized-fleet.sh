#!/usr/bin/env bash
# seed-oversized-fleet.sh <lab-home>: reproduce the ~220 KB digest shape from the RCA
# (146 orphan logs, full metas, an 11 KB secondmate row, held-row essays, many open decisions).
set -eu
cd "$1"; H=$PWD; S=state; D=data
printf '# Captain\n\nCaptain identity: LAB-CAPTAIN-ZEPHYR (call them Zephyr). Prefers terse updates.\n' > $D/captain.md
for i in $(seq 1 120); do printf -- '- learning %03d: keep digests small and bounded so tokens are not wasted\n' $i; done > $D/learnings.md
pad=$(awk 'BEGIN{while(i++<1050) printf "charter-word "}')
{ printf -- '- quartermaster — scope: %s\n' "$pad"; for i in $(seq 1 30); do printf -- '- mate-%02d — scope: owns lane %02d %s\n' $i $i "$(awk 'BEGIN{while(i++<30) printf "lane-detail "}')"; done; } > $D/secondmates.md
for i in $(seq 1 60); do printf -- '- proj-%02d [no-mistakes] - project %02d %s\n' $i $i "$(awk 'BEGIN{while(i++<30) printf "desc "}')"; done > $D/projects.md
essay=$(awk 'BEGIN{printf "essay"; while(i++<120) printf " padding-word"}')
printf 'manual\n' > config/backlog-backend
{ printf '# Backlog\n\n## Queued\n'
  for i in $(seq 1 60); do printf -- '- [ ] held-%02d - Held task %02d (repo: firstmate) (kind: ship) (hold: waiting on PR (#%d) %s) (hold-kind: captain)\n' $i $i $i "$essay"; done
  printf '\n## In flight\n'
  for i in $(seq 1 10); do printf -- '- [ ] flight-%02d - In flight %02d (hold: %s)\n' $i $i "$essay"; done
} > $D/backlog.md
for i in $(seq 1 40); do
  { printf 'window=fm-lab:t%02d\nkind=ship\nharness=claude\nmodel=opus\nbackend=tmux\nworktree=%s/projects/firstmate-t%02d\npr=https://example.com/pull/%d\n' $i "$H" $i $i
    for k in $(seq 1 25); do printf 'extra_key_%02d=%s\n' $k "$(awk 'BEGIN{while(i++<8) printf "value "}')"; done; } > $S/task-$i.meta
  { for l in $(seq 1 5); do printf 'working: task %02d step %d with padding to look like a real status line\n' $i $l; done
    printf 'needs-decision [key=k%02d]: decide option set %02d with enough padding words to fill the per-item budget toward the section ceiling quickly\n' $i $i; } > $S/task-$i.status
done
for i in $(seq 1 146); do
  { for l in $(seq 1 5); do printf 'working: retired orphan %03d step %d with padding to look like a real status line from history\n' $i $l; done
    for l in $(seq 1 6); do printf 'done: retired orphan %03d finished after many lines of wake-event history and long notes\n' $i; done; } > $S/retired-$i.status
  [ $i -le 4 ] || touch -t 202601010000 $S/retired-$i.status
done
