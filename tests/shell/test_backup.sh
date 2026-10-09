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

test_archive_type_dotdot_escapes_archives_dir() {
  setup
  run_script "$BACKUP" --archive ..
  assert_rc 0 "$RC" "'--archive ..' is accepted"
  assert_exists "$(first_archive "$T/backups/archives/..")" "archive lands outside archives/ (backups root)"
  assert_exists "$(find "$T/backups" -maxdepth 1 -name '*.tar.zst')" "archive sits directly in the backups root"
}

test_tar_dying_midway_is_reported_as_success() {
  setup
  export TAR_SHIM_FAIL_CREATE=1
  run_script "$BACKUP"
  assert_rc 0 "$RC" "truncated tar|zstd still exits 0 (no pipefail)"
  assert_exists "$(first_archive "$T/backups/hourly")" "truncated archive is kept"
}

test_failed_rsync_leaves_stale_temp_dir() {
  setup
  export RSYNC_SHIM_FAIL=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "rsync failure exits 1"
  assert_exists "$T/backups/hourly/tmp_backup" "temp dir is left behind"
}


test_dry_run_writes_nothing() {
  setup
  run_script "$BACKUP" --dry-run
  assert_rc 0 "$RC" "dry run exits 0"
  assert_eq "" "$(first_archive "$T/backups")" "no archive"
}

test_backups_do_not_take_a_lock() {
  setup
  export FLOCK_SHIM_BUSY=1
  run_script "$BACKUP"
  assert_rc 0 "$RC" "a busy lock changes nothing: backup.sh never calls flock"
  assert_not_logged "flock" "flock not invoked"
}

test_run_backup_executes_generation_flag_as_a_command() {
  setup
  sed -i "s|^DO_GENERATION_BACKUPS=.*|DO_GENERATION_BACKUPS=\"touch $T/pwned\"|" "$T/scripts/common/variables.txt"
  run_script "$RUN_BACKUP"
  assert_exists "$T/pwned" "the variable's value was executed as a command"
}

test_run_backup_hourly_when_generations_off() {
  setup
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "run_backup exits 0"
  assert_exists "$(first_archive "$T/backups/hourly")" "hourly archive written"
}

test_invalid_archive_is_kept_when_server_offline() {
  setup
  export ZSTD_SHIM_FAIL_TEST=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "failed zstd -t exits 1"
  assert_exists "$(first_archive "$T/backups/hourly")" "the failure path aborts at send_message (server offline) before removing the archive"
}

run_tests
