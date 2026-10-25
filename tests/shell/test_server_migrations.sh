#!/bin/bash
# Tests for migrate-lib/server_migrations.sh and how migrate.sh uses it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

ROOT="$(cd "$HERE/../.." && pwd)"
NEW_START="$ROOT/src/vanilla/start.sh"

OLD_UNIT='[Unit]
Description=testinst Server
After=network.target

[Service]
User=tester
ExecStart=/usr/bin/screen -DmS testinst /usr/bin/bash /srv/instances/testinst/start.sh
Restart=always
RestartSec=3s
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
'

# POSIX permission bits are only simulated on some hosts (Git Bash on NTFS).
perms_work() {
  local f="$T/.permprobe"
  : > "$f"; chmod 750 "$f"
  [[ "$(stat -c %a "$f")" == 750 ]]
}

# A fake install: an instance dir with an old start.sh, a scripts dir, a unit dir.
setup() {
  make_fixture; trap cleanup_fixture EXIT
  export SM_SOURCE_ROOT="$ROOT"
  export SM_INSTANCE_DIR="$T/instance"
  export SM_INSTANCE_NAME="testinst"
  export SM_SCRIPTS_DIR="$T/scripts"
  export SM_UNIT_DIR="$T/units"
  export SM_SUDO=""
  export SM_DRY_RUN=false
  mkdir -p "$SM_INSTANCE_DIR" "$SM_UNIT_DIR"
  printf '#!/bin/bash\necho old start\n' > "$SM_INSTANCE_DIR/start.sh"
  chmod 750 "$SM_INSTANCE_DIR/start.sh"
  printf '%s' "$OLD_UNIT" > "$SM_UNIT_DIR/testinst.service"
  # shellcheck source=/dev/null
  source "$ROOT/migrate-lib/server_migrations.sh"
}

test_an_old_install_has_the_file_migrations_pending() {
  setup
  sm_plan > /dev/null
  assert_eq "instance_start_script unit_start_limits" "${SM_PENDING[*]}" "both are detected from the real files"
}

