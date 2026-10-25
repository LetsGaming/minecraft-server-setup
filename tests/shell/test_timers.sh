#!/bin/bash
# Tests for the systemd timer helpers (src/setup/management/timer_lib.sh) and for
# create_backup_job.sh / create_restart_job.sh when systemd is available. systemctl
# is a shim that records its calls; units are written into a scratch folder
# with no sudo.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

REPO="$(cd "$HERE/../.." && pwd)"
MGMT="$REPO/src/setup/management"

setup() {
  make_fixture; trap cleanup_fixture EXIT
  use_install_layout
  mkdir -p "$R/scripts/testinst/backup/automation" "$R/scripts/testinst/backup/logs" "$T/units"
  : > "$R/scripts/testinst/backup/automation/run_backup.sh"
  : > "$R/scripts/testinst/backup/automation/scheduled_restart.sh"
  export MAIN_DIR="$T" TARGET_DIR_NAME="mc-root" INSTANCE_NAME="testinst" USER="tester" SYSTEMD_UNIT_DIR="$T/units"
  export SYSTEMD_USABLE=true TIMER_SUDO=""
  cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
f="$SHIM_STATE/crontab"
case "$1" in
  -l) [[ -f "$f" ]] || { echo "no crontab for tester" >&2; exit 1; }; cat "$f" ;;
  -) cat > "$f" ;;
esac
SH
  chmod +x "$T/bin/crontab"
}

run_mgmt() { # script ; sets OUT and RC
  OUT="$(bash "$MGMT/$1" 2>&1 < /dev/null)"
  RC=$?
}

in_lib() { ( source "$MGMT/timer_lib.sh"; "$@" ); }

restart_vars() { # hours
  printf 'RESTART_ENABLED="true"\nRESTART_INTERVAL_HOURS="%s"\n' "$1" >> "$R/scripts/testinst/common/variables.txt"
}

count_calls() { grep -c -- "$1" "$SHIM_LOG" 2> /dev/null || true; }

# ── pure helpers ─────────────────────────────────────────────────────────────

test_the_restart_calendar_follows_the_cron_rules() {
  setup
  assert_eq "*-*-* 00/12:00:00" "$(in_lib timer_restart_calendar 12)" "every 12 hours"
  assert_eq "*-*-* 00/1:00:00" "$(in_lib timer_restart_calendar 1)" "every hour"
  assert_eq "*-*-* 00:00:00" "$(in_lib timer_restart_calendar 24)" "daily at midnight"
  assert_eq "*-*-1/2 00:00:00" "$(in_lib timer_restart_calendar 48)" "every second day"
  assert_eq "*-*-* 00/6:00:00" "$(in_lib timer_restart_calendar 06)" "a leading zero is not read as octal"
  in_lib timer_restart_calendar 5 > /dev/null; assert_nonzero "$?" "5 does not divide a day"
  in_lib timer_restart_calendar 36 > /dev/null; assert_nonzero "$?" "36 is neither a divisor nor a multiple of 24"
  in_lib timer_restart_calendar "" > /dev/null; assert_nonzero "$?" "empty is refused"
  in_lib timer_restart_calendar 1x > /dev/null; assert_nonzero "$?" "text is refused"
}

test_quoting_protects_systemd_specifiers_and_variables() {
  setup
  assert_eq '"/a b/c"' "$(in_lib timer_quote "/a b/c")" "a space is grouped by the quotes"
  assert_eq '"100%%/x"' "$(in_lib timer_quote "100%/x")" "% is doubled"
  assert_eq '"$$HOME/x"' "$(in_lib timer_quote '$HOME/x')" "a dollar sign is doubled"
  assert_eq '"a\"b"' "$(in_lib timer_quote 'a"b')" "a quote is escaped"
  in_lib timer_quote $'a\nb' > /dev/null 2>&1; assert_nonzero "$?" "a newline is refused"
}

