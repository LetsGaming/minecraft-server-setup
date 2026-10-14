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

test_restore_refuses_while_server_running() {
  setup
  server_running
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 3 "$RC" "exit 3 while the session is up"
  assert_contains "$OUT" "is running" "tells the operator why"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "no staging directory created"
}

test_restore_refuses_when_only_systemd_reports_active() {
  setup
  cat > "$T/bin/screen" <<'SH'
#!/bin/bash
exit 1
SH
  cat > "$T/bin/systemctl" <<'SH'
#!/bin/bash
[[ "$1" == is-active ]] && { echo active; exit 0; }
exit 0
SH
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 3 "$RC" "systemd active alone is enough to refuse"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_restore_rechecks_right_before_the_swap() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  export TAR_SHIM_START_SERVER=1
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 3 "$RC" "server that came up during extraction aborts the swap"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "staging directory cleaned up"
}

test_restore_runs_once_server_is_stopped() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "no session, restore proceeds"
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

test_unknown_argument() {
  setup
  run_script "$RESTORE" --bogus
  assert_rc 1 "$RC" "unknown argument exits 1"
}

test_absolute_file_inside_backups_root_restores() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file "$T/backups/hourly/minecraft_backup_a.tar.zst" --y
  assert_rc 0 "$RC" "absolute --file (the form the wrapper sends) exits 0"
  assert_file_content "$T/server/world/level.dat" restored "world replaced from archive"
}

test_absolute_file_in_other_tier_restores() {
  setup
  make_archive "$T/backups/archives/daily/minecraft_backup_a.tar.zst" daily
  run_script "$RESTORE" --file "$T/backups/archives/daily/minecraft_backup_a.tar.zst" --y
  assert_rc 0 "$RC" "absolute path in archives/<type> accepted"
  assert_file_content "$T/server/world/level.dat" daily "world replaced from archive"
}

test_absolute_file_outside_backups_root_is_rejected() {
  setup
  make_archive "$T/elsewhere/minecraft_backup_a.tar.zst" evil
  run_script "$RESTORE" --file "$T/elsewhere/minecraft_backup_a.tar.zst" --y
  assert_rc 1 "$RC" "path outside the backups root exits 1"
  assert_contains "$OUT" "outside the backups directory" "explains the rejection"
  assert_file_content "$T/server/world/level.dat" current "server untouched"
}

test_symlink_escape_is_rejected() {
  setup
  make_archive "$T/elsewhere/minecraft_backup_a.tar.zst" evil
  mkdir -p "$T/backups/hourly"
  if ! ln -s "$T/elsewhere/minecraft_backup_a.tar.zst" "$T/backups/hourly/link.tar.zst" 2>/dev/null      || [[ ! -L "$T/backups/hourly/link.tar.zst" ]]; then
    skip "symlink escape" "this host cannot create real symlinks"
    return
  fi
  run_script "$RESTORE" --file "$T/backups/hourly/link.tar.zst" --y
  assert_rc 1 "$RC" "symlink pointing outside the backups root exits 1"
  run_script "$RESTORE" --file link.tar.zst --y
  assert_rc 1 "$RC" "same via a tier-relative name"
  assert_file_content "$T/server/world/level.dat" current "server untouched"
}

test_symlink_inside_backups_root_is_allowed() {
  setup
  make_archive "$T/backups/archives/update/minecraft_backup_a.tar.zst" snap
  mkdir -p "$T/backups/archives"
  if ! ln -s "$T/backups/archives/update/minecraft_backup_a.tar.zst" "$T/backups/archives/latest.tar.zst" 2>/dev/null      || [[ ! -L "$T/backups/archives/latest.tar.zst" ]]; then
    skip "in-root symlink" "this host cannot create real symlinks"
    return
  fi
  run_script "$RESTORE" --file "$T/backups/archives/latest.tar.zst" --y
  assert_rc 0 "$RC" "symlink resolving inside the backups root is accepted"
  assert_file_content "$T/server/world/level.dat" snap "world replaced from archive"
}

