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
  run_script_tty "$RESTORE" --y
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

stamp_ago() { date -d "$1 ago" +'%Y-%m-%d_%H-%M-%S'; }

test_ago_picks_the_newest_backup_at_or_before_the_target_by_name() {
  setup
  # mtimes say the opposite of the names; the name wins.
  make_archive "$T/backups/hourly/minecraft_backup_$(stamp_ago '6 hours').tar.zst" six
  make_archive "$T/backups/hourly/minecraft_backup_$(stamp_ago '4 hours').tar.zst" four
  make_archive "$T/backups/hourly/minecraft_backup_$(stamp_ago '1 hour').tar.zst" one
  touch -d "10 hours ago" "$T"/backups/hourly/minecraft_backup_*
  run_script_tty "$RESTORE" --ago 5h --y
  assert_rc 0 "$RC" "--ago exits 0"
  assert_file_content "$T/server/world/level.dat" six "the newest backup at or before 5h ago is chosen"
  assert_contains "$OUT" "closest backup" "says which stamp was chosen"
}

test_ago_refuses_a_match_far_from_the_target_without_y() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_$(stamp_ago '30 hours').tar.zst" old
  run_script_tty "$RESTORE" --ago 5h
  assert_rc 1 "$RC" "a backup 25 hours off a 5 hour target is refused"
  assert_contains "$OUT" "away from the requested time" "says why"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  run_script_tty "$RESTORE" --ago 5h --y
  assert_rc 0 "$RC" "--y accepts it"
  assert_file_content "$T/server/world/level.dat" old "and restores it"
}

test_a_missing_tier_folder_gives_a_friendly_error() {
  setup
  rm -rf "$T/backups/hourly"
  run_script_tty "$RESTORE" --y
  assert_rc 1 "$RC" "exit 1"
  assert_contains "$OUT" "No backups folder" "explains instead of a find error"
  assert_not_contains "$OUT" "No such file" "no raw tool error"
}

test_selection_ignores_partial_files_and_data_folders() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" good
  make_archive "$T/backups/hourly/.minecraft_backup_2026-01-02_00-00-00.tar.zst.part" partial
  mkdir -p "$T/backups/hourly/tmp_backup/world"
  make_archive "$T/backups/hourly/tmp_backup/minecraft_backup_2026-01-03_00-00-00.tar.zst" nested
  run_script_tty "$RESTORE" --y
  assert_rc 0 "$RC" "restore exits 0"
  assert_file_content "$T/server/world/level.dat" good "only a finished archive in the tier folder itself is a candidate"
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
  assert_eq "" "$(find "$T" -maxdepth 1 \( -name 'server.restore-staging.*' -o -name 'server.pre-restore.*' \))" "no server.restore-staging.* or server.pre-restore.<pid> left"
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
  export ZSTD_SHIM_FAIL_DECOMPRESS=1
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_nonzero "$RC" "a stream that does not decompress aborts"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "no staging or pre-restore directory left"
}

test_restore_decompresses_the_archive_once() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore exits 0"
  assert_eq "1" "$(grep -c '^zstd .*-d' "$SHIM_LOG")" "one zstd decompression"
  assert_not_logged "zstd -t" "no separate integrity pass"
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
  run_script_tty "$RESTORE" --archive --file minecraft_backup_u.tar.zst --y --install-units
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
  run_script_tty "$RESTORE" --archive --file minecraft_backup_u.tar.zst --y --install-units
  assert_contains "$OUT" "is unchanged" "unchanged unit reported"
  assert_not_logged "sudo cp" "nothing copied"
  assert_not_logged "daemon-reload" "no reload"
}

# ── the wrapper config from an archive ──────────────────────────────────────

