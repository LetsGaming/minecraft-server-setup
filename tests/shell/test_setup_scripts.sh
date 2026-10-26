#!/bin/bash
# Tests for the setup helpers that install the unit, the cron jobs and start the
# server (src/setup/management), and for the unit's ExecStop script. Nothing
# here touches a real crontab or systemd: crontab and sudo are shims that stay
# inside the scratch tree.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/assert.sh"
source "$HERE/lib/fixture.sh"

REPO="$(cd "$HERE/../.." && pwd)"
MGMT="$REPO/src/setup/management"

setup() {
  make_fixture; trap cleanup_fixture EXIT
  use_install_layout
  mkdir -p "$R/scripts/testinst/backup/automation" "$R/scripts/testinst/backup/logs"
  : > "$R/scripts/testinst/backup/automation/run_backup.sh"
  : > "$R/scripts/testinst/backup/automation/scheduled_restart.sh"
  export MAIN_DIR="$T" TARGET_DIR_NAME="mc-root" INSTANCE_NAME="testinst" USER="tester" SYSTEMD_UNIT_DIR="$T/units"
  # These cases cover the cron fallback; test_timers.sh covers the systemd path.
  export SYSTEMD_USABLE=false
  mkdir -p "$T/units"

  # Writes through tee only, and only where the test pointed it.
  cat > "$T/bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >> "$SHIM_LOG"
while [[ "$1" == -* ]]; do
  if [[ "$1" == -u ]]; then shift 2; else shift; fi
done
case "$1" in
  tee | chmod) exec "$@" ;;
  screen) exec "$@" ;;
esac
exit 0
SH
  cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
f="$SHIM_STATE/crontab"
case "$1" in
  -l)
    if [[ -n "${CRONTAB_SHIM_FAIL:-}" ]]; then echo "crontab: $CRONTAB_SHIM_FAIL" >&2; exit 1; fi
    [[ -f "$f" ]] || { echo "no crontab for tester" >&2; exit 1; }
    cat "$f"
    ;;
  -) cat > "$f" ;;
esac
SH
  chmod +x "$T/bin/sudo" "$T/bin/crontab"
}

run_mgmt() { # script ; sets OUT and RC
  OUT="$(bash "$MGMT/$1" 2>&1 < /dev/null)"
  RC=$?
}

restart_vars() { # hours
  printf 'RESTART_ENABLED="true"\nRESTART_INTERVAL_HOURS="%s"\n' "$1" >> "$R/scripts/testinst/common/variables.txt"
}

# ── the unit ─────────────────────────────────────────────────────────────────

test_the_unit_flushes_before_stopping_and_gets_a_longer_stop_window() {
  setup
  run_mgmt create_service.sh
  assert_rc 0 "$RC" "the unit is written"
  local unit
  unit="$(cat "$T/units/testinst.service")"
  assert_contains "$unit" "TimeoutStopSec=300" "a world has time to be written"
  assert_contains "$unit" "ExecStop=/usr/bin/bash $R/scripts/testinst/common/graceful_stop.sh" "the flush runs on stop"
  assert_contains "$unit" "PrivateTmp=true" "private /tmp"
  assert_contains "$unit" "ProtectSystem=full" "system folders are read-only"
  assert_contains "$unit" "ReadWritePaths=-$R/instances/testinst -$T/backups" "the instance and the backups stay writable"
  assert_contains "$unit" "StartLimitBurst=5" "the crash-loop limits are still there"
}

test_graceful_stop_flushes_a_running_server_and_does_nothing_for_a_stopped_one() {
  setup
  server_running
  export SCREEN_SHIM_SAVE_LOG="$R/instances/testinst/logs/latest.log"
  mkdir -p "$R/instances/testinst/logs"
  : > "$SCREEN_SHIM_SAVE_LOG"
  OUT="$(cd "$R/scripts/testinst" && bash common/graceful_stop.sh 2>&1 < /dev/null)"; RC=$?
  assert_rc 0 "$RC" "exits 0"
  assert_logged "save-all flush" "the world is flushed"

  : > "$SHIM_LOG"
  rm -f "$SHIM_STATE/screen_running"
  OUT="$(cd "$R/scripts/testinst" && bash common/graceful_stop.sh 2>&1 < /dev/null)"; RC=$?
  assert_rc 0 "$RC" "exits 0 for a stopped server too"
  assert_not_logged "save-all" "nothing to flush"
}