test_dotdot_is_rejected() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file "../hourly/minecraft_backup_a.tar.zst" --y
  assert_rc 1 "$RC" "relative .. exits 1"
  run_script "$RESTORE" --file "$T/backups/hourly/../hourly/minecraft_backup_a.tar.zst" --y
  assert_rc 1 "$RC" "absolute path containing .. exits 1"
  assert_contains "$OUT" "must not contain" "explains the rejection"
  assert_file_content "$T/server/world/level.dat" current "server untouched"
}

test_directory_is_rejected() {
  setup
  mkdir -p "$T/backups/hourly/sub"
  run_script "$RESTORE" --file "$T/backups/hourly/sub" --y
  assert_rc 1 "$RC" "a directory is not a backup"
}

test_missing_file_is_rejected() {
  setup
  run_script "$RESTORE" --file nope.tar.zst --y
  assert_rc 1 "$RC" "missing backup exits 1"
  assert_contains "$OUT" "Specified backup does not exist" "reports missing backup"
}

test_file_without_value_is_a_usage_error() {
  setup
  run_script "$RESTORE" --file
  assert_rc 1 "$RC" "--file with no value exits 1"
  assert_contains "$OUT" "--file requires a value" "usage message"
  assert_not_contains "$OUT" "unbound variable" "no bash error leaks"
  run_script "$RESTORE" --ago
  assert_contains "$OUT" "--ago requires a value" "same for --ago"
}

test_ago_picks_closest_backup() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_old.tar.zst" old
  touch -d "5 hours ago" "$T/backups/hourly/minecraft_backup_old.tar.zst"
  make_archive "$T/backups/hourly/minecraft_backup_new.tar.zst" new
  run_script "$RESTORE" --ago 5h --y
  assert_rc 0 "$RC" "--ago exits 0"
  assert_file_content "$T/server/world/level.dat" old "closest-to-5h archive chosen"
}

test_stale_dotfiles_are_replaced() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore exits 0"
  assert_missing "$T/server/.live_dotfile" "dotfile absent from the archive is gone"
  assert_exists "$T/server/.restored_dotfile" "dotfile from the archive is present"
}

test_no_staging_or_old_directories_remain() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "no server.restore-staging.* or server.pre-restore.* left"
}

test_corrupt_archive_leaves_world_untouched() {
  setup
  mkdir -p "$T/backups/hourly"
  echo "not an archive" > "$T/backups/hourly/minecraft_backup_bad.tar.zst"
  run_script "$RESTORE" --file minecraft_backup_bad.tar.zst --y
  assert_nonzero "$RC" "corrupt archive fails"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_exists "$T/server/.live_dotfile" "dotfiles untouched"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "no staging directory left"
}

test_zstd_integrity_failure_leaves_world_untouched() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  export ZSTD_SHIM_FAIL_TEST=1
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_nonzero "$RC" "failed zstd -t aborts"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_extraction_failure_leaves_world_untouched() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  export TAR_SHIM_FAIL_EXTRACT=1
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_nonzero "$RC" "failed extraction aborts"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_exists "$T/server/.live_dotfile" "dotfiles untouched"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "staging directory cleaned up"
}

