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
  assert_eq "0" "$(archive_ok "$a"; echo $?)" "archive is intact"
  assert_contains "$(archive_list "$a")" "world/level.dat" "archive holds the world"
  assert_contains "$(archive_list "$a")" ".live_dotfile" "archive holds dotfiles"
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
  assert_contains "$(archive_list "$(first_archive "$T/backups/archives/weekly")")" \
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

test_a_leftover_metadata_folder_is_not_backed_up() {
  setup
  mkdir -p "$T/server/.mc-meta"
  echo 'RCON_PASSWORD="hunter2"' > "$T/server/.mc-meta/variables.txt"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "hourly backup exits 0"
  assert_not_contains "$(archive_list "$(first_archive "$T/backups/hourly")")" ".mc-meta" "the folder is left out"
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
  assert_not_contains "$(archive_list "$(first_archive "$T/backups/hourly")")" "deleted_since.txt" "stale file not carried into the archive"
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
  # Hold the real lock the way a running backup does, rather than racing a
  # first run that finishes in about 200 ms here.
  mkdir -p "$T/backups"
  local ready="$T/lock-held"
  # /bin/sleep: the fixture's sleep shim returns at once.
  ( exec 9>"$T/backups/.backup.lock"; "$REAL_FLOCK" -n 9 && touch "$ready" && /bin/sleep 3 ) &
  local holder=$! _
  for _ in $(seq 1 50); do [[ -e "$ready" ]] && break; /bin/sleep 0.05; done
  local second_out second_rc
  second_out="$(cd "$T/scripts" && bash "$BACKUP" 2>&1)"; second_rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
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
  assert_contains "$OUT" "This backup was SKIPPED" "logs the skip"
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

test_a_failed_backup_still_runs_cleanup() {
  # S-013: with a full disk every backup fails; retention must still run, or
  # the disk never recovers by itself.
  setup
  export RSYNC_SHIM_FAIL=1
  run_script "$RUN_BACKUP"
  assert_nonzero "$RC" "the failed backup is reported"
  assert_contains "$OUT" "Backup cleanup complete." "cleanup ran anyway"
}

test_an_archive_backup_restores_to_real_jars() {
  # S-002: the archive used to swap server.jar for a link into the backups'
  # jars/ folder, which dangles once restored. Backup, restore, then look.
  setup
  mkdir -p "$T/server/mods"
  echo server-jar > "$T/server/server.jar"
  echo mod-jar > "$T/server/mods/a.jar"
  run_script "$BACKUP" --archive weekly
  assert_rc 0 "$RC" "archive backup exits 0"
  local a; a="$(first_archive "$T/backups/archives")"
  rm -f "$T/server/server.jar" "$T/server/mods/a.jar"
  run_script backup/restore.sh --archive --file "$a" --y
  assert_rc 0 "$RC" "restore exits 0"
  if [[ -f "$T/server/server.jar" && ! -L "$T/server/server.jar" ]]; then _ok "server.jar is a regular file"; else _bad "server.jar is a regular file" "$(ls -l "$T/server/server.jar" 2>&1)"; fi
  assert_file_content "$T/server/server.jar" server-jar "with the archived contents"
  assert_file_content "$T/server/mods/a.jar" mod-jar "and so are the mods"
  assert_missing "$T/server/a.jar" "no stray jar links at the top level"
}

# ── a backup needs a confirmed save ──────────────────────────────────────────

test_an_unconfirmed_save_aborts_the_backup_and_turns_saving_back_on() {
  setup
  server_running
  export SAVE_TIMEOUT_SECONDS=2
  run_script "$BACKUP"
  assert_rc 1 "$RC" "the backup fails"
  assert_contains "$OUT" "did not confirm the save" "says why"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "no archive was written"
  assert_logged "save-on" "auto-save is turned back on"
}

test_a_failed_save_off_over_rcon_aborts_without_a_console_fallback() {
  setup
  use_rcon_shim
  server_running
  export NODE_SHIM_RCON_RC=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "the backup fails"
  assert_contains "$OUT" "Could not turn auto-save off" "says why"
  assert_not_logged "stuff /save-off" "save-off was not typed into the console"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "no archive was written"
}

test_a_stopped_server_is_backed_up_without_save_commands() {
  setup
  run_script "$BACKUP"
  assert_rc 0 "$RC" "the backup succeeds"
  assert_contains "$OUT" "The server is not running" "says it copied the files as they are"
  assert_not_logged "save-off" "no save-off"
}

test_auto_save_is_back_on_before_the_archive_is_compressed() {
  setup
  server_running
  export SCREEN_SHIM_SAVE_LOG="$T/server/logs/latest.log"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "the backup succeeds"
  local on_line zstd_line
  on_line="$(grep -n 'save-on' "$SHIM_LOG" | head -n 1 | cut -d: -f1)"
  zstd_line="$(grep -n '^zstd .*-o ' "$SHIM_LOG" | head -n 1 | cut -d: -f1)"
  assert_eq 1 "$([[ -n "$on_line" && -n "$zstd_line" && "$on_line" -lt "$zstd_line" ]] && echo 1 || echo 0)" "save-on comes before compression"
}

run_tests