test_graceful_stop_exits_0_even_when_the_save_is_not_confirmed() {
  setup
  server_running
  export SAVE_TIMEOUT_SECONDS=2
  OUT="$(cd "$R/scripts/testinst" && bash common/graceful_stop.sh 2>&1 < /dev/null)"; RC=$?
  assert_rc 0 "$RC" "systemd is never held up by the flush"
  assert_contains "$OUT" "not confirmed" "the problem is reported"
}

# ── the cron jobs ────────────────────────────────────────────────────────────

test_the_backup_job_is_added_once_with_quoted_paths() {
  setup
  run_mgmt create_backup_job.sh
  assert_rc 0 "$RC" "added"
  assert_contains "$(cat "$SHIM_STATE/crontab")" "20 * * * * bash $R/scripts/testinst/backup/automation/run_backup.sh >> $R/scripts/testinst/backup/logs/backup.log 2>&1" "the hourly line"
  run_mgmt create_backup_job.sh
  assert_contains "$OUT" "already exists" "the second run adds nothing"
  assert_eq 1 "$(grep -c run_backup.sh "$SHIM_STATE/crontab")" "one line"
}

test_a_path_with_a_space_is_escaped_in_the_cron_line() {
  setup
  mkdir -p "$T/with space/mc/scripts/testinst/backup/automation"
  : > "$T/with space/mc/scripts/testinst/backup/automation/run_backup.sh"
  MAIN_DIR="$T/with space" TARGET_DIR_NAME=mc run_mgmt create_backup_job.sh
  assert_rc 0 "$RC" "added"
  assert_contains "$(cat "$SHIM_STATE/crontab")" 'bash '"$T"'/with\ space/mc/scripts/testinst/backup/automation/run_backup.sh' "the space is escaped"
  MAIN_DIR="$T/with space" TARGET_DIR_NAME=mc run_mgmt create_backup_job.sh
  assert_contains "$OUT" "already exists" "and found again on the next run"
}

test_an_unreadable_crontab_stops_the_job_instead_of_replacing_it() {
  setup
  printf '5 5 * * * keep-me\n' > "$SHIM_STATE/crontab"
  export CRONTAB_SHIM_FAIL="cannot open your crontab: Permission denied"
  run_mgmt create_backup_job.sh
  assert_rc 1 "$RC" "the script stops"
  assert_contains "$OUT" "Nothing was changed" "and says so"
  assert_file_content "$SHIM_STATE/crontab" "5 5 * * * keep-me" "the existing jobs are intact"
  restart_vars 6
  run_mgmt create_restart_job.sh
  assert_rc 1 "$RC" "the restart job stops too"
  assert_file_content "$SHIM_STATE/crontab" "5 5 * * * keep-me" "still intact"
}


test_the_restart_interval_must_divide_a_day() {
  setup
  restart_vars 5
  run_mgmt create_restart_job.sh
  assert_rc 1 "$RC" "5 hours is refused"
  assert_contains "$OUT" "must divide 24" "says why"
  assert_missing "$SHIM_STATE/crontab" "no job was written"
}

test_a_restart_interval_of_whole_days_becomes_a_day_step() {
  setup
  restart_vars 48
  run_mgmt create_restart_job.sh
  assert_rc 0 "$RC" "48 hours is accepted"
  assert_contains "$(cat "$SHIM_STATE/crontab")" "0 0 */2 * * bash $R/scripts/testinst/backup/automation/scheduled_restart.sh" "every second day at midnight"
}

test_a_divisor_of_24_uses_the_hour_step() {
  setup
  restart_vars 6
  run_mgmt create_restart_job.sh
  assert_contains "$(cat "$SHIM_STATE/crontab")" "0 */6 * * * bash" "every 6 hours"
}

# ── starting the server ──────────────────────────────────────────────────────

