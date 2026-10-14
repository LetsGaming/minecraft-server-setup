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

test_existing_instances_survive_a_failed_second_instance() {
  setup
  local base="$MAIN_DIR/mc"
  mkdir -p "$base/instances/first/world" "$base/scripts/first" "$base/backups/first/hourly" "$base/api-server"
  echo world > "$base/instances/first/world/level.dat"
  touch "$SYSTEMD_UNIT_DIR/first.service" "$SYSTEMD_UNIT_DIR/mc-api-server.service"
  printf '0 * * * * bash %s/scripts/first/backup.sh\n' "$base" > "$CRONTAB_FILE"

  run_rollback_after '
    mkdir -p "$MAIN_DIR/mc/instances/second" "$MAIN_DIR/mc/scripts/second" "$MAIN_DIR/mc/backups/second"
    touch "$SYSTEMD_UNIT_DIR/second.service"
    printf "0 * * * * bash %s/scripts/second/backup.sh\n" "$MAIN_DIR/mc" >> "$CRONTAB_FILE"
  '

  assert_exists "$base/instances/first/world/level.dat" "the first instance's world is kept"
  assert_exists "$base/scripts/first" "its scripts are kept"
  assert_exists "$base/backups/first/hourly" "its backups are kept"
  assert_exists "$base/api-server" "the shared wrapper is kept"
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
    mkdir -p "$MAIN_DIR/mc/instances/second" "$MAIN_DIR/mc/api-server"
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

test_target_dir_name_must_be_a_plain_name() {
  setup
  local out
  for bad in "." ".." "a/b" "../x"; do
    printf '{"INSTANCE_NAME":"x","TARGET_DIR_NAME":"%s","BACKUPS":{},"JAVA":{}}' "$bad" > "$T/v.json"
    out=$(node -e '
      const fs=require("fs"),path=require("path");
      const src=process.argv[1];
      const lv=fs.readFileSync(path.join(src,"src/setup/common/loadVariables.js"),"utf8");
      const m={exports:{}};
      new Function("module","exports","require","__dirname",lv)(m,m.exports,(id)=>id==="fs"?{...fs,existsSync:()=>true,readFileSync:(p,e)=>p.endsWith("variables.json")?fs.readFileSync(process.argv[2],e):fs.readFileSync(p,e)}:require(id),path.join(src,"src/setup/common"));
      try{(m.exports.default||m.exports)();console.log("accepted")}catch(e){console.log(e.message)}
    ' "$REPO" "$T/v.json")
    assert_contains "$out" "TARGET_DIR_NAME" "TARGET_DIR_NAME '$bad' is refused"
  done
}

run_tests
