#!/usr/bin/env bash
# The second half of tests/fm-supervision-host.test.sh: the engine-error latch,
# turn bounding and reaping, the park boundary, and ownership stand-downs.
# That script owns every case, fixture, and helper; this one only selects the
# half it runs, so the two halves can land on separate portable serial CI shards
# (docs/fm-test-portable-shards.md).
set -u
FM_SUPERVISION_HOST_PART=2
# shellcheck source=tests/fm-supervision-host.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