test_systemd_usable_can_be_forced_either_way() {
  setup
  SYSTEMD_USABLE=true in_lib systemd_usable; assert_rc 0 "$?" "forced true"
  SYSTEMD_USABLE=false in_lib systemd_usable; assert_rc 1 "$?" "forced false"
}

# ── the units ────────────────────────────────────────────────────────────────

test_the_service_has_no_sandboxing_that_would_break_sudo_or_screen() {
  setup
  local unit
  unit="$(in_lib timer_render_service "Backup" "/x/run backup.sh" "/x/logs/backup.log" "/x")"
  assert_contains "$unit" "Type=oneshot" "a oneshot service"
  assert_contains "$unit" "User=tester" "runs as the server owner"
  assert_contains "$unit" '"/x/run backup.sh"' "the script path is quoted"
  assert_contains "$unit" '"/x/logs/backup.log"' "the log path is passed to the job shell, quoted"
  assert_contains "$unit" "exec >>\"\$\$0\" 2>&1" "the job shell appends to the old log file after the privilege drop"
  assert_not_contains "$unit" "StandardOutput=append" "systemd does not open the log as root (a planted symlink would be followed)"
  assert_not_contains "$unit" "StandardOutput=file" "nor any other file output"
  assert_contains "$unit" "WorkingDirectory=/x" "the working directory is set"
  assert_contains "$unit" "TimeoutStartSec=3h" "a ceiling for a stuck job"
  assert_contains "$unit" '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "a full PATH, as cron's wrapper sets"
  assert_not_contains "$unit" "NoNewPrivileges" "sudo keeps working"
  assert_not_contains "$unit" "PrivateTmp" "screen's sockets stay reachable"
  assert_not_contains "$unit" "ProtectSystem" "no read-only system folders"
}

test_the_timer_fires_on_the_calendar_without_catching_up_by_default() {
  setup
  local unit
  unit="$(in_lib timer_render_timer "Backup" "*-*-* *:20:00")"
  assert_contains "$unit" "OnCalendar=*-*-* *:20:00" "the schedule"
  assert_contains "$unit" "Persistent=false" "no catch-up run at boot, like cron"
  assert_contains "$unit" "WantedBy=timers.target" "enabled with the timers"
  assert_not_contains "$unit" "RandomizedDelaySec" "no random delay unless asked"
  unit="$(in_lib timer_render_timer "Pull" "*-*-* 05:15:00" true 300)"
  assert_contains "$unit" "Persistent=true" "catch-up when asked"
  assert_contains "$unit" "RandomizedDelaySec=300s" "and a random delay"
}

test_install_writes_both_units_reloads_and_enables_the_timer() {
  setup
  in_lib timer_install backup "Hourly backup" "$R/scripts/testinst/backup/automation/run_backup.sh" "*-*-* *:20:00" "$R/scripts/testinst/backup/logs/backup.log" false "$R/scripts/testinst" > /dev/null
  assert_exists "$T/units/testinst-backup.service" "the service is written"
  assert_exists "$T/units/testinst-backup.timer" "the timer is written"
  assert_logged "systemctl daemon-reload" "systemd is told about the new units"
  assert_logged "systemctl enable --now testinst-backup.timer" "the timer is enabled and started"
}

test_installing_again_changes_nothing_and_does_not_reload() {
  setup
  local args=(backup "Hourly backup" "$R/scripts/testinst/backup/automation/run_backup.sh" "*-*-* *:20:00" "$R/scripts/testinst/backup/logs/backup.log" false "$R/scripts/testinst")
  in_lib timer_install "${args[@]}" > /dev/null
  local before; before="$(count_calls "daemon-reload")"
  in_lib timer_install "${args[@]}" > /dev/null; assert_rc 0 "$?" "the second run succeeds"
  assert_eq "$before" "$(count_calls "daemon-reload")" "unchanged units cause no daemon-reload"
  assert_eq 2 "$(count_calls "enable --now testinst-backup.timer")" "enabling is repeated, it is idempotent"
}

