#!/usr/bin/env bash
# tests/fm-vault.test.sh - unit and behavior tests for bin/fm-vault-lib.sh,
# the Automic Vault approval service liveness probe.
#
# Coverage:
#   - av absent: returns 0 and produces no diagnostic output
#   - av healthy (av list exits 0): returns 0 and stays silent
#   - av refused (av list exits non-zero): returns 1 and emits VAULT diagnostic
#   - av hung (av list hangs / times out): bounds probe, returns 1, emits VAULT diagnostic
#   - bounded execution terminates child process group promptly
#   - custom timeout bounds and capping at <= 10s
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-vault-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

# shellcheck source=bin/fm-vault-lib.sh
. "$ROOT/bin/fm-vault-lib.sh"

test_av_absent() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/av-absent")
  # PATH has no av binary
  out=$(PATH="$fakebin:$BASE_PATH" fm_vault_diagnostic 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm_vault_diagnostic when av is absent"
  [ -z "$out" ] || fail "fm_vault_diagnostic produced unexpected output when av is absent: $out"

  PATH="$fakebin:$BASE_PATH" fm_vault_probe
  rc=$?
  expect_code 0 "$rc" "fm_vault_probe when av is absent"
  pass "av absent: probe and diagnostic return 0 silently"
}

test_av_healthy() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/av-healthy")
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  printf 'vault1\nvault2\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/av"

  out=$(PATH="$fakebin:$BASE_PATH" fm_vault_diagnostic 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm_vault_diagnostic when av is healthy"
  [ -z "$out" ] || fail "fm_vault_diagnostic produced unexpected output when av is healthy: $out"

  PATH="$fakebin:$BASE_PATH" fm_vault_probe
  rc=$?
  expect_code 0 "$rc" "fm_vault_probe when av is healthy"
  pass "av healthy: probe and diagnostic return 0 silently"
}

test_av_refused() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/av-refused")
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  printf 'automic vault: human approval required\n' >&2
  exit 1
fi
exit 1
SH
  chmod +x "$fakebin/av"

  out=$(PATH="$fakebin:$BASE_PATH" fm_vault_diagnostic 2>&1)
  rc=$?
  expect_code 1 "$rc" "fm_vault_diagnostic when av is refused"
  assert_contains "$out" "VAULT: approval service degraded - key-injecting tool calls will refuse (open the menu-bar vault app)" \
    "fm_vault_diagnostic emitted the required VAULT line"

  PATH="$fakebin:$BASE_PATH" fm_vault_probe
  rc=$?
  expect_code 1 "$rc" "fm_vault_probe when av is refused"
  pass "av refused: probe returns 1 and diagnostic emits VAULT line"
}

test_av_hung() {
  local fakebin out rc started finished elapsed
  fakebin=$(fm_fakebin "$TMP_ROOT/av-hung")
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  # Hang indefinitely
  exec perl -e 'sleep 300'
fi
exit 0
SH
  chmod +x "$fakebin/av"

  started=$(date +%s)
  out=$(PATH="$fakebin:$BASE_PATH" FM_VAULT_PROBE_TIMEOUT=1 fm_vault_diagnostic 1 2>&1)
  rc=$?
  finished=$(date +%s)
  elapsed=$((finished - started))

  expect_code 1 "$rc" "fm_vault_diagnostic when av hung"
  assert_contains "$out" "VAULT: approval service degraded - key-injecting tool calls will refuse (open the menu-bar vault app)" \
    "fm_vault_diagnostic emitted the required VAULT line on timeout"
  [ "$elapsed" -le 4 ] || fail "fm_vault_diagnostic with 1s timeout took ${elapsed}s, expected <= 4s"

  PATH="$fakebin:$BASE_PATH" fm_vault_probe 1
  rc=$?
  expect_code 1 "$rc" "fm_vault_probe when av hung"
  pass "av hung: probe terminates within bound, returns 1, and diagnostic emits VAULT line"
}

# The cap is what keeps a caller (or a stale env value) from turning this
# advisory liveness probe into a long block. It moved 5s -> 10s so an operator
# tapping an approval is not judged by it, so pin the clamp through the real hang
# path rather than leaving the number asserted nowhere.
test_probe_timeout_cap() {
  local fakebin rc started finished elapsed
  fakebin=$(fm_fakebin "$TMP_ROOT/av-cap")
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  exec perl -e 'sleep 300'
fi
exit 0
SH
  chmod +x "$fakebin/av"

  started=$(date +%s)
  PATH="$fakebin:$BASE_PATH" fm_vault_probe 600
  rc=$?
  finished=$(date +%s)
  elapsed=$((finished - started))
  expect_code 1 "$rc" "fm_vault_probe with an over-cap timeout"
  [ "$elapsed" -le 20 ] || fail "an over-cap timeout must clamp to 10s, took ${elapsed}s"

  # A zero or non-numeric request falls back to the 10s default, never to "no
  # bound at all".
  started=$(date +%s)
  PATH="$fakebin:$BASE_PATH" fm_vault_probe 0
  rc=$?
  finished=$(date +%s)
  elapsed=$((finished - started))
  expect_code 1 "$rc" "fm_vault_probe with a zero timeout"
  [ "$elapsed" -le 20 ] || fail "a zero timeout must fall back to the 10s default, took ${elapsed}s"
  pass "the probe clamps an over-cap or zero timeout to its 10s bound"
}

test_av_absent
test_av_healthy
test_av_refused
test_av_hung
test_probe_timeout_cap

echo "# fm-vault.test.sh: all assertions passed"
