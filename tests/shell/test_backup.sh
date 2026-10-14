#!/bin/bash
# Characterization of backup/backup.sh and backup/automation/run_backup.sh
# (current behaviour, defects included).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() { make_fixture; trap cleanup_fixture EXIT; }
BACKUP="backup/backup.sh"
RUN_BACKUP="backup/automation/run_backup.sh"

first_archive() { find "$1" -name '*.tar.zst' 2>/dev/null | head -n1; }

test_hourly_backup_creates_valid_archive() {
  setup
  run_script "$BACKUP"
  assert_rc 0 "$RC" "hourly backup exits 0"
  local a; a="$(first_archive "$T/backups/hourly")"
  assert_exists "$a" "archive written to hourly/"
  assert_eq "0" "$(gzip -t "$a" 2>/dev/null; echo $?)" "archive is intact"
  assert_contains "$("$REAL_TAR" -tzf "$a")" "world/level.dat" "archive holds the world"
  assert_contains "$("$REAL_TAR" -tzf "$a")" ".live_dotfile" "archive holds dotfiles"
  assert_missing "$T/backups/hourly/tmp_backup" "temp dir removed after success"
}

test_archive_mode_uses_type_directory() {
  setup
  run_script "$BACKUP" --archive weekly
  assert_rc 0 "$RC" "archive backup exits 0"
  assert_exists "$(first_archive "$T/backups/archives/weekly")" "archive written to archives/weekly"
}


# The install root is <root>, not the server dir's parent <root>/instances.
test_archive_carries_the_wrapper_config_from_services() {
  setup
  use_install_layout
  mkdir -p "$R/services/api-server"
  echo '{"apiKey":"k"}' > "$R/services/api-server/api-server-config.json"
  run_in_layout "$BACKUP" --archive weekly
  assert_rc 0 "$RC" "archive backup exits 0"
  assert_contains "$OUT" "✓ api-server-config.json" "the config is staged"
  assert_contains "$("$REAL_TAR" -tzf "$(first_archive "$T/backups/archives/weekly")")" \
    ".mc-meta/api-server-config.json" "the archive holds the config"
}

test_archive_finds_the_wrapper_config_in_the_old_layout() {
  setup
  use_install_layout
  mkdir -p "$R/api-server"
  echo '{"apiKey":"k"}' > "$R/api-server/api-server-config.json"
  run_in_layout "$BACKUP" --archive weekly
  assert_contains "$OUT" "✓ api-server-config.json" "the config at <root>/api-server/ is staged"
}

test_dry_run_writes_nothing() {
  setup
  run_script "$BACKUP" --dry-run
  assert_rc 0 "$RC" "dry run exits 0"
  assert_eq "" "$(first_archive "$T/backups")" "no archive"
}

test_run_backup_hourly_when_generations_off() {
  setup
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "run_backup exits 0"
  assert_exists "$(first_archive "$T/backups/hourly")" "hourly archive written"
}

test_invalid_archive_types_are_rejected() {
  setup
  local bad
  for bad in .. ../x a/b UPPER "x y" 'a;b'; do
    run_script "$BACKUP" --archive "$bad"
    assert_rc 1 "$RC" "--archive '$bad' exits 1"
  done
  assert_contains "$OUT" "Invalid archive type" "explains the rejection"
  assert_eq "" "$(first_archive "$T/backups")" "nothing written anywhere"
  assert_missing "$T/backups/hourly" "no directory created before validation"
}

test_valid_archive_types_are_accepted() {
  setup
  run_script "$BACKUP" --archive pre_update-2
  assert_rc 0 "$RC" "lowercase, digits, '_' and '-' are fine"
  assert_exists "$(first_archive "$T/backups/archives/pre_update-2")" "archive written"
}

test_archive_without_type_defaults_to_general() {
  setup
  run_script "$BACKUP" --archive
  assert_rc 0 "$RC" "bare --archive exits 0"
  assert_exists "$(first_archive "$T/backups/archives/general")" "archive in archives/general"
}

test_tar_dying_midway_fails_and_leaves_nothing() {
  setup
  export TAR_SHIM_FAIL_CREATE=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "pipeline failure is reported"
  assert_contains "$OUT" "Compression failed" "says what failed"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "no truncated archive kept"
  assert_missing "$T/backups/hourly/tmp_backup" "temp dir removed"
}

