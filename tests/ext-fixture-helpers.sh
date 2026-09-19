#!/usr/bin/env bash
# tests/ext-fixture-helpers.sh - build synthetic firstmate extension packages.
#
# Source alongside tests/lib.sh:
#   # shellcheck source=tests/ext-fixture-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/ext-fixture-helpers.sh"
#
# The fixtures are generated rather than checked in so no synthetic SKILL.md
# joins the tracked documentation inventory and no deliberately broken `../`
# reference has to survive the repo's own link checks.
#
# fm_ext_fixture <dir> [name]           a healthy package: manifest, skill, one
#                                       command, a session-start hook, examples
# fm_ext_fixture_escape <dir> [name]    same, plus a SKILL.md reference that
#                                       escapes the package root
# fm_ext_fixture_requires <dir> <cap>   same, plus a capability requirement
# fm_ext_home <dir>                     a git-backed fake firstmate home

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_ext_fixture() {
  local dir=$1 name=${2:-hello-ext}
  mkdir -p "$dir/bin" "$dir/hooks" "$dir/examples"
  cat > "$dir/ext.json" <<JSON
{
  "schema": "firstmate.ext.v1",
  "name": "$name",
  "version": "1.0.0",
  "trigger": "load when config/$name.json opts the home in, and on any $name check wake",
  "commands": ["bin/fm-$name-report.sh"],
  "config": ["$name.json"],
  "state": ["$name"],
  "hooks": {"session-start": "hooks/session-start"},
  "configure": "bin/fm-$name-report.sh configure",
  "inherit": true
}
JSON
  cat > "$dir/SKILL.md" <<MD
---
name: $name
description: Synthetic fixture extension used to exercise the extension contract.
---

# $name

Reference a sibling file in this package: [notes](examples/notes.md).
Reference firstmate core as repo-root-relative text: bin/fm-ext.sh.
MD
  printf 'fixture notes\n' > "$dir/examples/notes.md"
  cat > "$dir/bin/fm-$name-report.sh" <<SH
#!/usr/bin/env bash
set -eu
case "\${1:-}" in
  configure) printf 'configured: %s\n' "\${2:-default}" ;;
  dependencies) exit 0 ;;
  *) printf 'report: %s\n' "$name" ;;
esac
SH
  chmod +x "$dir/bin/fm-$name-report.sh"
  cat > "$dir/hooks/session-start" <<SH
#!/usr/bin/env bash
printf '#title: %s\n' "$name"
printf 'fixture digest line\n'
SH
  chmod +x "$dir/hooks/session-start"
}

fm_ext_fixture_escape() {
  local dir=$1 name=${2:-escape-ext}
  fm_ext_fixture "$dir" "$name"
  printf '\nSee [configuration](../../../docs/configuration.md) for the rest.\n' >> "$dir/SKILL.md"
}

fm_ext_fixture_requires() {
  local dir=$1 cap=$2 name=${3:-future-ext} tmp
  fm_ext_fixture "$dir" "$name"
  tmp="$dir/.ext.json.tmp"
  jq --arg c "$cap" '.requires=[$c]' "$dir/ext.json" > "$tmp"
  mv "$tmp" "$dir/ext.json"
}

fm_ext_home() {
  local dir=$1
  mkdir -p "$dir/.agents/skills/coreskill" "$dir/bin" "$dir/state" "$dir/config" "$dir/data"
  printf '# core skill\n' > "$dir/.agents/skills/coreskill/SKILL.md"
  printf 'core\n' > "$dir/bin/fm-core.sh"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q -m initial
  printf '%s\n' "$dir"
}

# The hook variants below exist so the digest contributor's failure paths can be
# driven deliberately. Each takes an already-built fixture directory and
# replaces only its session-start hook, so the surrounding package stays valid.

# fm_ext_fixture_hook_failing <dir> [exit-code]: a hook that reports on stderr
# and exits non-zero.
fm_ext_fixture_hook_failing() {
  local dir=$1 code=${2:-3}
  cat > "$dir/hooks/session-start" <<SH
#!/usr/bin/env bash
printf 'ledger is unreadable\n' >&2
printf 'this body must never reach the digest\n'
exit $code
SH
  chmod +x "$dir/hooks/session-start"
}

# fm_ext_fixture_hook_hanging <dir>: a hook that never exits on its own, and
# whose child outlives it, so killing only the direct child would leave the
# digest waiting. The bound must terminate the whole process group.
fm_ext_fixture_hook_hanging() {
  local dir=$1
  cat > "$dir/hooks/session-start" <<'SH'
#!/usr/bin/env bash
sleep 300 &
wait
SH
  chmod +x "$dir/hooks/session-start"
}

# fm_ext_fixture_hook_oversized <dir> <bytes>: a hook contributing more than the
# byte cap allows.
fm_ext_fixture_hook_oversized() {
  local dir=$1 bytes=$2
  cat > "$dir/hooks/session-start" <<SH
#!/usr/bin/env bash
printf '#title: oversized\n'
for _ in \$(seq 1 $bytes); do printf 'x'; done
printf '\n'
SH
  chmod +x "$dir/hooks/session-start"
}

# fm_ext_fixture_hook_silent <dir>: a healthy hook that deliberately contributes
# nothing, the expected condition for an inert extension.
fm_ext_fixture_hook_silent() {
  local dir=$1
  cat > "$dir/hooks/session-start" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/hooks/session-start"
}

# fm_ext_fixture_add_launchwrap <dir> <hook-script-text>: declare a launch-wrap
# hook in the package's manifest and write the given script text to
# hooks/launch-wrap, replacing nothing else. The spawn seam's fixtures need
# launch-wrap-only packages (digest noise is irrelevant to them), so this
# deliberately leaves any session-start hook the fixture already wrote in place.
fm_ext_fixture_add_launchwrap() {
  local dir=$1 script=$2 tmp
  tmp="$dir/.ext.json.tmp"
  jq --arg h "hooks/launch-wrap" '.hooks["launch-wrap"]=$h' "$dir/ext.json" > "$tmp"
  mv "$tmp" "$dir/ext.json"
  printf '%s\n' "$script" > "$dir/hooks/launch-wrap"
  chmod +x "$dir/hooks/launch-wrap"
}
