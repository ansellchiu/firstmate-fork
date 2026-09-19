#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.H8yHJP/owner-dep.sh
. "/Users/achiu/.treehouse/firstmate-d4b9d8/4/firstmate/.fm-lint-parity.H8yHJP/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