config_archive() { # archive holding .mc-meta/api-server-config.json
  local src
  src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world/region" "$src/.mc-meta"
  echo restored > "$src/world/level.dat"
  echo r > "$src/world/region/r.0.0.mca"
  echo '{"apiKey":"restored"}' > "$src/.mc-meta/api-server-config.json"
  make_archive_from "$T/backups/archives/minecraft_backup_c.tar.zst" "$src"
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

# ── S-004: nothing implicit without a terminal, and only trusted archives ──

test_without_a_terminal_a_file_and_y_are_required() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --y
  assert_rc 1 "$RC" "no --file: refused"
  assert_contains "$OUT" "needs both --file" "says what is missing"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst
  assert_rc 1 "$RC" "no --y: refused rather than reading a y from stdin"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_scripts_and_units_flags_are_refused_without_a_terminal() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y --with-scripts
  assert_rc 1 "$RC" "--with-scripts is refused"
  assert_contains "$OUT" "need a terminal" "says why"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y --install-units
  assert_rc 1 "$RC" "--install-units is refused"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_an_archive_owned_by_someone_else_is_refused() {
  if [[ "$(id -u)" != 0 ]]; then skip "foreign-owner archive" "needs root to chown"; return; fi
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" planted
  chown 65534 "$T/backups/hourly/minecraft_backup_a.tar.zst"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 1 "$RC" "refused"
  assert_contains "$OUT" "owned by uid 65534" "says whose it is"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_archived_scripts_are_not_restored_without_a_terminal() {
  setup
  local src; src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world" "$src/.mc-meta/scripts"
  echo restored > "$src/world/level.dat"
  echo "echo planted" > "$src/.mc-meta/scripts/start.sh"
  mkdir -p "$T/backups/hourly"
  "$REAL_TAR" -cf - -C "$src" . | gzip -c > "$T/backups/hourly/minecraft_backup_m.tar.gz"
  run_script "$RESTORE" --file minecraft_backup_m.tar.gz --y
  assert_rc 0 "$RC" "the world is restored"
  assert_contains "$OUT" "scripts/ left as they are" "says the scripts were skipped"
  assert_not_contains "$(cat "$T/scripts/start.sh" 2>/dev/null)" "planted" "the scripts were not replaced"
}

# ── S-002/S-003: a restored server keeps runnable jars ──

test_an_hourly_restore_keeps_the_current_jars() {
  setup
  mkdir -p "$T/server/mods" "$T/server/libraries/x"
  echo jar > "$T/server/server.jar"; echo mod > "$T/server/mods/a.jar"; echo lib > "$T/server/libraries/x/l.jar"
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore exits 0"
  assert_file_content "$T/server/world/level.dat" restored "world comes from the archive"
  assert_file_content "$T/server/server.jar" jar "server.jar is kept"
  assert_file_content "$T/server/mods/a.jar" mod "mods are kept"
  assert_file_content "$T/server/libraries/x/l.jar" lib "libraries are kept"
}

test_dangling_jar_links_of_older_archives_are_repaired() {
  setup
  mkdir -p "$T/backups/jars"
  echo stored > "$T/backups/jars/server.jar"
  local src; src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world" "$src/mods"
  echo restored > "$src/world/level.dat"
  echo mod > "$src/mods/a.jar"
  ln -s ../../../jars/server.jar "$src/server.jar"
  mkdir -p "$T/backups/hourly"
  "$REAL_TAR" -cf - -C "$src" . | gzip -c > "$T/backups/hourly/minecraft_backup_old.tar.gz"
  rm -f "$T/server/server.jar"
  run_script "$RESTORE" --file minecraft_backup_old.tar.gz --y
  assert_rc 0 "$RC" "restore exits 0"
  if [[ -f "$T/server/server.jar" && ! -L "$T/server/server.jar" ]]; then _ok "server.jar is a regular file"; else _bad "server.jar is a regular file" "$(ls -l "$T/server/server.jar" 2>&1)"; fi
  assert_file_content "$T/server/server.jar" stored "taken from the stored copy"
}

# ── the replaced files are kept by default (D2) ─────────────────────────────

test_the_replaced_server_files_are_kept_by_default_and_replace_an_older_copy() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  mkdir -p "$T/server.pre-restore"
  echo stale > "$T/server.pre-restore/marker"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$T/server/world/level.dat" restored "the archive is live"
  assert_file_content "$T/server.pre-restore/world/level.dat" current "the previous world is kept"
  assert_missing "$T/server.pre-restore/marker" "the older kept copy was replaced"
  assert_contains "$OUT" "$T/server.pre-restore" "says where the old files are"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.pre-restore.*')" "no trash or pid-named copies left"
}

test_keep_old_is_still_accepted() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y --keep-old
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$T/server.pre-restore/world/level.dat" current "the previous world is kept"
}

test_discard_old_deletes_the_replaced_server_files() {
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y --discard-old
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$T/server/world/level.dat" restored "the archive is live"
  assert_missing "$T/server.pre-restore" "no copy of the old tree is kept"
  assert_eq "" "$(find "$T" -maxdepth 1 -name 'server.*')" "nothing else left either"
}

test_restore_keep_old_false_deletes_the_replaced_server_files() {
  setup
  echo 'RESTORE_KEEP_OLD="false"' >> "$T/scripts/common/variables.txt"
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore succeeds"
  assert_missing "$T/server.pre-restore" "no copy kept when the config says so"
}

