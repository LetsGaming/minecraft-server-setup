#!/bin/bash
# S-001: a failed setup run rolls back only what it created. Re-running setup
# to add an instance must never take the existing instances, worlds and
# backups with it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
source "$HERE/lib/assert.sh"

setup() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  export MAIN_DIR="$T/home" SCRIPT_DIR="$T/src" SYSTEMD_UNIT_DIR="$T/units" CRONTAB_FILE="$T/crontab"
  mkdir -p "$MAIN_DIR" "$SCRIPT_DIR/src/scripts/common" "$SYSTEMD_UNIT_DIR"
  cat > "$SCRIPT_DIR/variables.json" <<JSON
{ "INSTANCE_NAME": "second", "TARGET_DIR_NAME": "mc", "BACKUPS": { "BACKUPS_PATH": "none" } }
JSON
  INSTANCE_NAME=second TARGET_DIR_NAME=mc
}

# Stand-ins for what the rollback calls. sudo runs the command for real, but
# only ever inside $T.
stubs() {
  log() { echo "LOG $*"; }
  warn() { echo "WARN $*"; }
  error() { echo "ERR $*"; }
  sudo() { if [[ "$1" == systemctl ]]; then echo "systemctl ${*:2}" >> "$T/calls"; else "$@"; fi; }
  crontab() {
    case "$1" in
      -l) [[ -f "$CRONTAB_FILE" ]] && cat "$CRONTAB_FILE" || return 1 ;;
      -r) rm -f "$CRONTAB_FILE" ;;
      -) cat > "$CRONTAB_FILE" ;;
      *) cp "$1" "$CRONTAB_FILE" ;;
    esac
  }
}

run_rollback_after() { # body to run between snapshot and rollback
  (
    stubs
    source "$REPO/src/common/setup.sh"
    snapshot_setup_state > /dev/null
    eval "$1"
    run_rollback
  ) > "$T/out" 2>&1
}

test_a_failed_run_removes_the_timers_it_created_and_keeps_older_ones() {
  setup
  touch "$SYSTEMD_UNIT_DIR/first-backup.service" "$SYSTEMD_UNIT_DIR/first-backup.timer"
  INSTANCE_NAME=first
  run_rollback_after '
    touch "$SYSTEMD_UNIT_DIR/first-restart.service" "$SYSTEMD_UNIT_DIR/first-restart.timer"
  '
  assert_exists "$SYSTEMD_UNIT_DIR/first-backup.timer" "a timer from before the run is kept"
  assert_exists "$SYSTEMD_UNIT_DIR/first-backup.service" "and its service"
  assert_missing "$SYSTEMD_UNIT_DIR/first-restart.timer" "a timer this run created is removed"
  assert_missing "$SYSTEMD_UNIT_DIR/first-restart.service" "and its service"
  local calls; calls="$(cat "$T/calls" 2>/dev/null)"
  assert_contains "$calls" "stop first-restart.timer" "the timer is stopped"
  assert_contains "$calls" "disable first-restart.timer" "and disabled"
  assert_not_contains "$calls" "first-backup" "the older timer is left running"
}

test_existing_instances_survive_a_failed_second_instance() {
  setup
  local base="$MAIN_DIR/mc"
  mkdir -p "$base/instances/first/world" "$base/scripts/first" "$base/backups/first/hourly" "$base/services/api-server"
  echo '{"instances":{"first":{}}}' > "$base/services/api-server/api-server-config.json"
  echo world > "$base/instances/first/world/level.dat"
  touch "$SYSTEMD_UNIT_DIR/first.service" "$SYSTEMD_UNIT_DIR/mc-api-server.service"
  printf '0 * * * * bash %s/scripts/first/backup.sh\n' "$base" > "$CRONTAB_FILE"

  run_rollback_after '
    mkdir -p "$MAIN_DIR/mc/instances/second" "$MAIN_DIR/mc/scripts/second" "$MAIN_DIR/mc/backups/second"
    touch "$SYSTEMD_UNIT_DIR/second.service"
    echo "{\"instances\":{\"first\":{},\"second\":{}}}" > "$MAIN_DIR/mc/services/api-server/api-server-config.json"
    printf "0 * * * * bash %s/scripts/second/backup.sh\n" "$MAIN_DIR/mc" >> "$CRONTAB_FILE"
  '

  assert_exists "$base/instances/first/world/level.dat" "the first instance's world is kept"
  assert_exists "$base/scripts/first" "its scripts are kept"
  assert_exists "$base/backups/first/hourly" "its backups are kept"
  assert_exists "$base/services/api-server" "the shared wrapper is kept"
  assert_file_content "$base/services/api-server/api-server-config.json" '{"instances":{"first":{}}}' "the wrapper config no longer lists the failed instance"
  assert_exists "$SYSTEMD_UNIT_DIR/mc-api-server.service" "the shared wrapper unit is kept"
  assert_exists "$SYSTEMD_UNIT_DIR/first.service" "the first instance's unit is kept"
  assert_missing "$base/instances/second" "the new instance's directory is removed"
  assert_missing "$base/scripts/second" "the new scripts are removed"
  assert_missing "$base/backups/second" "the new backups folder is removed"
  assert_missing "$SYSTEMD_UNIT_DIR/second.service" "the new unit is removed"
  assert_file_content "$CRONTAB_FILE" "0 * * * * bash $base/scripts/first/backup.sh" "the crontab is exactly what it was"
  assert_not_contains "$(cat "$T/calls" 2>/dev/null)" "mc-api-server" "the shared wrapper is not stopped"
}

test_a_first_run_removes_its_whole_base_dir() {
  setup
  run_rollback_after '
    mkdir -p "$MAIN_DIR/mc/instances/second" "$MAIN_DIR/mc/services/api-server"
    touch "$SYSTEMD_UNIT_DIR/second.service"
    echo "0 * * * * x" > "$CRONTAB_FILE"
  '
  assert_missing "$MAIN_DIR/mc" "everything under the new base dir goes"
  assert_exists "$MAIN_DIR" "the home directory stays"
  assert_missing "$CRONTAB_FILE" "no crontab is left where there was none"
}

test_without_a_snapshot_nothing_is_deleted() {
  setup
  mkdir -p "$MAIN_DIR/mc/instances/first"
  ( stubs; source "$REPO/src/common/setup.sh"; run_rollback ) > "$T/out" 2>&1
  assert_exists "$MAIN_DIR/mc/instances/first" "an unarmed rollback deletes nothing"
}

test_rollback_keeps_variables_json() {
  setup
  local config="$SCRIPT_DIR/variables.json" before
  before="$(cat "$config")"
  mkdir -p "$MAIN_DIR/mc/instances/first"
  run_rollback_after '
    mkdir -p "$MAIN_DIR/mc/instances/second" "$MAIN_DIR/mc/scripts/second"
    touch "$SYSTEMD_UNIT_DIR/second.service"
    echo "0 * * * * x" > "$CRONTAB_FILE"
    echo secret > "$SCRIPT_DIR/src/scripts/common/variables.txt"
  '
  assert_exists "$config" "variables.json survives a rollback"
  assert_file_content "$config" "$before" "variables.json is unchanged"
  assert_missing "$MAIN_DIR/mc/instances/second" "the rollback itself ran"

  setup
  ( stubs; source "$REPO/src/common/setup.sh"; run_rollback ) > "$T/out" 2>&1
  assert_exists "$SCRIPT_DIR/variables.json" "variables.json survives an unarmed rollback"
}

# TARGET_DIR_NAME validation is covered in tests/js/loadVariables.test.cjs.

run_tests
