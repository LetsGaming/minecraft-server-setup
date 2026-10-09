#!/bin/bash
# Characterization of backup/restore.sh (current behaviour, defects included).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

setup() { make_fixture; trap cleanup_fixture EXIT; }
RESTORE="backup/restore.sh"

test_tier_relative_file_restores_world() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "tier-relative --file exits 0"
  assert_file_content "$T/server/world/level.dat" restored "world replaced from archive"
  assert_exists "$T/server/.restored_dotfile" "archive dotfile extracted"
}

test_absolute_file_is_rejected() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file "$T/backups/hourly/minecraft_backup_a.tar.zst" --y
  assert_rc 1 "$RC" "absolute --file fails (the form the wrapper sends)"
  assert_contains "$OUT" "Specified backup does not exist" "reports missing backup"
  assert_file_content "$T/server/world/level.dat" current "server untouched"
}

test_stale_dotfiles_survive_restore() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_exists "$T/server/.live_dotfile" "pre-existing dotfile is not removed by the glob"
}

test_corrupt_archive_wipes_world() {
  setup
  mkdir -p "$T/backups/hourly"
  echo "not an archive" > "$T/backups/hourly/minecraft_backup_bad.tar.zst"
  run_script "$RESTORE" --file minecraft_backup_bad.tar.zst --y
  assert_nonzero "$RC" "corrupt archive fails"
  assert_missing "$T/server/world" "world already deleted before the archive was read"
}

test_restore_proceeds_while_server_running() {
  setup
  server_running
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "no running-server check: restore succeeds on a live server"
  assert_file_content "$T/server/world/level.dat" restored "live world overwritten"
}

test_latest_backup_is_default() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_old.tar.zst" old
  touch -d "2 hours ago" "$T/backups/hourly/minecraft_backup_old.tar.zst"
  make_archive "$T/backups/hourly/minecraft_backup_new.tar.zst" new
  run_script "$RESTORE" --y
  assert_rc 0 "$RC" "default restore exits 0"
  assert_file_content "$T/server/world/level.dat" new "newest archive chosen"
}

test_file_without_value_fails_on_unbound_variable() {
  setup
  run_script "$RESTORE" --file
  assert_nonzero "$RC" "--file with no value fails"
  assert_contains "$OUT" "unbound variable" "failure is a bash unbound-variable error, not a usage message"
}

test_unknown_argument() {
  setup
  run_script "$RESTORE" --bogus
  assert_rc 1 "$RC" "unknown argument exits 1"
}

test_ago_never_resolves_a_backup() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_old.tar.zst" old
  touch -d "5 hours ago" "$T/backups/hourly/minecraft_backup_old.tar.zst"
  run_script "$RESTORE" --ago 5h --y
  assert_rc 1 "$RC" "--ago fails: the awk diff column is not stripped from the selected path"
  assert_file_content "$T/server/world/level.dat" current "server untouched"
}

run_tests
