#!/bin/bash
# Tests for backup/automation/run_backup.sh (the supervisor) and the pure
# schedule in backup/lib/bk_schedule.sh.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

# The weekday is pinned (a Wednesday): on a Sunday the weekly tier is due first
# and the tests that expect a daily would fail.
setup() { make_fixture; trap cleanup_fixture EXIT; export DATE_SHIM_DOW=3 DATE_SHIM_DOM=15; }
RUN_BACKUP="backup/automation/run_backup.sh"

set_var() { echo "$1=\"$2\"" >> "$T/scripts/common/variables.txt"; }
generations_on() { sed -i 's|^DO_GENERATION_BACKUPS=.*|DO_GENERATION_BACKUPS="true"|' "$T/scripts/common/variables.txt"; }
archives_in() { find "$T/backups/$1" -maxdepth 1 -name 'minecraft_backup_*.tar.zst' 2>/dev/null | wc -l | tr -d '[:space:]'; }
webhook_count() { grep -c "^jq .*$1" "$SHIM_LOG" 2>/dev/null || true; }

# ── the schedule table ──────────────────────────────────────────────────────

due() { # date dow dom [max]
  ( source "$T/scripts/backup/lib/bk_schedule.sh"; bk_due_tiers "$1" "$2" "$3" "$T/backups/.backup_flags" true "${4:-3}" ) | tr '\n' ' ' | sed 's/ $//'
}

test_schedule_table() {
  setup
  mkdir -p "$T/backups/.backup_flags"
  assert_eq "daily" "$(due 2026-03-02 1 02)" "Monday 00:20: daily"
  touch "$T/backups/.backup_flags/daily_2026-03-02"
  assert_eq "" "$(due 2026-03-02 1 02)" "Monday 01:20 after a successful daily: hourly"
  rm "$T/backups/.backup_flags/daily_2026-03-02"
  echo 1 > "$T/backups/.backup_flags/attempts_daily_2026-03-02"
  assert_eq "daily" "$(due 2026-03-02 1 02)" "Monday 01:20 after a failed 00:20: daily is still due"
  echo 3 > "$T/backups/.backup_flags/attempts_daily_2026-03-02"
  assert_eq "" "$(due 2026-03-02 1 02)" "attempts exhausted: hourly"
  assert_eq "weekly daily" "$(due 2026-03-08 7 08)" "an ordinary Sunday: weekly and daily"
  assert_eq "monthly weekly daily" "$(due 2026-03-01 7 01)" "the first Sunday: all three"
  touch "$T/backups/.backup_flags/monthly_2026-03-01" "$T/backups/.backup_flags/weekly_2026-03-01"
  assert_eq "daily" "$(due 2026-03-01 7 01)" "first Sunday after monthly and weekly succeeded: daily"
  echo 3 > "$T/backups/.backup_flags/attempts_monthly_2026-03-01"
  rm "$T/backups/.backup_flags/monthly_2026-03-01"
  assert_eq "daily" "$(due 2026-03-01 7 01)" "first Sunday with the monthly given up: the rest"
  assert_eq "" "$( ( source "$T/scripts/backup/lib/bk_schedule.sh"; bk_due_tiers 2026-03-01 7 01 "$T/backups/.backup_flags" false 3 ) )" "generations off: hourly only"
}

# ── the supervisor ──────────────────────────────────────────────────────────

test_one_archive_serves_every_due_tier() {
  setup
  generations_on
  # Pretend it is the first Sunday by pre-dating nothing: fake the date through
  # a date shim that answers +%u and +%d only.
  cat > "$T/bin/date" <<SH
#!/bin/bash
case "\$1" in
  +%u) echo 7 ;;
  +%d) echo 01 ;;
  *) exec "$(PATH="${PATH#"$T/bin:"}" command -v date)" "\$@" ;;
esac
SH
  chmod +x "$T/bin/date"
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "run exits 0"
  assert_contains "$OUT" "Starting monthly backup (also due: weekly daily)" "all three tiers in one run"
  assert_eq 1 "$(archives_in archives/monthly)" "one monthly archive"
  assert_eq 1 "$(archives_in archives/weekly)" "one weekly entry"
  assert_eq 1 "$(archives_in archives/daily)" "one daily entry"
  local m w
  m="$(stat -c %i "$T"/backups/archives/monthly/minecraft_backup_*.tar.zst)"
  w="$(stat -c %i "$T"/backups/archives/weekly/minecraft_backup_*.tar.zst)"
  if [[ "$m" == "$w" ]]; then _ok "weekly shares the monthly's inode (hardlink)"; else _ok "weekly is a copy of the monthly (no hardlinks on this filesystem)"; fi
  local today; today="$(date +%F)"
  assert_exists "$T/backups/.backup_flags/monthly_$today" "monthly flag set"
  assert_exists "$T/backups/.backup_flags/weekly_$today" "weekly flag set"
  assert_exists "$T/backups/.backup_flags/daily_$today" "daily flag set"
  assert_eq 1 "$(grep -c '^zstd .*-o ' "$SHIM_LOG")" "the archive was compressed once"
}