# ── carry-over of what no backup contains (D5) ──────────────────────────────

test_logs_crash_reports_and_the_ledger_are_carried_over_from_the_live_tree() {
  setup
  mkdir -p "$T/server/crash-reports"
  echo crash > "$T/server/crash-reports/crash-1.txt"
  echo ledger > "$T/server/ledger.sqlite"
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$T/server/logs/latest.log" current-log "logs/ kept"
  assert_file_content "$T/server/crash-reports/crash-1.txt" crash "crash-reports/ kept"
  assert_file_content "$T/server/ledger.sqlite" ledger "ledger.sqlite kept"
  assert_contains "$OUT" "Carried over logs" "says what it carried"
}

test_carry_over_never_overwrites_what_the_archive_holds() {
  setup
  local src; src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world/region" "$src/logs"
  echo restored > "$src/world/level.dat"; echo r > "$src/world/region/r.0.0.mca"
  echo archived-log > "$src/logs/latest.log"
  make_archive_from "$T/backups/hourly/minecraft_backup_a.tar.zst" "$src"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$T/server/logs/latest.log" archived-log "the archive's logs win"
}

test_carry_over_list_is_configurable() {
  setup
  echo 'RESTORE_CARRY_OVER="ledger.sqlite"' >> "$T/scripts/common/variables.txt"
  echo ledger > "$T/server/ledger.sqlite"
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$T/server/ledger.sqlite" ledger "the listed entry is carried"
  assert_missing "$T/server/logs" "an unlisted one is not"
}

# ── safety of the archive itself ────────────────────────────────────────────

test_a_failed_restore_keeps_the_live_metadata_folder() {
  setup
  mkdir -p "$T/server/.mc-meta"
  echo live > "$T/server/.mc-meta/note"
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" restored
  export TAR_SHIM_FAIL_EXTRACT=1
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_nonzero "$RC" "the restore fails"
  assert_file_content "$T/server/.mc-meta/note" live "the live tree's .mc-meta is untouched"
}

test_the_archive_opened_for_the_checks_is_the_one_restored() {
  # TOCTOU: the file is swapped under the same name once the trusted open
  # happened (the tar shim swaps it while extracting); the opened inode wins.
  setup
  make_archive "$T/backups/hourly/minecraft_backup_a.tar.zst" opened
  make_archive "$T/elsewhere/planted.tar.zst" planted
  cat > "$T/bin/tar" <<SH
#!/bin/bash
echo "tar \$*" >> "\$SHIM_LOG"
for a in "\$@"; do [[ "\$a" == -x* ]] && mv -f "$T/elsewhere/planted.tar.zst" "$T/backups/hourly/minecraft_backup_a.tar.zst"; done
exec "$REAL_TAR" "\$@"
SH
  chmod +x "$T/bin/tar"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "restore succeeds"
  assert_file_content "$T/server/world/level.dat" opened "the content comes from the inode that passed the checks"
}

test_an_archive_with_an_escaping_symlink_is_refused() {
  setup
  local src; src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world/region"
  echo restored > "$src/world/level.dat"; echo r > "$src/world/region/r.0.0.mca"
  if ! ln -s /etc/passwd "$src/evil" 2>/dev/null || [[ ! -L "$src/evil" ]]; then
    skip "escaping symlink" "this host cannot create real symlinks"
    return
  fi
  ln -s ../../outside "$src/evil2"
  make_archive_from "$T/backups/hourly/minecraft_backup_a.tar.zst" "$src"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 1 "$RC" "refused"
  assert_contains "$OUT" "symlink" "says why"
  assert_file_content "$T/server/world/level.dat" current "world untouched"
}

test_an_archive_with_an_internal_symlink_is_accepted() {
  setup
  local src; src="$(mktemp -d "$T/arch.XXXXXX")"
  mkdir -p "$src/world/region"
  echo restored > "$src/world/level.dat"; echo r > "$src/world/region/r.0.0.mca"
  if ! ln -s world "$src/world_link" 2>/dev/null || [[ ! -L "$src/world_link" ]]; then
    skip "internal symlink" "this host cannot create real symlinks"
    return
  fi
  make_archive_from "$T/backups/hourly/minecraft_backup_a.tar.zst" "$src"
  run_script "$RESTORE" --file minecraft_backup_a.tar.zst --y
  assert_rc 0 "$RC" "a link that stays inside the tree is fine"
  assert_file_content "$T/server/world/level.dat" restored "world restored"
}

run_tests
