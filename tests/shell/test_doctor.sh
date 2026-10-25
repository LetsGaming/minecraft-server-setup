#!/bin/bash
# Tests for misc/doctor.sh against a fixture instance with fake binaries.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

DOCTOR="misc/doctor.sh"
set_var() { echo "$1=\"$2\"" >> "$T/scripts/common/variables.txt"; }

# A healthy instance: unit enabled and running with start limits, the backup
# cron job present, little backup data.
setup() {
  make_fixture; trap cleanup_fixture EXIT
  server_running
  export DOCTOR_SUDOERS_DIR="$T/sudoers.d"
  mkdir -p "$DOCTOR_SUDOERS_DIR"
  export SYSTEMCTL_SHIM_UNIT=$'[Unit]\nDescription=x\nStartLimitBurst=5\n[Service]\nRestart=on-failure'
  export CRONTAB_SHIM_TEXT="20 * * * * bash $T/scripts/backup/automation/run_backup.sh >> /dev/null 2>&1"
  export DU_SHIM_BYTES=1000
  export DOCTOR_MIN_FREE_GB=0
}

test_a_healthy_instance_passes() {
  setup
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "no failures"
  assert_contains "$OUT" "[OK] cron: hourly backup job present" "backup job found"
  assert_contains "$OUT" "[OK] crash-loop-limits" "start limits found"
  assert_contains "$OUT" "[SKIP] sudoers" "no service user, nothing to check"
  assert_contains "$OUT" "[SKIP] wrapper" "wrapper not enabled"
  assert_not_contains "$OUT" "[FAIL]" "nothing failed"
}

test_a_missing_backup_job_fails() {
  setup
  export CRONTAB_SHIM_TEXT="0 4 * * * echo unrelated"
  run_script "$DOCTOR"
  assert_rc 1 "$RC" "the run fails"
  assert_contains "$OUT" "[FAIL] cron: no hourly backup job" "says which job is missing"
}

test_a_user_without_a_crontab_fails_the_backup_check() {
  setup
  export CRONTAB_SHIM_NONE=1
  run_script "$DOCTOR"
  assert_rc 1 "$RC" "the run fails"
  assert_contains "$OUT" "[FAIL] cron" "an empty crontab has no backup job"
}

test_an_enabled_restart_schedule_needs_its_job() {
  setup
  set_var RESTART_ENABLED true
  run_script "$DOCTOR"
  assert_rc 1 "$RC" "the run fails"
  assert_contains "$OUT" "no scheduled restart job" "the restart job is missing"
}

test_storage_over_the_limit_fails_and_near_it_warns() {
  setup
  set_var MAX_STORAGE_GB 1
  export DU_SHIM_BYTES=$((1073741824 + 5000))
  run_script "$DOCTOR"
  assert_rc 1 "$RC" "over the limit fails"
  assert_contains "$OUT" "[FAIL] storage" "reported as storage"
  export DU_SHIM_BYTES=$((1073741824 * 95 / 100))
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "near the limit only warns"
  assert_contains "$OUT" "[WARN] storage" "reported as a warning"
}

test_a_missing_backups_folder_only_warns_before_the_first_backup() {
  setup
  rm -rf "$T/backups"
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "a fresh install is not a failure"
  assert_contains "$OUT" "[WARN] storage: backups folder" "says the folder is missing"
  assert_contains "$OUT" "does not exist yet" "and that the first backup creates it"
}

test_a_unit_without_start_limits_warns() {
  setup
  export SYSTEMCTL_SHIM_UNIT=$'[Unit]\nDescription=x\n[Service]\nStartLimitBurst=5'
  run_script "$DOCTOR"
  assert_contains "$OUT" "[WARN] crash-loop-limits" "limits in [Service] do not count"
  assert_rc 0 "$RC" "a warning does not fail the run"
}

test_sudoers_files_are_checked_with_visudo() {
  setup
  : > "$DOCTOR_SUDOERS_DIR/mc-service-wrapper-testinst"
  run_script "$DOCTOR"
  assert_contains "$OUT" "[OK] sudoers" "a valid file passes"
  export VISUDO_SHIM_RC=1
  run_script "$DOCTOR"
  assert_rc 1 "$RC" "a file visudo rejects fails the run"
  assert_contains "$OUT" "[FAIL] sudoers" "reported as sudoers"
}