test_a_failed_archive_run_falls_back_to_an_hourly_backup_and_counts_the_attempt() {
  setup
  generations_on
  # The archive run fails at compression (ENOSPC) but the hourly must not.
  cat > "$T/bin/zstd" <<SH
#!/bin/bash
if [[ " \$* " == *" -15 "* ]]; then export ZSTD_SHIM_ENOSPC=1; fi
exec bash "$HERE/shims/zstd" "\$@"
SH
  chmod +x "$T/bin/zstd"
  run_script "$RUN_BACKUP"
  assert_nonzero "$RC" "the failed daily is reported"
  assert_contains "$OUT" "Making an hourly backup instead" "falls back"
  assert_eq 1 "$(archives_in hourly)" "the hourly backup exists"
  assert_eq 0 "$(archives_in archives/daily)" "no daily archive"
  local today; today="$(date +%F)"
  assert_file_content "$T/backups/.backup_flags/attempts_daily_$today" 1 "one failed attempt recorded"
  assert_missing "$T/backups/.backup_flags/daily_$today" "the daily flag stays unset so the next hour retries"
  assert_contains "$OUT" "Backup cleanup complete." "cleanup still ran"
}

test_the_daily_is_retried_next_hour_and_given_up_after_the_cap() {
  setup
  generations_on
  set_var WEBHOOK_URL "https://hooks.example/x"
  set_var BACKUP_ARCHIVE_MAX_ATTEMPTS 2
  local today; today="$(date +%F)"
  mkdir -p "$T/backups/.backup_flags"
  echo 1 > "$T/backups/.backup_flags/attempts_daily_$today"
  export RSYNC_SHIM_FAIL=1
  run_script "$RUN_BACKUP"
  assert_contains "$OUT" "Starting daily backup" "a failed daily is retried the next hour"
  assert_contains "$OUT" "giving up" "the second failure reaches the cap"
  assert_logged "giving up for today" "and sends one webhook saying so"
  unset RSYNC_SHIM_FAIL
  run_script "$RUN_BACKUP"
  assert_contains "$OUT" "Starting hourly backup" "after the cap only hourly backups run"
}

test_three_skips_in_a_row_send_one_warning() {
  setup
  set_var WEBHOOK_URL "https://hooks.example/x"
  export FLOCK_SHIM_BUSY=1 MC_OPERATION_LOCK_HELD=1
  run_script "$RUN_BACKUP"; assert_rc 0 "$RC" "a skip exits 0"
  assert_contains "$OUT" "This backup was SKIPPED" "logs the skip"
  run_script "$RUN_BACKUP"
  assert_eq 0 "$(webhook_count backup_skipped)" "no warning after two skips"
  run_script "$RUN_BACKUP"
  assert_eq 1 "$(webhook_count backup_skipped)" "one warning at the third skip"
  run_script "$RUN_BACKUP"
  assert_eq 1 "$(webhook_count backup_skipped)" "not repeated on the fourth"
  unset FLOCK_SHIM_BUSY
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "a successful run"
  assert_missing "$T/backups/.backup_flags/skip_streak" "resets the streak"
}

test_a_timed_out_backup_sends_save_on_and_a_webhook() {
  setup
  set_var WEBHOOK_URL "https://hooks.example/x"
  server_running
  export TIMEOUT_SHIM_EXPIRE=1
  run_script "$RUN_BACKUP"
  assert_rc 124 "$RC" "exit 124"
  assert_logged "timeout --signal=TERM --kill-after=120 120m" "backup.sh runs under the watchdog"
  assert_logged "save-on" "save-on sent by the supervisor"
  assert_logged "timed out" "a backup_failed webhook says it timed out"
  assert_contains "$OUT" "Backup cleanup complete." "cleanup still ran"
}

test_the_timeout_is_configurable() {
  setup
  set_var BACKUP_TIMEOUT_MINUTES 45
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "run exits 0"
  assert_logged "timeout --signal=TERM --kill-after=120 45m" "BACKUP_TIMEOUT_MINUTES is honoured"
}

test_the_log_is_rotated_copy_truncate_style() {
  setup
  set_var BACKUP_LOG_MAX_MB 1
  mkdir -p "$T/scripts/backup/logs"
  head -c $((1024 * 1024 + 10)) /dev/zero > "$T/scripts/backup/logs/backup.log"
  echo old > "$T/scripts/backup/logs/backup.log.1"
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "run exits 0"
  assert_eq 0 "$(stat -c %s "$T/scripts/backup/logs/backup.log")" "the log is truncated in place"
  assert_eq $((1024 * 1024 + 10)) "$(stat -c %s "$T/scripts/backup/logs/backup.log.1")" "its content moved to .1"
  assert_file_content "$T/scripts/backup/logs/backup.log.2" old "the older rotation shifted to .2"
}

test_the_supervisor_records_the_last_run() {
  setup
  run_script "$RUN_BACKUP"
  assert_rc 0 "$RC" "run exits 0"
  assert_exists "$T/backups/.meta/last_backup.json" "status file written"
  assert_contains "$(cat "$T/backups/.meta/last_backup.json")" '"rc":0' "with the exit status"
  assert_contains "$(cat "$T/backups/.meta/last_backup.json")" '"tier":"hourly"' "and the tier"
  assert_contains "$(cat "$T/backups/.meta/last_backup.json")" '"stage":"done"' "and the final stage"
}

run_tests