test_unlistable_tar_is_rejected_and_removed() {
  setup
  export TAR_SHIM_FAIL_LIST=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "tar -tf failure exits 1"
  assert_contains "$OUT" "Validation failed" "says what failed"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "archive removed"
  assert_missing "$T/backups/hourly/tmp_backup" "temp dir removed"
}

test_failed_zstd_test_removes_archive_even_when_server_offline() {
  setup
  export ZSTD_SHIM_FAIL_TEST=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "failed zstd -t exits 1"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "archive removed"
  assert_missing "$T/backups/hourly/tmp_backup" "temp dir removed"
}

test_failed_rsync_cleans_temp_dir() {
  setup
  export RSYNC_SHIM_FAIL=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "rsync failure exits 1"
  assert_missing "$T/backups/hourly/tmp_backup" "temp dir removed by the EXIT trap"
}

test_stale_temp_dir_from_a_killed_run_is_discarded() {
  setup
  mkdir -p "$T/backups/hourly/tmp_backup"
  echo stale > "$T/backups/hourly/tmp_backup/deleted_since.txt"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_not_contains "$("$REAL_TAR" -tzf "$(first_archive "$T/backups/hourly")")" "deleted_since.txt" "stale file not carried into the archive"
}

test_busy_lock_skips_the_run() {
  setup
  export FLOCK_SHIM_BUSY=1 MC_OPERATION_LOCK_HELD=1
  run_script "$BACKUP"
  assert_rc 75 "$RC" "exit 75 when another backup holds the lock"
  assert_contains "$OUT" "Another backup is already running" "says why"
  assert_eq "" "$(first_archive "$T/backups")" "nothing written"
}

test_backup_uses_a_per_instance_lock_file() {
  setup
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0 when the lock is free"
  assert_logged "flock -n 9" "non-blocking lock requested"
  [[ -n "$REAL_FLOCK" ]] && assert_exists "$T/backups/.backup.lock" "lock file lives in the instance backups root"
}

test_two_real_concurrent_backups_do_not_interleave() {
  if [[ -z "$REAL_FLOCK" ]]; then
    skip "concurrent run exclusion" "flock is not installed on this host; covered by the busy-lock test with a shim"
    return
  fi
  setup
  run_script "$BACKUP" &
  command sleep 0.2
  local second_out second_rc
  second_out="$(cd "$T/scripts" && bash "$BACKUP" 2>&1)"; second_rc=$?
  wait
  assert_eq "75" "$second_rc" "second run is refused while the first is active"
}

test_dry_run_takes_no_lock() {
  setup
  export FLOCK_SHIM_BUSY=1
  run_script "$BACKUP" --dry-run
  assert_rc 0 "$RC" "dry run ignores the lock"
}

test_run_backup_never_executes_the_generation_flag() {
  setup
  sed -i "s|^DO_GENERATION_BACKUPS=.*|DO_GENERATION_BACKUPS=\"touch $T/pwned\"|" "$T/scripts/common/variables.txt"
  run_script "$RUN_BACKUP"
  assert_missing "$T/pwned" "the variable's value is compared, not run"
  assert_rc 0 "$RC" "falls through to the hourly backup"
  assert_exists "$(first_archive "$T/backups/hourly")" "hourly archive written"
}

test_run_backup_skips_quietly_when_locked() {
  setup
  export FLOCK_SHIM_BUSY=1 MC_OPERATION_LOCK_HELD=1
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "cron run exits 0 when another backup is active"
  assert_contains "$OUT" "Another backup is running" "logs the skip"
}

test_backup_yields_to_a_running_operation() {
  setup
  export FLOCK_SHIM_BUSY=1
  unset MC_OPERATION_LOCK_HELD
  run_script "$BACKUP"
  assert_rc 75 "$RC" "exit 75 while a restore, rollback or upgrade holds the operation lock"
  assert_contains "$OUT" "Another operation" "says why"
  assert_eq "" "$(first_archive "$T/backups")" "nothing written"
}

test_backup_started_by_an_operation_does_not_wait_on_it() {
  setup
  export MC_OPERATION_LOCK_HELD=1
  run_script "$BACKUP"
  assert_rc 0 "$RC" "the upgrade job can run backup under its own lock"
}

test_backup_creates_archives_private_by_default() {
  setup
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_logged "zstd-umask 0077" "archive is written under umask 077"
}

test_backup_umask_can_be_widened_explicitly() {
  setup
  export BACKUP_UMASK=027
  run_script "$BACKUP"
  assert_logged "zstd-umask 0027" "BACKUP_UMASK is honoured"
}

run_tests