test_without_a_service_a_server_that_did_not_start_is_reported() {
  setup
  mkdir -p "$R/instances/testinst"
  : > "$R/instances/testinst/start.sh"
  NO_SERVICE=true run_mgmt start_server.sh
  assert_rc 1 "$RC" "no screen session means failure"
  assert_contains "$OUT" "did not stay up" "says so"
  assert_logged "screen -S testinst -dm bash $R/instances/testinst/start.sh" "the instance's own start.sh was launched, not the systemctl wrapper"
}

test_without_a_service_a_running_session_is_a_success() {
  setup
  mkdir -p "$R/instances/testinst"
  : > "$R/instances/testinst/start.sh"
  server_running
  NO_SERVICE=true run_mgmt start_server.sh
  assert_rc 0 "$RC" "started"
  assert_contains "$OUT" "screen session 'testinst'" "reports the session"
}

test_with_a_service_the_start_scripts_failure_is_the_result() {
  setup
  echo 'exit 7' > "$R/scripts/testinst/start.sh"
  NO_SERVICE=false run_mgmt start_server.sh
  assert_rc 1 "$RC" "a failing start.sh fails the step"
  assert_contains "$OUT" "did not start" "says so"
  echo 'exit 0' > "$R/scripts/testinst/start.sh"
  NO_SERVICE=false run_mgmt start_server.sh
  assert_rc 0 "$RC" "a working one succeeds"
}

# ── unpacking a modpack ──────────────────────────────────────────────────────

# mk_zip <file> <name:kind>...: kind is "file" or "link"; the entries are written
# as a Unix zip would, so unzip -Z shows a link as one.
mk_zip() {
  local file="$1"; shift
  python3 - "$file" "$@" <<'PY'
import stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for spec in sys.argv[2:]:
        name, kind = spec.rsplit(":", 1)
        info = zipfile.ZipInfo(name)
        info.create_system = 3
        info.external_attr = ((stat.S_IFLNK | 0o777) if kind == "link" else (stat.S_IFREG | 0o644)) << 16
        z.writestr(info, "/etc" if kind == "link" else "data")
PY
}

unpack() { # entries... ; sets OUT and RC
  local suite="$T/suite"
  mkdir -p "$suite/src/setup/download/temp"
  mk_zip "$suite/src/setup/download/temp/server-pack.zip" "$@"
  OUT="$(SCRIPT_DIR="$suite" bash "$REPO/src/setup/structure/unpack_modpack.sh" 2>&1 < /dev/null)"
  RC=$?
}

test_a_modpack_is_unpacked_when_every_entry_stays_inside() {
  setup
  if ! command -v python3 > /dev/null 2>&1 || ! command -v unzip > /dev/null 2>&1; then skip "unpack" "python3 or unzip is missing"; return; fi
  unpack "config/a.toml:file" "mods/m.jar:file"
  assert_rc 0 "$RC" "unpacked"
  assert_exists "$R/instances/testinst/config/a.toml" "the file is in the instance"
}

test_a_modpack_with_an_entry_outside_the_instance_is_refused_before_anything_is_written() {
  setup
  if ! command -v python3 > /dev/null 2>&1 || ! command -v unzip > /dev/null 2>&1; then skip "unpack" "python3 or unzip is missing"; return; fi
  unpack "ok.txt:file" "../../escape.txt:file"
  assert_rc 1 "$RC" "refused"
  assert_contains "$OUT" "leaves the instance folder" "says why"
  assert_missing "$R/instances/testinst/ok.txt" "no entry was extracted"
  unpack "/tmp/absolute.txt:file"
  assert_rc 1 "$RC" "an absolute path is refused too"
  unpack 'a\..\b.txt:file'
  assert_rc 1 "$RC" "so is a backslash path with a .. segment"
}

test_a_modpack_with_a_symbolic_link_is_refused() {
  setup
  if ! command -v python3 > /dev/null 2>&1 || ! command -v unzip > /dev/null 2>&1; then skip "unpack" "python3 or unzip is missing"; return; fi
  unpack "link:link" "link/escape.txt:file"
  assert_rc 1 "$RC" "refused"
  assert_contains "$OUT" "symbolic link" "says why"
  assert_missing "$R/instances/testinst/link" "nothing was extracted"
}

run_tests
