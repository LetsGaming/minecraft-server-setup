#!/bin/bash
# Tests for rollback.sh.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() { make_fixture; trap cleanup_fixture EXIT; }
ROLLBACK="rollback.sh"
UPDATE_DIR_REL="archives/update"

test_rollback_restores_latest_update_backup() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_2026-01-01_00-00-00.tar.zst" before-update
  server_running
  run_script "$ROLLBACK" --y
  assert_rc 0 "$RC" "rollback exits 0"
  assert_file_content "$T/server/world/level.dat" before-update "world restored"
  assert_logged "systemctl stop testinst.service" "server stopped through systemctl"
  assert_logged "systemctl start testinst.service" "server started again"
}

test_failed_stop_does_not_abort_and_world_is_wiped() {
  setup
  mkdir -p "$T/backups/$UPDATE_DIR_REL"
  echo "garbage" > "$T/backups/$UPDATE_DIR_REL/minecraft_backup_bad.tar.zst"
  server_running
  export SYSTEMCTL_STOP_RC=1
  run_script "$ROLLBACK" --y
  assert_nonzero "$RC" "rollback fails overall"
  assert_contains "$OUT" "Clearing server files" "continued past the failed systemctl stop"
  assert_missing "$T/server/world" "world deleted although the stop failed and the archive is corrupt"
}

test_corrupt_archive_wipes_world() {
  setup
  mkdir -p "$T/backups/$UPDATE_DIR_REL"
  echo "garbage" > "$T/backups/$UPDATE_DIR_REL/minecraft_backup_bad.tar.zst"
  run_script "$ROLLBACK" --y
  assert_nonzero "$RC" "corrupt archive fails"
  assert_missing "$T/server/world" "world deleted before the archive was read"
}

test_no_update_backups() {
  setup
  run_script "$ROLLBACK" --y
  assert_rc 1 "$RC" "missing update directory exits 1"
  assert_file_content "$T/server/world/level.dat" current "server untouched"
}

test_list_flag() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_2026-01-01_00-00-00.tar.zst" x
  run_script "$ROLLBACK" --list
  assert_rc 0 "$RC" "--list exits 0"
  assert_contains "$OUT" "minecraft_backup_2026-01-01_00-00-00.tar.zst" "lists the archive"
}

run_tests
