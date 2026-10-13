#!/bin/bash
# Tests for src/migrations/server.sh and how migrate.sh uses it.
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
  source "$ROOT/src/migrations/server.sh"
}

test_an_old_install_has_both_migrations_pending() {
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
  assert_eq "" "$(ls "$SM_INSTANCE_DIR" | grep 'migrate-[0-9]*$' || true)" "no temp file is left behind"
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
  assert_contains "$unit" "LimitNOFILE=4096" "the rest of the unit is untouched"
  assert_eq "RestartSec=3s" "$(grep -B0 -A0 '^RestartSec' <<< "$unit")" "RestartSec is unchanged"
  assert_logged "systemctl daemon-reload" "systemd is told, without a restart"
  assert_not_logged "systemctl restart" "the server is not restarted"
  assert_eq 1 "$(ls "$SM_SCRIPTS_DIR"/common/migration-backups/testinst.service.* | grep -vc patched)" "the old unit is kept"
}

test_a_unit_with_its_own_limits_is_left_alone() {
  setup
  printf '%s' "${OLD_UNIT/RestartSec=3s/RestartSec=3s
StartLimitBurst=10}" > "$SM_UNIT_DIR/testinst.service"
  sm_plan > /dev/null
  assert_eq "instance_start_script" "${SM_PENDING[*]}" "the operator's own StartLimit settings win"
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

run_tests
