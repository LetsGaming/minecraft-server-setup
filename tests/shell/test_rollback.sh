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

test_the_metadata_folder_does_not_stay_in_the_live_server() {
  setup
  make_archive_with_unit "$T/backups/$UPDATE_DIR_REL/minecraft_backup_m.tar.zst" before-update testinst.service "ExecStart=/bin/true"
  server_running
  run_script "$ROLLBACK" --y
  assert_rc 0 "$RC" "rollback exits 0"
  assert_file_content "$T/server/world/level.dat" before-update "world restored"
  assert_missing "$T/server/.mc-meta" "the archived copy of variables and units is removed"
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

test_failed_stop_aborts_and_keeps_world() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_a.tar.zst" before-update
  server_running
  export SYSTEMCTL_STOP_RC=1
  run_script "$ROLLBACK" --y
  assert_nonzero "$RC" "rollback aborts when systemctl stop fails"
  assert_not_contains "$OUT" "Restoring backup" "never reaches the restore step"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_exists "$T/server/.live_dotfile" "dotfiles untouched"
}

test_server_still_running_after_stop_aborts() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_a.tar.zst" before-update
  server_running
  # stop reports success but the session never goes away
  cat > "$T/bin/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >> "$SHIM_LOG"
exit 0
SH
  run_script "$ROLLBACK" --y
  assert_nonzero "$RC" "rollback aborts"
  assert_contains "$OUT" "is running" "says why"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_rollback_rechecks_right_before_the_swap() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_a.tar.zst" before-update
  server_running
  export TAR_SHIM_START_SERVER=1
  run_script "$ROLLBACK" --y
  assert_nonzero "$RC" "server that came up during extraction aborts the swap"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "staging directory cleaned up"
}

test_corrupt_archive_aborts_before_stopping_server() {
  setup
  mkdir -p "$T/backups/$UPDATE_DIR_REL"
  echo "garbage" > "$T/backups/$UPDATE_DIR_REL/minecraft_backup_bad.tar.zst"
  server_running
  run_script "$ROLLBACK" --y
  assert_nonzero "$RC" "corrupt archive fails"
  assert_not_logged "systemctl stop" "server never stopped"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_extraction_failure_keeps_world_and_restarts_server() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_a.tar.zst" before-update
  server_running
  export TAR_SHIM_FAIL_EXTRACT=1
  run_script "$ROLLBACK" --y
  assert_nonzero "$RC" "rollback fails"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_exists "$T/server/.live_dotfile" "dotfiles untouched"
  assert_logged "systemctl start testinst.service" "server started again"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "staging directory cleaned up"
}

test_rollback_replaces_dotfiles() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_a.tar.zst" before-update
  run_script "$ROLLBACK" --y
  assert_rc 0 "$RC" "rollback exits 0"
  assert_missing "$T/server/.live_dotfile" "stale dotfile gone"
  assert_exists "$T/server/.restored_dotfile" "archive dotfile present"
}

test_keep_old_keeps_the_replaced_server_files() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_a.tar.zst" before-update
  server_running
  run_script "$ROLLBACK" --y --keep-old
  assert_rc 0 "$RC" "rollback exits 0"
  assert_file_content "$T/server/world/level.dat" before-update "world restored"
  assert_file_content "$T/server.pre-restore/world/level.dat" current "the previous world is kept"
}

test_rollback_deletes_the_replaced_files_without_keep_old() {
  setup
  make_archive "$T/backups/$UPDATE_DIR_REL/minecraft_backup_a.tar.zst" before-update
  server_running
  run_script "$ROLLBACK" --y
  assert_missing "$T/server.pre-restore" "nothing kept by default"
}

run_tests
