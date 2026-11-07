#!/usr/bin/env bash
# usage: run-case.sh <driverdir> <casename> <worktree> <prompt>
set -u
D=$1; C=$2; WT=$3; PROMPT=$4
P="$D/$C/project"; mkdir -p "$P/.agents/skills/quota-array-dispatch" "$D/$C/bin"
cp "$WT/.agents/skills/quota-array-dispatch/SKILL.md" "$P/.agents/skills/quota-array-dispatch/SKILL.md"
cp "$D/fake-quota-axi" "$D/$C/bin/quota-axi"
[ -d "$D/$C/home" ] && cp -R "$D/$C/home/." "$P/"
: > "$D/$C/calls"
cd "$P" && PATH="$D/$C/bin:$PATH" QUOTA_AXI_CALLS="$D/$C/calls" QUOTA_AXI_TOON="$D/$C/toon" QUOTA_AXI_JSON="$D/$C/json" \
  pi --print --approve --no-session --no-context-files --no-extensions --no-skills --skill .agents/skills --tools bash \
  --model openai-codex/gpt-5.6-sol --thinking high "$PROMPT" < /dev/null > "$D/$C/out" 2>&1
echo "rc=$?" >> "$D/$C/out"