test_start_script_is_replaced_and_the_old_copy_kept() {
  setup
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_eq 0 "$(cmp -s "$NEW_START" "$SM_INSTANCE_DIR/start.sh" && echo 0 || echo 1)" "start.sh is now the suite's"
  if perms_work; then
    assert_eq "750" "$(stat -c %a "$SM_INSTANCE_DIR/start.sh")" "its permissions are kept"
  else
    skip "permissions are kept" "this host does not keep POSIX permission bits"
  fi
  local kept
  kept="$(ls "$SM_INSTANCE_DIR"/start.sh.pre-migrate-* 2> /dev/null | head -1)"
  assert_contains "$(cat "$kept")" "old start" "the previous file is kept next to it"
  assert_eq true "$SM_NEEDS_RESTART" "the caller is told it takes effect at the next restart"
  local f leftover=""
  for f in "$SM_INSTANCE_DIR"/*; do
    [[ "$(basename "$f")" =~ migrate-[0-9]*$ ]] && leftover+="$(basename "$f") "
  done
  assert_eq "" "$leftover" "no temp file is left behind"
}

test_a_current_start_script_is_left_alone() {
  setup
  cp "$NEW_START" "$SM_INSTANCE_DIR/start.sh"
  sm_plan > /dev/null
  assert_eq "unit_start_limits" "${SM_PENDING[*]}" "only the unit is pending"
  assert_eq 0 "$(ls "$SM_INSTANCE_DIR"/start.sh.pre-migrate-* 2> /dev/null | wc -l | tr -d ' ')" "no copy is made when nothing changes"
}

test_a_missing_start_script_is_not_invented() {
  setup
  rm "$SM_INSTANCE_DIR/start.sh"
  sm_plan > /dev/null
  assert_eq "unit_start_limits" "${SM_PENDING[*]}" "an instance without start.sh is not this migration's business"
}

test_unit_gets_the_crash_loop_limits_after_restartsec() {
  setup
  sm_plan > /dev/null
  sm_apply > /dev/null
  local unit
  unit="$(cat "$SM_UNIT_DIR/testinst.service")"
  assert_contains "$unit" "StartLimitBurst=5" "the burst limit is added"
  assert_contains "$unit" "StartLimitIntervalSec=120" "and the window"
  assert_contains "$unit" "StartLimitAction=none" "and the action"
  assert_eq "" "$(awk '/^\[/{s=$0} s=="[Service]" && /^StartLimit/' <<< "$unit")" "in [Unit], where systemd reads them (S-016)"
  assert_contains "$unit" "LimitNOFILE=4096" "the rest of the unit is untouched"
  assert_eq "RestartSec=3s" "$(grep -B0 -A0 '^RestartSec' <<< "$unit")" "RestartSec is unchanged"
  assert_logged "systemctl daemon-reload" "systemd is told, without a restart"
  assert_not_logged "systemctl restart" "the server is not restarted"
  local f kept=0
  for f in "$SM_SCRIPTS_DIR"/common/migration-backups/testinst.service.*; do
    [[ -e "$f" && "$f" != *patched* ]] && kept=$((kept + 1))
  done
  assert_eq 1 "$kept" "the old unit is kept"
}

test_limits_in_unit_are_left_alone() {
  setup
  printf '%s' "${OLD_UNIT/\[Unit\]/[Unit]
StartLimitBurst=10}" > "$SM_UNIT_DIR/testinst.service"
  sm_plan > /dev/null
  assert_eq "instance_start_script" "${SM_PENDING[*]}" "the operator's own [Unit] StartLimit settings win"
}

test_limits_in_service_move_to_unit_keeping_their_values() {
  # S-016: systemd ignores StartLimit* in [Service]; units written that way
  # never stopped a crash loop. Their values move to [Unit].
  setup
  printf '%s' "${OLD_UNIT/RestartSec=3s/RestartSec=3s
StartLimitIntervalSec=300
StartLimitBurst=10}" > "$SM_UNIT_DIR/testinst.service"
  sm_plan > /dev/null
  assert_contains "${SM_PENDING[*]}" "unit_start_limits" "a unit with the limits in [Service] is pending"
  sm_apply > /dev/null
  local unit
  unit="$(cat "$SM_UNIT_DIR/testinst.service")"
  assert_eq $'StartLimitIntervalSec=300\nStartLimitBurst=10' "$(awk '/^\[/{s=$0} s=="[Unit]" && /^StartLimit/' <<< "$unit")" "the operator's values now sit in [Unit]"
  assert_eq "" "$(awk '/^\[/{s=$0} s=="[Service]" && /^StartLimit/' <<< "$unit")" "and none are left in [Service]"
  sm_plan > /dev/null
  assert_not_contains "${SM_PENDING[*]}" "unit_start_limits" "applied once, it is done"
}

test_a_unit_that_does_not_exist_is_skipped() {
  setup
  rm "$SM_UNIT_DIR/testinst.service"
  sm_plan > /dev/null
  assert_eq "instance_start_script" "${SM_PENDING[*]}" "no unit, nothing to patch"
}

test_running_twice_changes_nothing_the_second_time() {
  setup
  sm_plan > /dev/null
  sm_apply > /dev/null
  sm_plan > /dev/null
  assert_eq 0 "${#SM_PENDING[@]}" "nothing is pending after a successful run"
  sm_apply > /dev/null
  assert_eq 1 "$(ls "$SM_INSTANCE_DIR"/start.sh.pre-migrate-* | wc -l | tr -d ' ')" "and no second copy is made"
}

test_a_dry_run_changes_nothing() {
  setup
  export SM_DRY_RUN=true
  sm_plan > /dev/null
  local out
  out="$(sm_apply)"
  assert_contains "$out" "[DRY-RUN] server migration: instance_start_script" "it says what it would do"
  assert_contains "$(cat "$SM_INSTANCE_DIR/start.sh")" "old start" "start.sh is untouched"
  assert_not_contains "$(cat "$SM_UNIT_DIR/testinst.service")" "StartLimit" "the unit is untouched"
  assert_eq false "$(test -f "$SM_SCRIPTS_DIR/common/server-migrations.log" && echo true || echo false)" "nothing is recorded"
}

test_results_are_recorded_and_listed() {
  setup
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_contains "$(cat "$SM_SCRIPTS_DIR/common/server-migrations.log")" "instance_start_script applied" "the log names the migration and its result"
  local listing
  listing="$(sm_list)"
  assert_contains "$listing" "instance_start_script" "the list names it"
  assert_contains "$listing" "current" "as current"
  assert_contains "$listing" "last:" "with when it last ran"
}

test_an_unwritable_unit_is_a_manual_step_not_a_failure() {
  setup
  export SM_SUDO="false"
  sm_plan > /dev/null
  sm_apply > /dev/null 2>&1
  assert_eq "unit_start_limits" "${SM_MANUAL[*]}" "reported for the operator to do"
  assert_eq 0 "${#SM_FAILED[@]}" "and not counted as a failure"
  assert_eq "instance_start_script" "${SM_APPLIED[*]}" "the other migration still ran"
  assert_not_contains "$(cat "$SM_UNIT_DIR/testinst.service")" "StartLimit" "the unit was not half written"
  assert_exists "$(ls "$SM_SCRIPTS_DIR"/common/migration-backups/*.patched | head -1)" "the patched unit is kept for the manual copy"
}

test_one_failing_migration_does_not_stop_the_others() {
  setup
  if ! perms_work || [[ "$(id -u)" == 0 ]]; then
    skip "unwritable instance dir" "needs POSIX permissions and a non-root user"
    return
  fi
  chmod 500 "$SM_INSTANCE_DIR"
  sm_plan > /dev/null
  sm_apply > /dev/null 2>&1
  chmod 700 "$SM_INSTANCE_DIR"
  assert_eq "instance_start_script" "${SM_FAILED[*]}" "the start.sh migration failed"
  assert_contains "$(cat "$SM_UNIT_DIR/testinst.service")" "StartLimitBurst" "the unit migration still ran"
}

# ── migrate.sh ──

test_migrate_lists_the_migrations_and_changes_nothing() {
  setup
  local scripts="$T/install/scripts/testinst"
  mkdir -p "$scripts/common" "$T/install/instances/testinst"
  cat > "$scripts/common/variables.txt" <<VARS
USER="tester"
INSTANCE_NAME="testinst"
SERVER_PATH="$SM_INSTANCE_DIR"
BACKUPS_PATH="$T/backups"
VARS
  local out
  out="$(SM_UNIT_DIR="$SM_UNIT_DIR" bash "$ROOT/migrate.sh" "$scripts" --list-server-migrations 2>&1)"
  assert_contains "$out" "instance_start_script" "migrate.sh lists the start.sh migration"
  assert_contains "$out" "pending" "as pending for this install"
  assert_contains "$(cat "$SM_INSTANCE_DIR/start.sh")" "old start" "and changes nothing"
}

test_migrate_help_documents_the_migrations() {
  setup
  local out
  out="$(bash "$ROOT/migrate.sh" --help 2>&1)"
  assert_contains "$out" "--no-server-migrations" "the skip flag is documented"
  assert_contains "$out" "--list-server-migrations" "and the list flag"
  assert_contains "$out" "World data, mods, server.jar and server.properties are not touched" "and what is never touched"
}

# ── cron to systemd timers ───────────────────────────────────────────────────

# A crontab that keeps what is written to it, and systemd as the shim sees it.
cron_setup() {
  setup
  export SYSTEMD_USABLE=true SYSTEMCTL_SHIM_UNITS="testinst-backup.timer testinst-restart.timer"
  mkdir -p "$SM_SCRIPTS_DIR/backup/logs"
  cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
f="$SHIM_STATE/crontab"
case "$1" in
  -l) [[ -f "$f" ]] || { echo "no crontab for tester" >&2; exit 1; }; cat "$f" ;;
  -r) rm -f "$f" ;;
  -) cat > "$f" ;;
  *) cp "$1" "$f" ;;
esac
SH
  chmod +x "$T/bin/crontab"
}

backup_line() { printf '20 * * * * bash %s >> %s 2>&1\n' "$SM_SCRIPTS_DIR/backup/automation/run_backup.sh" "$SM_SCRIPTS_DIR/backup/logs/backup.log"; }
restart_line() { printf '0 */6 * * * bash %s >> %s 2>&1\n' "$SM_SCRIPTS_DIR/backup/automation/scheduled_restart.sh" "$SM_SCRIPTS_DIR/backup/logs/restart.log"; }

test_the_cron_migration_is_pending_only_when_the_suites_cron_lines_exist() {
  cron_setup
  sm_plan > /dev/null
  assert_not_contains " ${SM_PENDING[*]} " " cron_to_timers " "no crontab, nothing to move"
  printf '5 5 * * * unrelated\n' > "$SHIM_STATE/crontab"
  sm_plan > /dev/null
  assert_not_contains " ${SM_PENDING[*]} " " cron_to_timers " "an unrelated cron line is not the suite's"
  { printf '5 5 * * * unrelated\n'; backup_line; } > "$SHIM_STATE/crontab"
  sm_plan > /dev/null
  assert_contains " ${SM_PENDING[*]} " " cron_to_timers " "the suite's backup line makes it pending"
  SYSTEMD_USABLE=false sm_plan > /dev/null
  assert_not_contains " ${SM_PENDING[*]} " " cron_to_timers " "a host without systemd keeps cron"
}

test_the_backup_cron_line_becomes_a_timer_and_other_lines_stay() {
  cron_setup
  { printf '5 5 * * * unrelated\n'; backup_line; } > "$SHIM_STATE/crontab"
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_eq "cron_to_timers" "$(printf '%s\n' "${SM_APPLIED[@]}" | grep cron_to_timers)" "applied"
  assert_exists "$SM_UNIT_DIR/testinst-backup.timer" "the timer is installed"
  assert_contains "$(cat "$SM_UNIT_DIR/testinst-backup.timer")" "OnCalendar=*-*-* *:20:00" "at minute 20, like the cron line"
  assert_file_content "$SHIM_STATE/crontab" "5 5 * * * unrelated" "only the suite's line is gone"
  assert_eq 1 "$(ls "$SM_SCRIPTS_DIR"/common/migration-backups/crontab.* 2> /dev/null | wc -l | tr -d '[:space:]')" "the old crontab is kept"
  assert_contains "$(cat "$SM_SCRIPTS_DIR"/common/migration-backups/crontab.*)" "run_backup.sh" "and has the old line"
  sm_plan > /dev/null
  assert_not_contains " ${SM_PENDING[*]} " " cron_to_timers " "a second run has nothing to do"
}

test_an_emptied_crontab_is_removed_not_left_blank() {
  cron_setup
  backup_line > "$SHIM_STATE/crontab"
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_missing "$SHIM_STATE/crontab" "no crontab is left when nothing else was in it"
}

test_the_restart_cron_line_follows_the_configured_interval() {
  cron_setup
  printf 'RESTART_ENABLED="true"\nRESTART_INTERVAL_HOURS="6"\n' >> "$SM_SCRIPTS_DIR/common/variables.txt"
  { backup_line; restart_line; } > "$SHIM_STATE/crontab"
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_contains "$(cat "$SM_UNIT_DIR/testinst-restart.timer")" "OnCalendar=*-*-* 00/6:00:00" "every 6 hours"
  assert_missing "$SHIM_STATE/crontab" "both lines are gone"
}

test_a_schedule_that_is_not_the_suites_is_left_for_the_operator() {
  cron_setup
  printf '5 * * * * bash %s >> /dev/null 2>&1\n' "$SM_SCRIPTS_DIR/backup/automation/run_backup.sh" > "$SHIM_STATE/crontab"
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_eq "cron_to_timers" "${SM_MANUAL[*]}" "reported as a manual step"
  assert_missing "$SM_UNIT_DIR/testinst-backup.timer" "no timer was guessed"
  assert_contains "$(cat "$SHIM_STATE/crontab")" "5 * * * *" "the operator's line is untouched"
}

test_without_sudo_the_migration_asks_for_a_manual_step_and_changes_nothing() {
  cron_setup
  backup_line > "$SHIM_STATE/crontab"
  export SM_SUDO="false"
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_contains " ${SM_MANUAL[*]} " " cron_to_timers " "reported as a manual step"
  assert_missing "$SM_UNIT_DIR/testinst-backup.timer" "no unit was written"
  assert_contains "$(cat "$SHIM_STATE/crontab")" "run_backup.sh" "the cron line stays"
}

test_a_timer_that_cannot_be_enabled_keeps_cron_and_leaves_no_units() {
  cron_setup
  export SYSTEMCTL_SHIM_UNITS=""
  backup_line > "$SHIM_STATE/crontab"
  sm_plan > /dev/null
  sm_apply > /dev/null
  assert_eq "cron_to_timers" "${SM_FAILED[*]}" "reported as failed"
  assert_missing "$SM_UNIT_DIR/testinst-backup.timer" "the timer file is taken back out"
  assert_missing "$SM_UNIT_DIR/testinst-backup.service" "and its service"
  assert_contains "$(cat "$SHIM_STATE/crontab")" "run_backup.sh" "backups keep running from cron"
}

test_an_unreadable_crontab_changes_nothing() {
  cron_setup
  cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
echo "crontab: cannot open your crontab: Permission denied" >&2
exit 1
SH
  chmod +x "$T/bin/crontab"
  sm_plan > /dev/null
  assert_not_contains " ${SM_PENDING[*]} " " cron_to_timers " "an unreadable crontab is never treated as the suite's"
  assert_missing "$SM_UNIT_DIR/testinst-backup.timer" "no timer"
}

run_tests