test_wrapper_key_is_checked_and_kept_off_the_command_line() {
  setup
  set_var API_SERVER_ENABLED true
  set_var API_SERVER_PORT 3030
  set_var API_SERVER_KEY "secret-key-0123456789"
  run_script "$DOCTOR"
  assert_contains "$OUT" "[OK] wrapper-key" "the key is accepted"
  assert_not_logged "secret-key-0123456789" "the key never reaches curl's arguments"
  assert_logged "127.0.0.1:3030/health" "the configured port is probed"
  export CURL_SHIM_RUNNING_CODE=401
  run_script "$DOCTOR"
  assert_rc 1 "$RC" "a rejected key fails the run"
  assert_contains "$OUT" "[FAIL] wrapper-key" "reported as the key"
  export CURL_SHIM_HEALTH_CODE=000
  run_script "$DOCTOR"
  assert_contains "$OUT" "[FAIL] wrapper: GET /health" "a wrapper that does not answer fails"
}

test_a_normal_run_sends_no_notification() {
  setup
  set_var WEBHOOK_URL "https://hooks.example/x"
  run_script "$DOCTOR"
  assert_not_logged "hooks.example" "nothing is sent without --test-webhook"
}

test_test_webhook_sends_even_when_the_event_is_not_listed() {
  setup
  set_var WEBHOOK_URL "https://hooks.example/x"
  set_var WEBHOOK_EVENTS "backup_failed"
  run_script "$DOCTOR" --test-webhook
  assert_rc 0 "$RC" "no failures"
  assert_contains "$OUT" "[OK] webhook" "accepted"
  assert_logged "webhook_test" "the test event was sent"
}

test_test_webhook_reports_a_rejecting_endpoint() {
  setup
  set_var WEBHOOK_URL "https://hooks.example/x"
  export CURL_SHIM_RC=22
  run_script "$DOCTOR" --test-webhook
  assert_rc 1 "$RC" "the run fails"
  assert_contains "$OUT" "[FAIL] webhook" "reported"
}

test_test_webhook_without_a_url_is_skipped() {
  setup
  run_script "$DOCTOR" --test-webhook
  assert_contains "$OUT" "[SKIP] webhook" "nothing to test"
  assert_rc 0 "$RC" "not a failure"
}

xaero_jars() {
  mkdir -p "$T/server/mods"
  : > "$T/server/mods/xaerominimap-fabric-1.jar"
  : > "$T/server/mods/xaeroworldmap-fabric-1.jar"
}

test_doctor_xaero_skip_without_jars() {
  setup
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "no failures"
  assert_contains "$OUT" "[SKIP] xaero-config: no Xaero mod installed" "nothing to check"
}

test_doctor_xaero_drift_warns_with_fix_command() {
  setup; xaero_jars
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "a warning does not fail the run"
  assert_contains "$OUT" "[WARN] xaero-config: " "reported as a warning"
  assert_contains "$OUT" "everyone_tracks_everyone" "names the key"
  assert_contains "$OUT" "xaero_config.sh apply $T/server" "names the fix command"
}

test_doctor_xaero_ok_when_in_sync() {
  setup; xaero_jars
  bash "$T/scripts/misc/xaero_config.sh" apply "$T/server"
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "no failures"
  assert_contains "$OUT" "[OK] xaero-config" "keys are in sync"
}

test_doctor_xaero_check_failure_is_a_warning_with_its_text() {
  setup; xaero_jars
  printf '#!/bin/bash\necho "cannot read the config folder" >&2\nexit 2\n' > "$T/scripts/misc/xaero_config.sh"
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "a warning does not fail the run"
  assert_contains "$OUT" "[WARN] xaero-config: " "reported as a warning"
  assert_contains "$OUT" "cannot read the config folder" "shows the error text"
  assert_not_contains "$OUT" "no Xaero mod installed" "not reported as no mod"
}

test_doctor_xaero_script_missing_skips() {
  setup; xaero_jars
  rm "$T/scripts/misc/xaero_config.sh"
  run_script "$DOCTOR"
  assert_rc 0 "$RC" "no failures"
  assert_contains "$OUT" "[SKIP] xaero-config: xaero_config.sh not installed (run migrate.sh)" "older install"
}

run_tests
