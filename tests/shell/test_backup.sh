#!/bin/bash
# Characterization of backup/backup.sh and backup/automation/run_backup.sh
# (current behaviour, defects included).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"
source "$HERE/lib/signals.sh"

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

test_a_corrupt_stream_removes_the_archive_even_when_server_offline() {
  setup
  export ZSTD_SHIM_FAIL_DECOMPRESS=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "a stream that does not decompress exits 1"
  assert_contains "$OUT" "Validation failed" "says what failed"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "archive removed"
  assert_eq "" "$(find "$T/backups/hourly" -name '.minecraft_backup_*.part' 2>/dev/null)" "partial file removed"
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

# ── what a backup contains ───────────────────────────────────────────────────

test_logs_crash_reports_and_the_ledger_are_not_backed_up() {
  setup
  mkdir -p "$T/server/crash-reports" "$T/server/plugins/x/logs"
  echo crash > "$T/server/crash-reports/crash-1.txt"
  echo ledger > "$T/server/ledger.sqlite"
  echo plog > "$T/server/plugins/x/logs/debug.log"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  local listing; listing="$(archive_list "$(first_archive "$T/backups/hourly")")"
  assert_not_contains "$listing" "latest.log" "logs/ contents are left out"
  assert_not_contains "$listing" "crash-1.txt" "crash-reports/ contents are left out"
  assert_not_contains "$listing" "ledger.sqlite" "ledger.sqlite is left out"
  assert_not_contains "$listing" "debug.log" "a plugin's logs/ folder is left out too (unanchored pattern)"
  assert_contains "$listing" "world/region/r.0.0.mca" "the world is in"
}

test_extra_excludes_are_honoured() {
  setup
  export BACKUP_EXTRA_EXCLUDES="*.db plugins/cache/*"
  mkdir -p "$T/server/plugins/cache"
  echo db > "$T/server/plugins/stats.db"
  echo c > "$T/server/plugins/cache/x.bin"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  local listing; listing="$(archive_list "$(first_archive "$T/backups/hourly")")"
  assert_not_contains "$listing" "stats.db" "the extra pattern is applied"
  assert_not_contains "$listing" "x.bin" "and the folder pattern"
}

test_an_archive_without_a_world_is_rejected_with_65() {
  setup
  rm -rf "$T/server/world"
  echo cfg > "$T/server/server.properties"
  run_script "$BACKUP"
  assert_rc 65 "$RC" "exit 65"
  assert_contains "$OUT" "no level.dat" "says what is missing"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "no archive published"
  assert_eq "" "$(find "$T/backups/hourly" -name '.minecraft_backup_*.part' 2>/dev/null)" "partial file removed"
}

test_the_archive_is_decompressed_once_for_verification() {
  setup
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_eq "1" "$(grep -c '^zstd .*-d' "$SHIM_LOG")" "one decompression pass"
  assert_not_logged "zstd -t" "no separate zstd -t"
}

# ── atomic publish ───────────────────────────────────────────────────────────

test_the_archive_is_invisible_under_its_final_name_until_verified() {
  setup
  # tar shim variant: while creating, look at what the tier folder holds.
  cat > "$T/bin/tar" <<SH
#!/bin/bash
echo "tar \$*" >> "\$SHIM_LOG"
for a in "\$@"; do
  if [[ "\$a" == -c* ]]; then ls -A "$T/backups/hourly" > "$T/state/during_compress"; break; fi
done
exec "$REAL_TAR" "\$@"
SH
  chmod +x "$T/bin/tar"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_not_contains "$(grep -v '^\.' "$T/state/during_compress")" "minecraft_backup_" "nothing under a final name while compressing"
  assert_logged "-o $T/backups/hourly/.minecraft_backup_" "zstd writes the dot-prefixed partial file"
  local a; a="$(first_archive "$T/backups/hourly")"
  assert_exists "$T/backups/.meta/hourly/$(basename "$a").sha256" "a sidecar is written next to the publish, in .meta/"
  assert_contains "$(cat "$T/backups/.meta/hourly/$(basename "$a").sha256")" "$(basename "$a")" "naming the archive"
  assert_eq "" "$(find "$T/backups/hourly" -name '*.part')" "no partial file left"
}

test_a_stale_partial_file_is_removed_by_the_next_run() {
  setup
  mkdir -p "$T/backups/hourly"
  echo half > "$T/backups/hourly/.minecraft_backup_2026-01-01_00-00-00.tar.zst.part"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_missing "$T/backups/hourly/.minecraft_backup_2026-01-01_00-00-00.tar.zst.part" "stale partial removed"
  assert_contains "$OUT" "Removed stale partial archive" "and reported"
}

test_a_failed_compression_leaves_no_partial_file() {
  setup
  export ZSTD_SHIM_ENOSPC=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "exit 1"
  assert_contains "$OUT" "Compression failed" "says what failed"
  assert_eq "" "$(find "$T/backups/hourly" -name '*.part' -o -name '*.tar.zst' 2>/dev/null)" "nothing left in the tier folder"
}

# ── one failure notification, whatever ended the run ─────────────────────────

test_a_failed_rsync_sends_exactly_one_backup_failed_webhook() {
  setup
  echo 'WEBHOOK_URL="https://hooks.example/x"' >> "$T/scripts/common/variables.txt"
  export RSYNC_SHIM_FAIL=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "rsync failure exits 1"
  assert_eq 1 "$(grep -c '^jq .*backup_failed' "$SHIM_LOG")" "one backup_failed notification"
  assert_contains "$OUT" "stage 'stage'" "names the stage"
}

test_a_failed_compression_sends_exactly_one_backup_failed_webhook() {
  setup
  echo 'WEBHOOK_URL="https://hooks.example/x"' >> "$T/scripts/common/variables.txt"
  export TAR_SHIM_FAIL_CREATE=1
  run_script "$BACKUP"
  assert_rc 1 "$RC" "exit 1"
  assert_eq 1 "$(grep -c '^jq .*backup_failed' "$SHIM_LOG")" "one backup_failed notification"
  assert_contains "$OUT" "stage 'compress'" "names the stage"
}

test_a_skipped_run_sends_no_failure_webhook_and_no_player_message() {
  setup
  echo 'WEBHOOK_URL="https://hooks.example/x"' >> "$T/scripts/common/variables.txt"
  server_running
  export FLOCK_SHIM_BUSY=1 MC_OPERATION_LOCK_HELD=1
  run_script "$BACKUP"
  assert_rc 75 "$RC" "exit 75"
  assert_not_logged "backup_failed" "no failure notification for a skip"
  assert_not_logged "Starting hourly backup" "players are not told about a backup that did not start"
}

test_dry_run_tells_no_one() {
  setup
  server_running
  run_script "$BACKUP" --dry-run
  assert_rc 0 "$RC" "dry run exits 0"
  assert_not_logged "Starting hourly backup" "no player broadcast"
  assert_not_logged "save-off" "no save-off"
}

test_a_term_during_compression_turns_saving_on_before_removing_staging() {
  if signals_unreliable "TERM during compression"; then return; fi
  setup
  echo 'WEBHOOK_URL="https://hooks.example/x"' >> "$T/scripts/common/variables.txt"
  server_running
  export SCREEN_SHIM_SAVE_LOG="$T/server/logs/latest.log" BACKUP_STAGING_MODE=fresh
  export ZSTD_SHIM_STALL="$T/state/zstd"
  local pid
  set -m
  # exec: the backgrounded process is backup.sh itself, so its exit status is
  # what wait reports and nothing is left to kill once it has finished.
  ( cd "$T/scripts" && exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV' -- bash "$BACKUP" > "$T/out" 2>&1 < /dev/null ) &
  pid=$!
  set +m
  signal_when_started TERM "$pid" "$T/state/zstd.started" "$T/state/zstd.release"
  assert_eq 143 "$SIGNAL_STATUS" "exit 143 after the EXIT handler"
  assert_logged "save-on" "save-on sent"
  assert_eq "" "$(find "$T/backups/hourly" -name '*.part' 2>/dev/null)" "partial file removed"
  assert_missing "$T/backups/.stage/snap" "per-run staging removed"
  assert_eq 1 "$(grep -c '^jq .*backup_failed' "$SHIM_LOG")" "one backup_failed notification"
  assert_contains "$(cat "$T/out")" "interrupted" "says it was interrupted"
}

# ── priority wrapper ─────────────────────────────────────────────────────────

test_a_refused_ionice_does_not_fail_the_backup() {
  setup
  export IONICE_SHIM_FAIL=1
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0 although ionice refuses"
  assert_logged "ionice -c2 -n7 -t true" "ionice is probed with -t"
  assert_exists "$(first_archive "$T/backups/hourly")" "archive written"
}

test_a_working_ionice_wraps_rsync_and_tar() {
  setup
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_logged "ionice -c2 -n7 -t nice -n 10 rsync" "rsync runs under ionice and nice"
  assert_logged "ionice -c2 -n7 -t nice -n 10 tar" "tar too"
}

test_without_ionice_nice_alone_is_used() {
  setup
  rm -f "$T/bin/ionice"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_not_logged "ionice" "no ionice call"
  assert_contains "$OUT" "priority wrapper: nice -n 10" "nice alone"
}

# ── levels and threads ───────────────────────────────────────────────────────

test_hourly_uses_the_configured_level_and_a_thread_cap() {
  setup
  export BACKUP_ZSTD_THREADS=2
  run_script "$BACKUP"
  assert_logged "zstd-level 3" "hourly uses COMPRESSION_LEVEL (3 in the fixture)"
  assert_logged "zstd-threads 2" "BACKUP_ZSTD_THREADS is passed as -T"
  run_script "$BACKUP" --archive weekly
  assert_logged "zstd-level 15" "archives use at least level 15"
}

test_hourly_and_archive_levels_can_be_set_separately() {
  setup
  export BACKUP_HOURLY_LEVEL=1 BACKUP_ARCHIVE_LEVEL=19
  run_script "$BACKUP"
  assert_logged "zstd-level 1" "BACKUP_HOURLY_LEVEL wins for hourly"
  run_script "$BACKUP" --archive weekly
  assert_logged "zstd-level 19" "BACKUP_ARCHIVE_LEVEL wins for archives"
}

test_the_default_thread_count_is_capped() {
  setup
  run_script "$BACKUP"
  local t; t="$(grep '^zstd-threads' "$SHIM_LOG" | head -n1 | cut -d' ' -f2)"
  assert_eq 1 "$([[ "$t" =~ ^[0-9]+$ && "$t" -ge 1 && "$t" -le 4 ]] && echo 1 || echo 0)" "between 1 and 4 by default (got '$t')"
}

test_a_bad_compression_level_is_a_config_error() {
  setup
  sed -i 's|^COMPRESSION_LEVEL=.*|COMPRESSION_LEVEL="fast"|' "$T/scripts/common/variables.txt"
  run_script "$BACKUP"
  assert_rc 1 "$RC" "exit 1"
  assert_contains "$OUT" "COMPRESSION_LEVEL" "names the key"
}

# ── staging modes ────────────────────────────────────────────────────────────

test_mirror_mode_keeps_a_persistent_mirror_and_excludes_jars_only_in_the_tar() {
  setup
  server_running
  export SCREEN_SHIM_SAVE_LOG="$T/server/logs/latest.log"
  export BACKUP_STAGING_MODE=mirror
  echo jar > "$T/server/server.jar"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_exists "$T/backups/.stage/mirror/world/level.dat" "the mirror persists after the run"
  assert_exists "$T/backups/.stage/mirror/server.jar" "the mirror holds the jars"
  assert_not_contains "$(archive_list "$(first_archive "$T/backups/hourly")")" "server.jar" "the hourly archive leaves them out"
  assert_missing "$T/backups/.stage/MIRROR_INCOMPLETE" "the marker is gone after a complete refresh"
  assert_contains "$OUT" "auto-save was off for" "the save-off duration is logged"
}

test_a_file_deleted_on_the_server_disappears_from_the_mirror() {
  setup
  export BACKUP_STAGING_MODE=mirror
  echo gone > "$T/server/old.txt"
  run_script "$BACKUP"
  rm "$T/server/old.txt"
  rm -f "$T"/backups/hourly/*.tar.zst
  run_script "$BACKUP"
  assert_rc 0 "$RC" "second backup exits 0"
  assert_missing "$T/backups/.stage/mirror/old.txt" "deleted on the server, deleted in the mirror"
  assert_not_contains "$(archive_list "$(first_archive "$T/backups/hourly")")" "old.txt" "and not in the archive"
}

test_an_incomplete_mirror_is_not_archived() {
  setup
  export BACKUP_STAGING_MODE=mirror RSYNC_SHIM_EXIT=11
  run_script "$BACKUP"
  assert_rc 1 "$RC" "the run fails"
  assert_exists "$T/backups/.stage/MIRROR_INCOMPLETE" "the mirror is marked incomplete"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "nothing archived from it"
  unset RSYNC_SHIM_EXIT
  run_script "$BACKUP"
  assert_rc 0 "$RC" "the next run heals the mirror"
  assert_missing "$T/backups/.stage/MIRROR_INCOMPLETE" "and clears the marker"
}

test_vanished_files_are_a_warning_not_a_failure() {
  setup
  export RSYNC_SHIM_EXIT=24
  run_script "$BACKUP"
  assert_rc 0 "$RC" "rsync 24 does not fail the backup"
  assert_contains "$OUT" "some files vanished" "it is logged"
}

test_fresh_mode_leaves_no_staging_behind() {
  setup
  export BACKUP_STAGING_MODE=fresh
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_exists "$(first_archive "$T/backups/hourly")" "archive written"
  assert_missing "$T/backups/.stage/snap" "the per-run snapshot is removed"
  assert_missing "$T/backups/.stage/mirror" "no mirror in fresh mode"
}

test_archive_runs_verify_the_mirror_by_checksum() {
  setup
  export BACKUP_STAGING_MODE=mirror
  run_script "$BACKUP" --archive daily
  assert_logged "--checksum" "an archive run compares by checksum"
  : > "$SHIM_LOG"
  run_script "$BACKUP"
  assert_not_logged "--checksum" "an hourly run uses the quick check"
}

test_a_server_that_starts_during_the_copy_fails_the_run() {
  setup
  export BACKUP_STAGING_MODE=fresh
  cat > "$T/bin/rsync" <<SH
#!/bin/bash
touch "$T/state/screen_running"
exec bash "$HERE/shims/rsync" "\$@"
SH
  chmod +x "$T/bin/rsync"
  run_script "$BACKUP"
  assert_rc 1 "$RC" "the run fails"
  assert_contains "$OUT" "started while its files were being copied" "says why"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "nothing published"
}

# ── space preflight ──────────────────────────────────────────────────────────

test_a_short_disk_makes_room_before_the_backup() {
  setup
  export BACKUP_STAGING_MODE=fresh
  mkdir -p "$T/backups/hourly"
  head -c 100 /dev/zero > "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst"
  # Half the (tiny) server plus the server itself is well under 1 MB; 10 bytes free is not.
  cat > "$T/bin/df" <<SH
#!/bin/bash
echo "df \$*" >> "\$SHIM_LOG"
if [[ -e "$T/state/evicted" ]]; then printf 'Avail\\n%s\\n' 1073741824; else printf 'Avail\\n%s\\n' 10; fi
SH
  chmod +x "$T/bin/df"
  cat > "$T/bin/rm" <<SH
#!/bin/bash
touch "$T/state/evicted"
exec "$(PATH="${PATH#"$T/bin:"}" command -v rm)" "\$@"
SH
  chmod +x "$T/bin/rm"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "the backup succeeds after eviction"
  assert_contains "$OUT" "asking cleanup to free" "the preflight asked for room"
  assert_contains "$OUT" "to make room" "cleanup evicted"
  assert_missing "$T/backups/hourly/minecraft_backup_2026-01-01_00-00-00.tar.zst" "the old archive went"
}

test_a_disk_that_stays_short_fails_with_73_and_a_webhook() {
  setup
  echo 'WEBHOOK_URL="https://hooks.example/x"' >> "$T/scripts/common/variables.txt"
  export DF_SHIM_AVAIL=10
  run_script "$BACKUP"
  assert_rc 73 "$RC" "exit 73"
  assert_contains "$OUT" "not enough free space" "says why"
  assert_eq 1 "$(grep -c '^jq .*backup_failed' "$SHIM_LOG")" "one backup_failed notification"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "nothing written"
}

# ── several tiers from one archive ───────────────────────────────────────────

test_extra_tiers_get_the_same_archive_and_their_own_sidecar() {
  setup
  export BK_EXTRA_TIERS="weekly daily"
  run_script "$BACKUP" --archive monthly
  assert_rc 0 "$RC" "backup exits 0"
  local m; m="$(first_archive "$T/backups/archives/monthly")"
  assert_exists "$T/backups/archives/weekly/$(basename "$m")" "weekly entry"
  assert_exists "$T/backups/archives/daily/$(basename "$m")" "daily entry"
  assert_exists "$T/backups/.meta/archives/weekly/$(basename "$m").sha256" "weekly sidecar"
  assert_eq 1 "$(grep -c '^zstd .*-o ' "$SHIM_LOG")" "compressed once"
}

test_the_status_file_describes_the_last_run() {
  setup
  run_script "$BACKUP"
  local j; j="$(cat "$T/backups/.meta/last_backup.json")"
  assert_contains "$j" '"rc":0' "rc"
  assert_contains "$j" '"tier":"hourly"' "tier"
  assert_contains "$j" '"file":"hourly/minecraft_backup_' "file"
  assert_contains "$j" '"level":3' "level"
  assert_contains "$j" '"stage":"done"' "stage"
  export RSYNC_SHIM_FAIL=1
  run_script "$BACKUP"
  j="$(cat "$T/backups/.meta/last_backup.json")"
  assert_contains "$j" '"rc":1' "a failure is recorded too"
  assert_contains "$j" '"stage":"stage"' "with the stage it failed at"
}


# ── the mirror must be private to this user ──────────────────────────────────

mode_has_no_group_or_other_write() { # path
  local m; m="$(stat -c %a "$1")"
  (( (10#${m: -2:1} & 2) == 0 && (10#${m: -1:1} & 2) == 0 )) && echo yes || echo "no ($m)"
}

test_a_world_writable_mirror_is_tightened_before_use() {
  setup
  export BACKUP_STAGING_MODE=mirror
  mkdir -p "$T/backups/.stage/mirror"
  chmod 777 "$T/backups/.stage" "$T/backups/.stage/mirror"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_contains "$OUT" "Staging mode: mirror" "the mirror is used once private"
  assert_eq yes "$(mode_has_no_group_or_other_write "$T/backups/.stage/mirror")" "the mirror is no longer writable by others"
  assert_eq yes "$(mode_has_no_group_or_other_write "$T/backups/.stage")" "nor is .stage"
  assert_eq yes "$(mode_has_no_group_or_other_write "$T/backups/.meta")" "nor is .meta"
}

test_a_mirror_that_cannot_be_made_private_is_not_used() {
  setup
  export BACKUP_STAGING_MODE=mirror
  # An id that reports another uid stands in for a mirror owned by someone else.
  cat > "$T/bin/id" <<SH
#!/bin/bash
[[ "\$1" == -u ]] && { echo 4242; exit 0; }
exec "$(PATH="${PATH#"$T/bin:"}" command -v id)" "\$@"
SH
  chmod +x "$T/bin/id"
  run_script "$BACKUP"
  assert_nonzero "$RC" "the run fails rather than trusting a sidecar folder owned by someone else"
  assert_contains "$OUT" "not private to this user" "says why"
  rm -f "$T/bin/id"
  # Only the mirror foreign: .meta is fine, so the run falls back to a fresh copy.
  cat > "$T/bin/stat" <<SH
#!/bin/bash
if [[ "\$*" == *"$T/backups/.stage/mirror" ]]; then echo "4242 700"; exit 0; fi
exec "$(PATH="${PATH#"$T/bin:"}" command -v stat)" "\$@"
SH
  chmod +x "$T/bin/stat"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_contains "$OUT" "using a fresh copy for this run" "falls back"
  assert_contains "$OUT" "Staging mode: fresh" "and runs in fresh mode"
  assert_exists "$(first_archive "$T/backups/hourly")" "archive written"
}


test_a_staging_folder_that_cannot_be_made_private_ends_the_run() {
  setup
  cat > "$T/bin/stat" <<SH
#!/bin/bash
if [[ "\$*" == *"$T/backups/.stage" ]]; then echo "4242 700"; exit 0; fi
exec "$(PATH="${PATH#"$T/bin:"}" command -v stat)" "\$@"
SH
  chmod +x "$T/bin/stat"
  run_script "$BACKUP"
  assert_rc 1 "$RC" "the run fails closed"
  assert_contains "$OUT" "staging folder" "names the folder"
  assert_eq "" "$(first_archive "$T/backups/hourly")" "nothing written"
}

test_privacy_is_enforced_below_the_mirror_too() {
  setup
  export BACKUP_STAGING_MODE=mirror
  mkdir -p "$T/backups/.stage/mirror/world" "$T/backups/.meta/hourly"
  chmod 777 "$T/backups/.stage/mirror/world" "$T/backups/.meta/hourly"
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_eq yes "$(mode_has_no_group_or_other_write "$T/backups/.stage/mirror/world")" "a folder inside the mirror is tightened"
  assert_eq yes "$(mode_has_no_group_or_other_write "$T/backups/.meta/hourly")" "and one inside .meta"
}


test_a_symlink_inside_the_mirror_does_not_make_it_unprivate() {
  setup
  export BACKUP_STAGING_MODE=mirror
  if ! ln -s world/level.dat "$T/server/level_link" 2>/dev/null || [[ ! -L "$T/server/level_link" ]]; then
    skip "symlink in the mirror" "this host cannot create real symlinks"
    return
  fi
  run_script "$BACKUP"
  assert_rc 0 "$RC" "backup exits 0"
  assert_contains "$OUT" "Staging mode: mirror" "the mirror stays in use"
  assert_not_contains "$OUT" "writable by others" "a link's 777 mode is not a privacy failure"
  rm -f "$T"/backups/hourly/*.tar.zst
  run_script "$BACKUP"
  assert_rc 0 "$RC" "the second run, with the link now inside the mirror, exits 0"
  assert_contains "$OUT" "Staging mode: mirror" "and still uses the mirror"
}

run_tests
