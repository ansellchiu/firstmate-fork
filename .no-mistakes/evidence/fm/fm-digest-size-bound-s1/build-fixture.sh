#!/usr/bin/env bash
# build-fixture.sh <lab-home> : populate a lab FM_HOME resembling the RCA's 220 KB digest
set -eu
H=$1
pad() { awk -v n="$1" -v w="$2" 'BEGIN{while(i++<n) printf "%s ", w}'; }
# captain identity
printf '# Captain\n\nCaptain identity: LAB-CAPTAIN-ZEBRA (test fixture). Prefers terse updates.\n' > "$H/data/captain.md"
# 146 orphan status logs, 5 lines each, ~800 B each; 3 recent, rest aged
for i in $(seq 1 146); do
  for s in 1 2 3 4; do printf 'working: retired-%s step %s %s\n' "$i" "$s" "$(pad 14 orphan-pad)"; done > "$H/state/retired-$i.status"
  printf 'done: retired-%s finished\n' "$i" >> "$H/state/retired-$i.status"
  [ "$i" -le 3 ] || touch -t 202601010000 "$H/state/retired-$i.status"
done
# 15 live tasks with full meta records and long status logs; 40 open decisions on task live-1
for i in $(seq 1 15); do
  { printf 'window=fm-lab:live-%s\nkind=ship\nharness=claude\nmodel=opus\nbackend=tmux\nworktree=%s/projects/p%s\npr=https://example.com/pull/%s\n' "$i" "$H" "$i" "$i"
    printf 'spawn_gen=%s\nbrief=%s\nnotes=%s\n' "$i" "$(pad 60 brief-word)" "$(pad 60 note-word)"; } > "$H/state/live-$i.meta"
  for s in $(seq 1 8); do printf 'working: live-%s step %s %s\n' "$i" "$s" "$(pad 20 tail-word)"; done > "$H/state/live-$i.status"
done
for k in $(seq 1 40); do printf 'needs-decision [key=decision-%02d]: %s\n' "$k" "$(pad 30 choose-word)" >> "$H/state/live-1.status"; done
# registry: one 11 KB secondmate row + projects
{ printf -- '- quartermaster — scope: %s\n' "$(pad 900 charter-word)"; for i in 1 2 3; do printf -- '- mate-%s — scope: small\n' "$i"; done; } > "$H/data/secondmates.md"
for i in $(seq 1 30); do printf -- '- proj-%s [no-mistakes] - %s\n' "$i" "$(pad 25 project-desc)"; done > "$H/data/projects.md"
# backlog: manual backend, held rows with 2 KB hold reasons
printf 'manual\n' > "$H/config/backlog-backend"
{ printf '# Backlog\n\n## Queued\n'
  for i in $(seq 1 12); do printf -- '- [ ] held-%s - Held task %s (hold: waiting on captain %s) (hold-kind: captain)\n' "$i" "$i" "$(pad 180 essay-word)"; done
  for i in $(seq 1 10); do printf -- '- [ ] ready-%s - Ready task %s\n' "$i" "$i"; done
  printf '\n## In flight\n'
  for i in $(seq 1 5); do printf -- '- [ ] flight-%s - Flight (hold: paused %s)\n' "$i" "$(pad 120 flight-word)"; done
} > "$H/data/backlog.md"