test_a_changed_schedule_rewrites_the_timer() {
  setup
  local run="$R/scripts/testinst/backup/automation/scheduled_restart.sh" log="$R/scripts/testinst/backup/logs/restart.log"
  in_lib timer_install restart "Restart" "$run" "*-*-* 00/12:00:00" "$log" false > /dev/null
  in_lib timer_install restart "Restart" "$run" "*-*-* 00/6:00:00" "$log" false > /dev/null
  assert_contains "$(cat "$T/units/testinst-restart.timer")" "OnCalendar=*-*-* 00/6:00:00" "the new interval replaces the old one"
  assert_eq 2 "$(count_calls "daemon-reload")" "and systemd reloads for it"
}

test_remove_deletes_both_units_and_tolerates_missing_ones() {
  setup
  in_lib timer_install backup "Hourly backup" "$R/scripts/testinst/backup/automation/run_backup.sh" "*-*-* *:20:00" "$R/scripts/testinst/backup/logs/backup.log" > /dev/null
  in_lib timer_remove backup; assert_rc 0 "$?" "removed"
  assert_missing "$T/units/testinst-backup.timer" "the timer is gone"
  assert_missing "$T/units/testinst-backup.service" "and the service"
  in_lib timer_remove backup; assert_rc 0 "$?" "removing again is fine"
}

# ── the job scripts with systemd ─────────────────────────────────────────────

test_the_backup_job_becomes_a_timer_not_a_cron_line() {
  setup
  run_mgmt create_backup_job.sh
  assert_rc 0 "$RC" "installed"
  assert_contains "$(cat "$T/units/testinst-backup.timer")" "OnCalendar=*-*-* *:20:00" "at minute 20, as the cron line was"
  assert_contains "$(cat "$T/units/testinst-backup.service")" "run_backup.sh" "it runs the backup wrapper"
  assert_missing "$SHIM_STATE/crontab" "the crontab is not touched"
}

test_an_old_cron_line_is_reported_not_removed() {
  setup
  printf '20 * * * * bash %s/scripts/testinst/backup/automation/run_backup.sh >> /dev/null 2>&1\n' "$R" > "$SHIM_STATE/crontab"
  run_mgmt create_backup_job.sh
  assert_rc 0 "$RC" "installed"
  assert_contains "$OUT" "migrate.sh" "the operator is pointed at the migration"
  assert_eq 1 "$(grep -c run_backup.sh "$SHIM_STATE/crontab")" "the cron line is left for the migration"
}

test_the_restart_job_becomes_a_timer_with_the_matching_calendar() {
  setup
  restart_vars 6
  run_mgmt create_restart_job.sh
  assert_rc 0 "$RC" "installed"
  assert_contains "$(cat "$T/units/testinst-restart.timer")" "OnCalendar=*-*-* 00/6:00:00" "every 6 hours"
  assert_missing "$SHIM_STATE/crontab" "no cron line"
}

test_a_disabled_restart_schedule_installs_nothing() {
  setup
  run_mgmt create_restart_job.sh
  assert_rc 0 "$RC" "nothing to do"
  assert_missing "$T/units/testinst-restart.timer" "no timer"
}

test_the_restart_interval_must_still_divide_a_day_with_timers() {
  setup
  restart_vars 5
  run_mgmt create_restart_job.sh
  assert_rc 1 "$RC" "5 hours is refused"
  assert_contains "$OUT" "must divide 24" "says why"
  assert_missing "$T/units/testinst-restart.timer" "no timer was written"
}

test_without_systemd_the_backup_job_is_still_a_cron_line() {
  setup
  export SYSTEMD_USABLE=false
  run_mgmt create_backup_job.sh
  assert_rc 0 "$RC" "installed"
  assert_contains "$(cat "$SHIM_STATE/crontab")" "20 * * * * bash" "the fallback is cron"
  assert_missing "$T/units/testinst-backup.timer" "no timer"
}

run_tests