test_unsupported_extension_is_rejected_before_any_change() {
  setup
  mkdir -p "$T/backups/hourly"
  echo x > "$T/backups/hourly/minecraft_backup_a.zip"
  run_script "$RESTORE" --file minecraft_backup_a.zip --y
  assert_nonzero "$RC" "unsupported format fails"
  assert_contains "$OUT" "Unsupported backup file format" "says why"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_restore_into_missing_server_dir() {
  setup
  rm -rf "$T/server"
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore creates the server directory"
  assert_file_content "$T/server/world/level.dat" restored "world restored"
}

# ── systemd units from an archive ────────────────────────────────────────────

unit_archive() { # unit text
  make_archive_with_unit "$T/backups/archives/minecraft_backup_u.tar.zst" restored testinst.service "$1"
  export SYSTEMD_UNIT_DIR="$T/units"
  mkdir -p "$SYSTEMD_UNIT_DIR"
}

test_units_in_an_archive_are_not_installed_without_consent() {
  setup
  unit_archive "ExecStart=/bin/true"
  run_script "$RESTORE" --archive --file minecraft_backup_u.tar.zst --y
  assert_rc 0 "$RC" "restore itself succeeds"
  assert_not_logged "sudo cp" "no unit copied with sudo"
  assert_not_logged "daemon-reload" "no daemon-reload without an install"
  assert_missing "$T/units/testinst.service" "nothing written to the unit directory"
  assert_contains "$OUT" "NOT installed" "tells the operator the unit was skipped"
  assert_contains "$OUT" "--install-units" "says how to install it"
  assert_contains "$OUT" "ExecStart=/bin/true" "shows the unit that was skipped"
}

test_changed_unit_shows_a_diff_before_installing() {
  setup
  unit_archive "ExecStart=/bin/new"
  echo "ExecStart=/bin/old" > "$T/units/testinst.service"
  run_script "$RESTORE" --archive --file minecraft_backup_u.tar.zst --y --install-units
  assert_rc 0 "$RC" "restore succeeds"
  assert_contains "$OUT" "-ExecStart=/bin/old" "diff shows the installed line"
  assert_contains "$OUT" "+ExecStart=/bin/new" "diff shows the incoming line"
  assert_logged "sudo cp" "installed after review with --install-units"
  assert_logged "systemctl daemon-reload" "systemd reloaded after installing"
}

test_identical_unit_is_left_alone() {
  setup
  unit_archive "ExecStart=/bin/same"
  echo "ExecStart=/bin/same" > "$T/units/testinst.service"
  run_script "$RESTORE" --archive --file minecraft_backup_u.tar.zst --y --install-units
  assert_contains "$OUT" "is unchanged" "unchanged unit reported"
  assert_not_logged "sudo cp" "nothing copied"
  assert_not_logged "daemon-reload" "no reload"
}

# ── the wrapper config from an archive ──────────────────────────────────────

config_archive() { # archive holding .mc-meta/api-server-config.json
  local src
  src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world" "$src/.mc-meta"
  echo restored > "$src/world/level.dat"
  echo '{"apiKey":"restored"}' > "$src/.mc-meta/api-server-config.json"
  mkdir -p "$T/backups/archives"
  "$REAL_TAR" -cf - -C "$src" . | gzip -c > "$T/backups/archives/minecraft_backup_c.tar.zst"
  rm -rf "$src"
}

test_wrapper_config_is_restored_into_services() {
  setup
  use_install_layout
  config_archive
  run_in_layout "$RESTORE" --archive --file minecraft_backup_c.tar.zst --y
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$R/services/api-server/api-server-config.json" '{"apiKey":"restored"}' "config lands in services/api-server/"
  assert_eq "600" "$(stat -c %a "$R/services/api-server/api-server-config.json")" "config is mode 600"
  assert_missing "$R/instances/api-server" "nothing is written under instances/"
  assert_contains "$OUT" "mc-root-api-server.service" "the start hint names the install root's unit"
}

test_wrapper_config_goes_to_the_old_folder_on_an_old_layout() {
  setup
  use_install_layout
  rmdir "$R/services"
  mkdir -p "$R/api-server"
  config_archive
  run_in_layout "$RESTORE" --archive --file minecraft_backup_c.tar.zst --y
  assert_file_content "$R/api-server/api-server-config.json" '{"apiKey":"restored"}' "config lands in api-server/"
  assert_missing "$R/services/api-server" "no services/ folder is made beside it"
}

run_tests
